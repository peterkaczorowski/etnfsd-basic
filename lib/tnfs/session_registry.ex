defmodule Tnfs.SessionRegistry do
  @moduledoc """
  SID routing table and the only place where sessions are created.

  Lookups are plain ETS reads done by the calling process: routing a request
  must not queue behind a global GenServer (handoff section 7.4). The process
  is involved only in MOUNT, in cleanup after a session dies, and in enforcing
  the session limits - all rare events.

  The table is `:protected`, so everyone can read it and only this process can
  write it, which keeps the limits honest without a lock.
  """

  use GenServer

  alias Tnfs.Limits
  alias Tnfs.MountCache
  alias Tnfs.Path, as: SafePath
  alias Tnfs.Peer
  alias Tnfs.Protocol
  alias Tnfs.Protocol.Request
  alias Tnfs.Protocol.Response
  alias Tnfs.SessionSupervisor

  @table :tnfs_sessions
  @sid_attempts 64

  @doc false
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @doc "Looks up a session. Hot path: a single ETS read, no message passing."
  @spec lookup(0..0xFFFF) :: {:ok, pid(), :inet.ip_address()} | :error
  def lookup(sid) do
    case :ets.lookup(@table, sid) do
      [{^sid, pid, address}] -> {:ok, pid, address}
      [] -> :error
    end
  end

  @doc "Number of live sessions."
  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  @doc "Live session ids of one address. Tests and telemetry only."
  @spec sids_for(:inet.ip_address()) :: [0..0xFFFF]
  def sids_for(address) do
    :ets.select(@table, [{{:"$1", :_, address}, [], [:"$1"]}])
  end

  @doc """
  Handles a MOUNT and returns the encoded response.

  The whole response is built here because a retransmitted MOUNT must replay
  the very same bytes, including the allocated SID. Without that, a lost MOUNT
  reply would leak one session per retry.
  """
  @spec mount(Request.t(), Peer.t()) :: binary()
  def mount(%Request{} = request, %Peer{} = peer) do
    GenServer.call(__MODULE__, {:mount, request, peer})
  end

  @impl GenServer
  def init(config) do
    table = :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])

    # Owned here, so a restart of this process takes the retry cache with it
    # rather than leaving replayable answers behind for sessions that no longer
    # exist.
    MountCache.new()

    state = %{config: config, table: table, ip_counts: %{}, monitors: %{}}
    schedule_prune(config)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:mount, request, peer}, _from, state) do
    case cached_mount(state, peer, request) do
      {:ok, encoded} ->
        :telemetry.execute([:tnfs, :mount, :retry_hit], %{count: 1}, %{address: peer.address})
        {:reply, encoded, state}

      :miss ->
        {encoded, state} = do_mount(request, peer, state)
        {:reply, encoded, state}
    end
  end

  # Expired entries have to go without waiting for another MOUNT: a server that
  # goes quiet after a burst would otherwise hold answers nobody can be given
  # for ever. A soak measured 14,520 entries and 8.6 MB still resident three
  # windows after the last MOUNT.
  #
  # The sweep is budgeted, and when it stops on the budget it queues itself
  # behind whatever is already in the mailbox instead of continuing. That is the
  # difference between "cleanup is bounded work" and "cleanup is bounded work
  # per callback": a MOUNT that arrives while a large cache is draining waits
  # for one budget, not for the drain.
  @impl GenServer
  def handle_info(:prune_mount_cache, state) do
    case MountCache.sweep(state.config.mount_dedup_ttl_ms) do
      :more -> send(self(), :prune_mount_cache)
      :done -> schedule_prune(state.config)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{sid, address}, monitors} ->
        :ets.delete(@table, sid)

        # Requests still queued to a dead process will never be dequeued, so
        # the counter has to go with the session rather than be inherited by
        # whoever gets this SID next.
        Limits.forget(sid)

        :telemetry.execute([:tnfs, :session, :closed], %{count: 1}, %{
          sid: sid,
          address: address,
          reason: reason
        })

        {:noreply, %{state | monitors: monitors, ip_counts: release_ip(state.ip_counts, address)}}
    end
  end

  defp do_mount(request, %Peer{address: address} = peer, state) do
    config = state.config

    case admit(state, address) do
      :ok ->
        start_session(request, peer, state)

      {:error, status} ->
        :telemetry.execute([:tnfs, :mount, :rejected], %{count: 1}, %{
          address: address,
          status: status
        })

        {encode_mount(request, 0, status, version_payload(config), config), state}
    end
  end

  # The session is bound to the address alone, as ADR 2 requires: a client that
  # changes source port must still reach it. Only the retry cache is keyed by
  # the full peer.
  defp start_session(request, %Peer{address: address} = peer, state) do
    config = state.config

    with {:ok, root} <- mounted_root(config, request.args.mount),
         {:ok, sid} <- allocate_sid(),
         opts = [
           sid: sid,
           peer_ip: address,
           mount_point: request.args.mount,
           root: root,
           protocol_version: request.args.version,
           config: config
         ],
         {:ok, pid} <- SessionSupervisor.start_session(opts) do
      ref = Process.monitor(pid)
      :ets.insert(@table, {sid, pid, address})

      payload = mount_success_payload(config)
      encoded = encode_mount(request, sid, :success, payload, config)

      :telemetry.execute([:tnfs, :session, :opened], %{count: 1}, %{sid: sid, address: address})

      remember_mount(state, peer, request, encoded)

      state = %{
        state
        | monitors: Map.put(state.monitors, ref, {sid, address}),
          ip_counts: Map.update(state.ip_counts, address, 1, &(&1 + 1))
      }

      {encoded, state}
    else
      {:error, reason} ->
        status = mount_failure_status(reason)

        :telemetry.execute([:tnfs, :mount, :failed], %{count: 1}, %{
          address: address,
          reason: reason
        })

        {encode_mount(request, 0, status, version_payload(config), config), state}
    end
  end

  # The mountpoint is a client-supplied path and gets exactly the same
  # treatment as any other one: resolved inside the export root, symlinks
  # denied. An empty mountpoint means the root itself (handoff section 3.1).
  defp mounted_root(config, mount) do
    with {:ok, root} <- SafePath.canonical_root(config.root),
         {:ok, resolved} <- SafePath.resolve(root, mount, config) do
      case File.lstat(resolved) do
        {:ok, %File.Stat{type: :directory}} -> {:ok, resolved}
        {:ok, _stat} -> {:error, :enotdir}
        {:error, reason} -> {:error, Tnfs.Error.to_status(reason)}
      end
    end
  end

  defp mount_failure_status(:sid_exhausted), do: :enobufs
  defp mount_failure_status(reason) when is_atom(reason), do: Tnfs.Error.to_status(reason)
  defp mount_failure_status(_reason), do: :eio

  defp admit(state, address) do
    config = state.config

    cond do
      is_nil(config.root) ->
        {:error, :eacces}

      count() >= config.max_sessions ->
        {:error, :eusers}

      Map.get(state.ip_counts, address, 0) >= config.max_sessions_per_ip ->
        {:error, :eusers}

      true ->
        :ok
    end
  end

  # A SID is a non-zero, cryptographically random u16 checked for collisions
  # (handoff section 5). It is an identifier, never an authenticator: the space
  # is only 65535 values wide.
  defp allocate_sid(attempts \\ 0)

  defp allocate_sid(attempts) when attempts >= @sid_attempts, do: {:error, :sid_exhausted}

  defp allocate_sid(attempts) do
    <<candidate::unsigned-16>> = :crypto.strong_rand_bytes(2)

    if candidate != 0 and not :ets.member(@table, candidate) do
      {:ok, candidate}
    else
      allocate_sid(attempts + 1)
    end
  end

  defp release_ip(ip_counts, address) do
    case Map.get(ip_counts, address, 0) do
      count when count <= 1 -> Map.delete(ip_counts, address)
      count -> Map.put(ip_counts, address, count - 1)
    end
  end

  defp cached_mount(state, peer, request) do
    MountCache.fetch(peer, request.seq, request.raw, state.config.mount_dedup_ttl_ms)
  end

  defp remember_mount(state, peer, request, encoded) do
    MountCache.put(
      peer,
      request.seq,
      request.raw,
      encoded,
      state.config.max_mount_dedup_entries
    )
  end

  # One TTL apart, so an entry is resident for at most twice the window it can
  # be used in. Sweeping more often would walk the index for nothing; less often
  # and the bound this exists to enforce becomes a suggestion.
  defp schedule_prune(config) do
    Process.send_after(self(), :prune_mount_cache, config.mount_dedup_ttl_ms)
  end

  defp mount_success_payload(config) do
    {:ok, payload} =
      Protocol.encode_payload(:mount, %{
        version: config.server_version,
        retry_ms: config.retry_ms
      })

    payload
  end

  # Even a failed MOUNT carries the server version, so a client can tell an old
  # server from a broken one (handoff section 3.1).
  defp version_payload(config), do: <<config.server_version::unsigned-little-16>>

  defp encode_mount(request, sid, status, payload, config) do
    response = %Response{
      sid: sid,
      seq: request.seq,
      command_id: request.command_id,
      status: status,
      payload: payload
    }

    {:ok, encoded} = Protocol.encode_response(response, config)
    encoded
  end
end
