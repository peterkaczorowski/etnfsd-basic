defmodule Tnfs.MountCache do
  @moduledoc """
  The retry cache for MOUNT: the last MOUNT of each peer, replayable for
  `mount_dedup_ttl_ms`.

  MOUNT cannot use the per-session retry cache because no session exists yet,
  and without a cache a lost reply costs a session per retry. The key is the
  whole `Tnfs.Peer` rather than its address: two machines behind one NAT send
  identical bytes from one address, and merging them would hand both a single
  SID and a single handle table.

  ## Why it is not a map

  This cache used to be a map held in `Tnfs.SessionRegistry`, which is the
  process every MOUNT is serialised through. At its limit an insert sorted the
  whole map to find the oldest entry, and every periodic sweep filtered all of
  it. With the limit derived from `max_sessions` that meant a quarter of a
  million entries in a large configuration, so one insert or one sweep became a
  global MOUNT stall - and a flood of MOUNTs from unique source ports is an easy
  way to ask for exactly that.

  So it is two ETS tables instead:

    * `:tnfs_mount_cache`, a `set` keyed by peer, holding the request that was
      answered, the bytes that answered it, and the expiry key below;
    * `:tnfs_mount_expiry`, an `ordered_set` keyed by `{inserted_at, unique}`,
      holding the peer.

  Insert, lookup, replacement and eviction of the oldest entry are then constant
  or logarithmic, and nothing ever walks the whole cache. Replacement deletes
  the previous expiry key using the copy kept in the entry, so the index cannot
  accumulate orphans. Expiry pops the front of the ordered set up to
  `sweep_budget/0` entries per call, which is the bound on how long the registry
  can be away from its mailbox.

  Both tables are created by, and belong to, the registry process. They die with
  it and are rebuilt by its `init/1`, so a restart cannot leave a stale cache
  behind.
  """

  alias Tnfs.Peer

  @entries :tnfs_mount_cache
  @expiry :tnfs_mount_expiry

  # Entries one `sweep/1` may remove before returning. Two ETS deletes each, so
  # the callback is bounded at roughly a thousand deletes - tens of microseconds
  # - however many entries are due.
  @sweep_budget 512

  @doc """
  Creates the tables. Must be called from the process that is to own them.
  """
  @spec new() :: :ok
  def new do
    :ets.new(@entries, [:set, :protected, :named_table])
    :ets.new(@expiry, [:ordered_set, :protected, :named_table])
    :ok
  end

  @doc """
  Returns the bytes that answered this peer's last MOUNT, if the request is a
  retransmission of it and the window has not passed.

  A different sequence number or a different body is a miss, never a hit: a
  request that is not the one that was answered must not be answered from here.
  """
  @spec fetch(Peer.t(), 0..0xFF, binary(), pos_integer()) :: {:ok, binary()} | :miss
  def fetch(%Peer{} = peer, seq, raw, ttl_ms) do
    case :ets.lookup(@entries, peer) do
      [{^peer, ^seq, ^raw, encoded, at, _index}] ->
        if now() - at < ttl_ms, do: {:ok, encoded}, else: :miss

      _other ->
        :miss
    end
  end

  @doc """
  Remembers `encoded` as the answer to this peer's MOUNT, evicting the oldest
  entry if the cache is full.

  Only the owning process may call this, which is also why the capacity check
  can be a plain read: there is no second writer to race with.
  """
  @spec put(Peer.t(), 0..0xFF, binary(), binary(), pos_integer()) :: :ok
  def put(%Peer{} = peer, seq, raw, encoded, max) do
    case :ets.lookup(@entries, peer) do
      [{^peer, _seq, _raw, _encoded, _at, index}] -> :ets.delete(@expiry, index)
      [] -> make_room(max)
    end

    at = now()
    index = {at, :erlang.unique_integer([:monotonic])}

    :ets.insert(@expiry, {index, peer})
    :ets.insert(@entries, {peer, seq, raw, encoded, at, index})
    :ok
  end

  @doc """
  Removes entries too old to be replayed, at most `sweep_budget/0` of them.

  Returns `:more` when it stopped on the budget rather than on the work, so the
  caller can come back after servicing its mailbox instead of holding the
  process for an unbounded number of deletions.
  """
  @spec sweep(pos_integer()) :: :done | :more
  def sweep(ttl_ms), do: sweep(now() - ttl_ms, @sweep_budget)

  @doc "Entries currently held. Tests and telemetry."
  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@entries, :size)

  @doc "Expiry index size. Tests only: it must track `size/0` exactly."
  @spec index_size() :: non_neg_integer()
  def index_size, do: :ets.info(@expiry, :size)

  @doc "Entries one sweep may remove. Tests and documentation."
  @spec sweep_budget() :: pos_integer()
  def sweep_budget, do: @sweep_budget

  defp sweep(_deadline, 0), do: :more

  defp sweep(deadline, budget) do
    case :ets.first(@expiry) do
      :"$end_of_table" ->
        :done

      {at, _unique} = index when at <= deadline ->
        drop(index)
        sweep(deadline, budget - 1)

      _newer ->
        :done
    end
  end

  defp make_room(max) do
    if size() >= max and drop_oldest() == :dropped, do: make_room(max)
  end

  defp drop_oldest do
    case :ets.first(@expiry) do
      :"$end_of_table" -> :empty
      index -> drop(index)
    end
  end

  defp drop(index) do
    case :ets.take(@expiry, index) do
      [{^index, peer}] ->
        :ets.delete(@entries, peer)
        :dropped

      [] ->
        :empty
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
