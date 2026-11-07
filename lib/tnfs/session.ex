defmodule Tnfs.Session do
  @moduledoc """
  One process per mounted session, and the only owner of that session's state
  (handoff sections 5 and 7.4).

  Everything belonging to a SID - sequence state, retry cache, file and
  directory handles, the mounted root - lives here and nowhere else. Because
  all commands of a SID go through this single process, READ/WRITE/LSEEK and
  directory cursors keep their order without any lock, while different SIDs run
  in parallel on different schedulers.

  The process is started as `:temporary`: a crashed session must never come
  back as an empty session under the same SID. The client gets EBADSESSION and
  mounts again (handoff section 7.3).
  """

  use GenServer, restart: :temporary

  alias Tnfs.Limits
  alias Tnfs.Protocol
  alias Tnfs.Protocol.Request
  alias Tnfs.Protocol.Response
  alias Tnfs.Reply
  alias Tnfs.Session.Handler
  alias Tnfs.Session.Live

  defmodule State do
    @moduledoc false
    defstruct [
      :sid,
      :peer_ip,
      :mount_point,
      :root,
      :config,
      :protocol_version,
      :last_contact,
      :last_seq,
      :last_raw,
      :last_response,
      files: %{},
      dirs: %{},
      # What each open read handle has delivered so far, for the live transfer
      # panel. Empty and never written to while the panel is disabled, so the
      # cost of the feature to a server that does not run it is one map match
      # against `%{}` per READ. See `Tnfs.Session.Live`.
      live: %{},
      # The transport this session's current request arrived on, which is the
      # sink the reply will take. Not a property of the session: a SID is
      # bound to an address and not to a connection, so it is answered per
      # request rather than remembered from MOUNT.
      transport: :udp
    ]
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Executes one request in the session and returns the encoded response.

  `{:error, :gone}` means the session process is no longer there, which the
  caller turns into EBADSESSION; `{:error, :busy}` means the session did not
  answer in time and the caller should reply EAGAIN.
  """
  @spec request(pid(), Request.t(), timeout()) ::
          {:ok, binary()} | {:error, :gone | :busy}
  def request(pid, %Request{} = request, timeout) do
    {:ok, GenServer.call(pid, {:request, request}, timeout)}
  catch
    :exit, {:timeout, _call} -> {:error, :busy}
    :exit, _reason -> {:error, :gone}
  end

  @doc """
  Hands one request to the session without waiting for it.

  The session answers through `sink` when it gets there. This is what keeps two
  sessions on the same dispatcher independent: the worker returns immediately,
  so a large directory listing in one session costs nothing to the other.
  """
  @spec deliver(pid(), Request.t(), Reply.t()) :: :ok
  def deliver(pid, %Request{} = request, sink) do
    GenServer.cast(pid, {:request, request, sink})
  end

  @doc "Snapshot of session state. Tests and telemetry only."
  @spec info(pid()) :: map()
  def info(pid), do: GenServer.call(pid, :info)

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)

    state = %State{
      sid: Keyword.fetch!(opts, :sid),
      peer_ip: Keyword.fetch!(opts, :peer_ip),
      mount_point: Keyword.fetch!(opts, :mount_point),
      root: Keyword.fetch!(opts, :root),
      protocol_version: Keyword.fetch!(opts, :protocol_version),
      config: config,
      last_contact: now()
    }

    schedule_idle_check(config.session_timeout_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:request, request}, _from, state) do
    # A synchronous request is the TCP path: the connection process owns the
    # socket, is dedicated to one client and sends the answer itself.
    case run(request, %{state | transport: :tcp}) do
      {:continue, encoded, state} -> {:reply, encoded, state}
      {:final, encoded, state} -> {:stop, :normal, encoded, state}
    end
  end

  def handle_call(:info, _from, state) do
    info = %{
      sid: state.sid,
      peer_ip: state.peer_ip,
      root: state.root,
      mount_point: state.mount_point,
      last_seq: state.last_seq,
      open_files: map_size(state.files),
      open_dirs: map_size(state.dirs)
    }

    {:reply, info, state}
  end

  @impl GenServer
  def handle_cast({:request, request, sink}, state) do
    {outcome, encoded, state} =
      try do
        run(request, %{state | transport: transport(sink)})
      after
        Limits.dequeue(state.sid)
      end

    Reply.send(sink, encoded)

    case outcome do
      :continue -> {:noreply, state}
      :final -> {:stop, :normal, state}
    end
  end

  @impl GenServer
  def handle_info(:idle_check, state) do
    idle_for = now() - state.last_contact

    if idle_for >= state.config.session_timeout_ms do
      :telemetry.execute([:tnfs, :session, :timeout], %{idle_ms: idle_for}, %{sid: state.sid})
      {:stop, :normal, state}
    else
      schedule_idle_check(state.config.session_timeout_ms - idle_for)
      {:noreply, state}
    end
  end

  # The answer to the one question this process asks anybody: a country code
  # for a handle it opened. It arrives between requests, costs one map update
  # and is never waited for - if it never arrives the panel shows a globe. The
  # address that produced it was sent out at OPEN and is not stored here.
  def handle_info({:live_flag, handle, id, country}, state) do
    {:noreply, %{state | live: Live.flagged(state.live, handle, id, country)}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Handler.close_all(state)
    :ok
  end

  defp transport({:udp, _socket, _address, _port}), do: :udp
  defp transport(:sync), do: :tcp

  # The whole of a session's decision making, independent of how the answer
  # will travel back. `:final` means the command ended the session and the
  # response is the last thing it will ever say.
  @spec run(Request.t(), State.t()) :: {:continue | :final, binary(), State.t()}
  defp run(request, state) do
    state = %{state | last_contact: now()}

    cond do
      state.last_seq != request.seq ->
        execute(request, state)

      request.raw == state.last_raw ->
        # Retransmission: replay the stored bytes, never the effect.
        :telemetry.execute([:tnfs, :session, :retry_hit], %{count: 1}, %{sid: state.sid})
        {:continue, state.last_response, state}

      true ->
        # Same sequence number, different body. Refuse without executing and
        # without disturbing the cached answer to the original request, so a
        # later retransmission of that request still replays correctly
        # (handoff section 14.1, ADR 8).
        :telemetry.execute([:tnfs, :session, :seq_conflict], %{count: 1}, %{sid: state.sid})

        case state.config.seq_conflict do
          :eproto -> {:continue, encode(request, :eproto, <<>>, state), state}
          :execute_new -> execute(request, state)
        end
    end
  end

  defp execute(request, state) do
    {status, payload, state} =
      try do
        Handler.execute(request, state)
      rescue
        exception ->
          # A bug in a handler must cost one command, not the session and not
          # the server. The client still gets exactly one answer.
          :telemetry.execute([:tnfs, :session, :handler_crash], %{count: 1}, %{
            sid: state.sid,
            command: request.command,
            kind: exception.__struct__
          })

          {:eio, <<>>, state}
      end

    encoded = encode(request, status, payload, state)

    # Every executed command becomes the new retry cache entry. The one answer
    # that must not overwrite it is the EPROTO of a sequence conflict, and that
    # one is produced in `handle_call/3` without ever reaching here.
    state = %{state | last_seq: request.seq, last_raw: request.raw, last_response: encoded}

    if Handler.final?(request.command, status) do
      {:final, encoded, state}
    else
      {:continue, encoded, state}
    end
  end

  defp encode(request, status, payload, state) do
    response = %Response{
      sid: state.sid,
      seq: request.seq,
      command_id: request.command_id,
      status: status,
      payload: payload
    }

    case Protocol.encode_response(response, state.config) do
      {:ok, encoded} ->
        encoded

      {:error, :response_too_large} ->
        # Refuse rather than truncate: a half listing is worse than an error.
        {:ok, encoded} =
          Protocol.encode_response(%{response | status: :e2big, payload: <<>>}, state.config)

        encoded
    end
  end

  defp schedule_idle_check(after_ms) do
    Process.send_after(self(), :idle_check, max(after_ms, 1))
  end

  defp now, do: System.monotonic_time(:millisecond)

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :sid)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end
end
