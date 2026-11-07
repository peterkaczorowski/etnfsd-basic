defmodule Tnfs.MountCacheTest do
  @moduledoc """
  The retry cache at the level the server cannot reach: capacity, expiry and the
  work one callback is allowed to do.

  These matter because the cache lives inside `Tnfs.SessionRegistry`, which is
  the process every MOUNT is serialised through. Anything unbounded in here is
  unbounded MOUNT latency for everybody, and the shape that produces it - a
  flood of MOUNTs from unique source ports - costs an attacker nothing.
  """

  use ExUnit.Case, async: false

  alias Tnfs.MountCache
  alias Tnfs.Peer

  # The tables are `:protected`, so writes have to come from their owner. This
  # is that owner, and running the assertions through it is also how the "one
  # callback" bound is measured: each `run/1` is exactly one callback.
  defmodule Owner do
    @moduledoc false
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

    @impl GenServer
    def init(nil), do: {:ok, MountCache.new()}

    def run(fun), do: GenServer.call(__MODULE__, {:run, fun}, 120_000)

    @impl GenServer
    def handle_call({:run, fun}, _from, state), do: {:reply, fun.(), state}
  end

  setup do
    start_supervised!(Owner)
    :ok
  end

  defp peer(port), do: Peer.udp({192, 0, 2, 1}, port)
  defp run(fun), do: Owner.run(fun)

  defp put(peer, seq, raw, encoded, max \\ 1_000_000) do
    run(fn -> MountCache.put(peer, seq, raw, encoded, max) end)
  end

  describe "replay" do
    test "returns the original bytes for a retransmission of the same request" do
      put(peer(1), 7, "request", "answer")

      assert MountCache.fetch(peer(1), 7, "request", 60_000) == {:ok, "answer"}
    end

    test "a different sequence number, body or peer is a miss" do
      put(peer(1), 7, "request", "answer")

      assert MountCache.fetch(peer(1), 8, "request", 60_000) == :miss
      assert MountCache.fetch(peer(1), 7, "other", 60_000) == :miss
      assert MountCache.fetch(peer(2), 7, "request", 60_000) == :miss
    end

    test "an entry older than the window is a miss" do
      put(peer(1), 7, "request", "answer")

      Process.sleep(20)

      assert MountCache.fetch(peer(1), 7, "request", 10) == :miss
    end
  end

  describe "capacity" do
    test "never holds more than the configured maximum" do
      for port <- 1..1_000 do
        put(peer(port), 0, "r", "a", 64)
        assert MountCache.size() <= 64
      end

      assert MountCache.size() == 64
      assert MountCache.index_size() == 64
    end

    test "evicts the oldest entry, not an arbitrary one" do
      for port <- 1..64, do: put(peer(port), 0, "r", "a", 64)

      put(peer(65), 0, "r", "a", 64)

      assert MountCache.fetch(peer(1), 0, "r", 60_000) == :miss
      assert MountCache.fetch(peer(2), 0, "r", 60_000) == {:ok, "a"}
      assert MountCache.fetch(peer(65), 0, "r", 60_000) == {:ok, "a"}
    end

    test "one peer mounting repeatedly occupies one entry and one index key" do
      for seq <- 0..500, do: put(peer(1), rem(seq, 256), "r#{seq}", "a", 64)

      assert MountCache.size() == 1
      assert MountCache.index_size() == 1
      assert MountCache.fetch(peer(1), rem(500, 256), "r500", 60_000) == {:ok, "a"}
    end

    test "a churn of unique source ports leaves the cache at its bound" do
      # The attack shape: one MOUNT per ephemeral port, never repeated. Under
      # the old map this both grew the cache to `4 * max_sessions` and made
      # every insert past that sort the whole thing.
      for port <- 1..200_000, do: put(peer(port), 0, "r", "a", 1_024)

      assert MountCache.size() == 1_024
      assert MountCache.index_size() == 1_024
    end
  end

  describe "expiry" do
    test "removes entries without any further traffic" do
      for port <- 1..100, do: put(peer(port), 0, "r", "a", 1_000)

      Process.sleep(20)

      assert run(fn -> MountCache.sweep(10) end) == :done
      assert MountCache.size() == 0
      assert MountCache.index_size() == 0
    end

    test "leaves entries that are still inside the window" do
      for port <- 1..100, do: put(peer(port), 0, "r", "a", 1_000)

      assert run(fn -> MountCache.sweep(60_000) end) == :done
      assert MountCache.size() == 100
    end

    test "one sweep removes at most its budget and says so" do
      budget = MountCache.sweep_budget()
      total = budget * 4

      for port <- 1..total, do: put(peer(port), 0, "r", "a", total)

      Process.sleep(20)

      # This is the bound the registry is held to. Not "cleanup is cheap on
      # average" - one callback, one budget, then back to the mailbox, so a
      # MOUNT arriving mid-drain waits for one batch rather than for the drain.
      assert run(fn -> MountCache.sweep(10) end) == :more
      assert MountCache.size() == total - budget

      assert run(fn -> MountCache.sweep(10) end) == :more
      assert MountCache.size() == total - 2 * budget
    end

    test "a full cache drains completely over repeated budgeted sweeps" do
      total = MountCache.sweep_budget() * 3

      for port <- 1..total, do: put(peer(port), 0, "r", "a", total)

      Process.sleep(20)

      drain = fn drain ->
        case run(fn -> MountCache.sweep(10) end) do
          :more -> drain.(drain)
          :done -> :ok
        end
      end

      drain.(drain)

      assert MountCache.size() == 0
      assert MountCache.index_size() == 0
    end
  end
end
