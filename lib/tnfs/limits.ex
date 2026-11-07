defmodule Tnfs.Limits do
  @moduledoc """
  Admission control: in-flight work per dispatch partition and a token bucket
  per source address (handoff section 7.4).

  Both counters live in ETS and are updated with `:ets.update_counter/4`, so the
  hot path never calls this process. The process exists only to own the tables
  and to refill the buckets on a timer.

  ## Why the bucket table cannot grow

  A UDP source address is whatever the sender wrote in the packet, so a table
  keyed by address is a table whose cardinality an attacker picks. Clearing it
  every window bounds how *long* a forged row lives, which is not the same thing
  as bounding how *many* there are: a flood at line rate still allocates a row
  per distinct address until the timer fires, and a window is long enough to run
  a machine out of memory.

  So the table is not keyed by address. It is a fixed array of
  `rate_limit_buckets` counters and an address is hashed into one of them. The
  keys are the integers `0..rate_limit_buckets-1` and nothing else is ever
  written, so the row count cannot exceed `rate_limit_buckets` no matter what
  arrives - the bound is the key space, not a check before an insert, and there
  is nothing for concurrent callers to race over. A previously unseen source
  whose bucket is already spent is refused without allocating anything.

  The price is collision sharing: two addresses landing in the same bucket spend
  one budget between them. That is deliberate, and it is why the hash is seeded
  with a per-boot random value - otherwise an attacker could compute addresses
  that collide with a chosen victim and starve it cheaply. Sizing is a straight
  trade: with `b` buckets and `n` active peers the chance a given peer shares
  with another is about `n/b`, and a bucket costs on the order of fifty bytes.

  The bucket is a fixed window rather than a leaky bucket, so refilling is just
  clearing the table; rows reappear lazily through the default of
  `:ets.update_counter/4`.
  """

  use GenServer

  @inflight :tnfs_inflight
  @backlog :tnfs_session_backlog
  @rate :tnfs_rate_buckets
  @hash {__MODULE__, :hash}

  @doc false
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @doc """
  Reserves a slot in a dispatch partition.

  Returns `{:error, :overload}` when the partition is saturated; the caller
  must then answer EAGAIN instead of queueing more work.
  """
  @spec acquire(non_neg_integer(), pos_integer()) :: :ok | {:error, :overload}
  def acquire(partition, max) do
    case :ets.update_counter(@inflight, partition, {2, 1}, {partition, 0}) do
      count when count > max ->
        :ets.update_counter(@inflight, partition, {2, -1}, {partition, 0})
        {:error, :overload}

      _count ->
        :ok
    end
  end

  @doc "Releases a slot previously taken with `acquire/2`."
  @spec release(non_neg_integer()) :: :ok
  def release(partition) do
    :ets.update_counter(@inflight, partition, {2, -1, 0, 0}, {partition, 0})
    :ok
  end

  @doc "Current in-flight count of a partition. For tests and telemetry."
  @spec in_flight(non_neg_integer()) :: non_neg_integer()
  def in_flight(partition) do
    case :ets.lookup(@inflight, partition) do
      [{^partition, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Reserves a place in a session's queue.

  Nothing waits on a session, so its mailbox is where work for a slow client
  piles up and it has to be bounded explicitly. The count is kept here rather
  than read from the process, because `:erlang.process_info/2` is a signal the
  target has to answer - asking a busy session how busy it is would block on
  exactly the request we are trying not to wait for.
  """
  @spec enqueue(0..0xFFFF, pos_integer()) :: :ok | {:error, :overload}
  def enqueue(sid, max) do
    case :ets.update_counter(@backlog, sid, {2, 1}, {sid, 0}) do
      count when count > max ->
        :ets.update_counter(@backlog, sid, {2, -1}, {sid, 0})
        {:error, :overload}

      _count ->
        :ok
    end
  end

  @doc "Gives back a place taken with `enqueue/2`, once the request is answered."
  @spec dequeue(0..0xFFFF) :: :ok
  def dequeue(sid) do
    :ets.update_counter(@backlog, sid, {2, -1, 0, 0}, {sid, 0})
    :ok
  end

  @doc """
  Drops a session's counter.

  Must be called when a session ends, however it ends: requests still queued to
  a dead process are never dequeued, and a leftover count would otherwise be
  charged to whoever is given that SID next.
  """
  @spec forget(0..0xFFFF) :: :ok
  def forget(sid) do
    :ets.delete(@backlog, sid)
    :ok
  end

  @doc "Current queue length of a session. For tests and telemetry."
  @spec backlog(0..0xFFFF) :: non_neg_integer()
  def backlog(sid) do
    case :ets.lookup(@backlog, sid) do
      [{^sid, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Takes one token from the bucket `address` hashes to.

  Used for traffic that is not attached to an established session: MOUNT and
  every error reply. Without it the error path is an amplification primitive
  and the SID space can be probed at line rate.
  """
  @spec allow?(:inet.ip_address(), pos_integer()) :: boolean()
  def allow?(address, burst) do
    slot = slot(address)
    :ets.update_counter(@rate, slot, {2, -1, -1, -1}, {slot, burst}) >= 0
  end

  @doc """
  Tokens left this window in the bucket serving `address`.

  For tests and telemetry: it is the only way to assert that a request was
  charged once and not twice. Note that the answer is about the bucket, not the
  address - another peer sharing it spends the same tokens.
  """
  @spec tokens(:inet.ip_address(), pos_integer()) :: integer()
  def tokens(address, burst) do
    slot = slot(address)

    case :ets.lookup(@rate, slot) do
      [{^slot, left}] -> left
      [] -> burst
    end
  end

  @doc """
  The bucket an address is metered in.

  Exported so tests can pick addresses that do or do not share a bucket, which
  is otherwise unknowable: the hash is seeded per boot on purpose.
  """
  @spec slot(:inet.ip_address()) :: non_neg_integer()
  def slot(address) do
    {buckets, seed} = :persistent_term.get(@hash)
    :erlang.phash2({seed, address}, buckets)
  end

  @impl GenServer
  def init(config) do
    :ets.new(@inflight, [:set, :public, :named_table, write_concurrency: true])
    :ets.new(@backlog, [:set, :public, :named_table, write_concurrency: true])
    :ets.new(@rate, [:set, :public, :named_table, write_concurrency: true])

    # Read once per request off the hot path. It is written here and nowhere
    # else, so the global scan a `:persistent_term` write costs is paid at boot.
    :persistent_term.put(@hash, {config.rate_limit_buckets, :rand.uniform(4_294_967_296)})

    schedule_refill(config.rate_limit_window_ms)
    {:ok, {config.rate_limit_window_ms, config.rate_limit_buckets}}
  end

  @impl GenServer
  def handle_info(:refill, {window_ms, buckets} = state) do
    # Saturation is worth reporting and a refusal is not: one event per refused
    # packet is one event per attacker packet, and an address in its metadata
    # would hand every aggregator downstream the unbounded table we just got rid
    # of. Instead the window reports how much of the fixed array was used and
    # how much of it hit the floor. Both sweeps are bounded by `buckets`.
    :telemetry.execute(
      [:tnfs, :rate_limit, :window],
      %{
        buckets: buckets,
        used: :ets.info(@rate, :size),
        exhausted: :ets.select_count(@rate, [{{:_, :"$1"}, [{:"=<", :"$1", 0}], [true]}])
      },
      %{}
    )

    # Clearing is the refill: every bucket starts the next window full and the
    # rows reappear only for buckets that are actually used.
    :ets.delete_all_objects(@rate)
    schedule_refill(window_ms)
    {:noreply, state}
  end

  defp schedule_refill(window_ms), do: Process.send_after(self(), :refill, window_ms)
end
