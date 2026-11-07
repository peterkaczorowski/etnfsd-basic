defmodule Tnfs.Session.Live do
  @moduledoc """
  What the session tells the outside world about a download in progress.

  This module is the whole of the TNFS side of the live transfer panel, and it
  is deliberately small. Everything it does happens inside the session process
  that is already running the command, so everything it does is on the critical
  path of a TNFS request and is written to cost as close to nothing as a
  function can.

  ## Why the session is the right place to count

  A transfer is a property of an open file handle, and the only process that
  knows a handle's history is the session that owns it. Two facts found by
  `Tnfs.ReadPathCharacterizationTest` decide the design:

    * a session may hold several read handles at once and they do not share a
      position, so identity has to be per handle and not per session; and
    * a closed handle number is handed straight back out again, so the handle
      number alone cannot be the identity - a record is keyed by a random id
      minted at OPEN, and a reused number gets a new one.

  A third fact decides where in the session to put it. A retransmitted request
  never reaches `Tnfs.Session.Handler`: `Tnfs.Session.run/2` replays the cached
  bytes and returns. So counting here counts *logical* delivery. A replayed
  READ puts bytes on the wire again and is correctly not counted as progress,
  because the file position did not move either.

  ## Why it cannot block

  `emit/2` is one `send/3` to a pid that was written into `:persistent_term`
  when the aggregator started. That is the only coupling between TNFS and
  anything that displays it - there is no module reference, no registry
  lookup, no `GenServer.call`, no monitor and nothing to wait for. A send to a
  dead pid is a no-op, so an aggregator that has crashed and not yet restarted
  silently loses events and costs a session nothing.

  What keeps the aggregator's mailbox bounded is also here rather than there:
  a handle emits at most once per `interval` milliseconds however many READs
  it serves in that time. Emission rate is therefore a function of how many
  files are open, never of how fast they are being read. A client issuing
  thirty thousand one-byte READs a second produces four messages a second.

  ## What travels

  The id, the logical path the client asked for, the size, the transport, the
  covered position, the payload bytes served and the timestamps. No address,
  no port, no SID, no pid, no handle number and no host path: the record is
  built from what the request said and what this handle has done, and the
  fields that would identify anyone are not in it to be leaked.

  Sanitising the path, clamping, formatting and encoding all happen in the
  aggregator. This process hands over raw values and returns to serving TNFS.
  """

  # The destination is a pid in `:persistent_term`, and its absence is what
  # "disabled" means. Reading a persistent term is a lock-free constant-time
  # lookup with no copy, which is the cheapest way to ask a question on a path
  # that asks it once per READ.
  @key {__MODULE__, :sink}

  # The country resolver, published separately and read separately, because it
  # is answered separately: a deployment can run the panel without a country
  # database and the absence of this term is what that looks like. One OPEN
  # reads it once; no READ reads it at all.
  @geo_key {__MODULE__, :geo}

  @type t :: %__MODULE__{}

  defstruct [
    :id,
    :path,
    :size,
    :transport,
    :position,
    :covered,
    :served,
    :started,
    :last_read,
    :last_emit,
    :emitted_served,
    :rate,
    :country
  ]

  @doc """
  Publishes the process that should receive events, or clears it.

  Called by the aggregator when it starts and by whatever shuts it down.
  Writing a persistent term is expensive - it scans every process for
  references to the term it replaces - which is exactly why this happens at
  boot and at restart rather than per request.
  """
  @spec publish(pid(), pos_integer()) :: :ok
  def publish(pid, interval_ms)
      when is_pid(pid) and is_integer(interval_ms) and interval_ms > 0 do
    :persistent_term.put(@key, {pid, interval_ms})
  end

  @doc "Stops all emission. Idempotent."
  @spec withdraw() :: :ok
  def withdraw do
    _ = :persistent_term.erase(@key)
    :ok
  end

  @doc """
  Where events go and how often, or `nil` when the feature is off.

  One persistent term read answers both questions, which is why they are one
  term: a READ on the critical path asks this exactly once.
  """
  @spec sink() :: {pid(), pos_integer()} | nil
  def sink, do: :persistent_term.get(@key, nil)

  @doc "Whether anything is listening."
  @spec enabled?() :: boolean()
  def enabled?, do: sink() != nil

  @doc "Publishes the process that resolves addresses to country codes."
  @spec publish_geo(pid()) :: :ok
  def publish_geo(pid) when is_pid(pid), do: :persistent_term.put(@geo_key, pid)

  @doc "Stops all country resolution. Idempotent."
  @spec withdraw_geo() :: :ok
  def withdraw_geo do
    _ = :persistent_term.erase(@geo_key)
    :ok
  end

  @doc "The country resolver, or `nil` when no database is installed."
  @spec geo() :: pid() | nil
  def geo, do: :persistent_term.get(@geo_key, nil)

  @doc """
  Records an OPEN.

  Nothing is emitted and nothing is displayed yet: a transfer becomes visible
  on its first successful non-empty READ, so that a client that opens a file
  and never reads it produces no row. `size` is `nil` when it is not known,
  which is honest and is rendered as an indeterminate state rather than as a
  percentage of an invented total.
  """
  @spec opened(map(), non_neg_integer(), binary(), non_neg_integer() | nil, :inet.ip_address()) ::
          map()
  def opened(live, handle, path, size, address) do
    if enabled?() do
      id = new_id()
      locate(handle, id, address)

      Map.put(live, handle, %__MODULE__{
        id: id,
        path: clamp_path(path),
        size: size,
        position: 0,
        covered: 0,
        served: 0,
        rate: 0
      })
    else
      live
    end
  end

  @doc """
  Attaches a country code that the resolver worked out after the OPEN returned.

  The id is checked as well as the handle. A handle number is reissued the
  moment it is closed, so a reply that arrives after the file it describes has
  been closed and the number reused would otherwise label the new file with the
  old file's country. Mismatched replies are dropped; there is no queue and
  nothing to clean up.
  """
  @spec flagged(map(), non_neg_integer(), binary(), binary()) :: map()
  def flagged(live, handle, id, country) do
    case live do
      %{^handle => %__MODULE__{id: ^id} = record} ->
        %{live | handle => %{record | country: country}}

      _absent_or_reused ->
        live
    end
  end

  @doc """
  Records a READ that returned `bytes` bytes, and emits if it is time to.

  Two different quantities move here and they are not the same quantity, which
  is why they are two fields:

    * `covered` is the highest position this handle has reached, so it never
      exceeds the file and never goes backwards. That is what the progress bar
      shows.
    * `served` is every payload byte this handle has produced, including bytes
      produced twice because the client seeked backwards. That is what the
      rate is computed from.

  A client that reads the first kilobyte of a file a hundred times has served
  a hundred kilobytes and covered one, and both numbers are true.
  """
  @spec read(map(), non_neg_integer(), pos_integer(), :udp | :tcp, integer()) :: map()
  def read(live, handle, bytes, transport, now) do
    case live do
      %{^handle => record} ->
        position = record.position + bytes

        record = %{
          record
          | transport: transport,
            position: position,
            covered: max(record.covered, position),
            served: record.served + bytes,
            started: record.started || now,
            last_read: now
        }

        %{live | handle => maybe_emit(record, now)}

      _absent ->
        # The common case when the panel is off: `live` is `%{}` and this is a
        # failed map match, which is the whole cost of the feature to a
        # deployment that does not run it.
        live
    end
  end

  @doc """
  Records an LSEEK.

  The position is whatever the kernel reported, so a seek past the end leaves
  a position past the end. `covered` is not moved by a seek - seeking is not
  delivering - so a client cannot make the bar read 100% without having been
  sent the file.
  """
  @spec sought(map(), non_neg_integer(), non_neg_integer()) :: map()
  def sought(live, handle, position) do
    case live do
      %{^handle => record} -> %{live | handle => %{record | position: position}}
      _absent -> live
    end
  end

  @doc """
  Records a CLOSE and retires the record.

  A handle that was never read was never visible, so nothing is sent for it.
  Anything else is announced as finished; how long a finished transfer stays
  on screen is the aggregator's decision, not this one's.
  """
  @spec closed(map(), non_neg_integer(), integer()) :: map()
  def closed(live, handle, now) do
    case Map.pop(live, handle) do
      {nil, live} ->
        live

      {record, live} ->
        retire(record, now)
        live
    end
  end

  @doc """
  Retires every record, for UMOUNT and for session death.

  Idle expiry in the aggregator is the backstop for a session killed without
  running `terminate/2`; this is the ordinary path, and it is immediate.
  """
  @spec closed_all(map(), integer()) :: map()
  def closed_all(live, now) do
    Enum.each(live, fn {_handle, record} -> retire(record, now) end)
    %{}
  end

  # A handle that was never read was never visible, so there is nothing to
  # take down.
  defp retire(%__MODULE__{started: nil}, _now), do: :ok

  # The covered position travels with the close, and it has to. Emission is
  # coalesced to once per interval, so the last few READs before a CLOSE are
  # usually still unemitted - and without this the aggregator would mark the
  # record complete while holding the position from the last emission. A
  # 512 KiB file read to the end then closed displayed 99%: a bar that is not
  # full beside the word "complete", which is the panel contradicting itself.
  defp retire(record, now), do: emit({:live_complete, record.id, record.covered, now})

  # Not emitted on every READ. At one message per `interval` per open handle
  # the load this puts on the aggregator is set by how many files are open,
  # which is bounded by `max_file_handles` times `max_sessions`, and not by
  # how many requests arrive.
  defp maybe_emit(record, now) do
    case sink() do
      # Turned off, or the aggregator has gone away. Stop emitting; the
      # counters keep running so that a transfer already in flight reappears
      # correctly if it comes back.
      nil ->
        record

      {pid, interval} when record.last_emit == nil or now - record.last_emit >= interval ->
        record = %{record | rate: rate(record, now)}

        _ =
          :erlang.send(
            pid,
            {:live_update,
             %{
               id: record.id,
               path: record.path,
               size: record.size,
               transport: record.transport,
               country: record.country,
               covered: record.covered,
               served: record.served,
               rate: record.rate,
               started: record.started,
               at: now
             }},
            [:nosuspend, :noconnect]
          )

        %{record | last_emit: now, emitted_served: record.served}

      _too_soon ->
        record
    end
  end

  # Bytes served since the last emission over the time since the last
  # emission, smoothed so that one slow interval does not make the number
  # jump. Monotonic time throughout, so a clock change cannot produce a
  # negative interval and a division by a zero interval is not possible
  # because the caller only gets here after `interval` has elapsed.
  defp rate(%__MODULE__{last_emit: nil}, _now), do: 0

  defp rate(record, now) do
    elapsed = now - record.last_emit
    sample = div((record.served - record.emitted_served) * 1_000, elapsed)
    div(record.rate * 2 + sample * 3, 5)
  end

  # A path may legally be `max_path_length` bytes, which is far more than a
  # panel can show and more than an event should carry. The tail is kept
  # rather than the head because the name is at the end and the directory is
  # not what a reader is looking at. Cutting bytes can cut a character in
  # half; the display layer replaces any byte that is not part of a valid
  # printable character, so the result is always well formed.
  @max_path_bytes 320

  defp clamp_path(path) when byte_size(path) <= @max_path_bytes, do: path
  defp clamp_path(path), do: binary_slice(path, -@max_path_bytes, @max_path_bytes)

  # Four bytes of randomness rendered as eight hex characters. Not derived
  # from the SID, the pid, the handle, the address or the name: there is
  # nothing in it to correlate, and a client that reopens the same file twice
  # gets two unrelated ids.
  defp new_id do
    Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  # The address leaves the session here and nowhere else, in one message, to
  # one process, which answers with a two-letter code. Nothing waits: if the
  # resolver is absent, slow, restarting or dead, no reply arrives, the record
  # keeps `country: nil` and the panel shows a globe. That is why this is a
  # `send` and not a call, and why the failure of the country database is not a
  # failure of anything a client can see.
  defp locate(handle, id, address) do
    case geo() do
      nil ->
        :ok

      pid ->
        _ =
          :erlang.send(
            pid,
            {:live_locate, self(), handle, id, address},
            [:nosuspend, :noconnect]
          )

        :ok
    end
  end

  # `:nosuspend` says that this process must never be made to wait for the
  # receiver, and `:noconnect` that it must never trigger a distribution
  # handshake. A send to a dead pid succeeds and does nothing, which is what
  # makes a crashed aggregator invisible from here.
  defp emit(message) do
    case sink() do
      nil -> :ok
      {pid, _interval} -> _ = :erlang.send(pid, message, [:nosuspend, :noconnect])
    end

    :ok
  end
end
