defmodule Tnfs.LimitsTest do
  use ExUnit.Case, async: false

  alias Tnfs.Config
  alias Tnfs.Limits

  @rate :tnfs_rate_buckets

  setup context do
    config =
      Config.build!(
        rate_limit_window_ms: Map.get(context, :window_ms, 50),
        rate_limit_buckets: Map.get(context, :buckets, 64)
      )

    start_supervised!({Limits, config})
    {:ok, buckets: config.rate_limit_buckets}
  end

  describe "in-flight counters" do
    test "admits up to the limit and refuses beyond it" do
      assert Limits.acquire(0, 2) == :ok
      assert Limits.acquire(0, 2) == :ok
      assert Limits.acquire(0, 2) == {:error, :overload}

      # A refused acquire must not leave the counter inflated, otherwise a
      # burst of rejections would permanently close the partition.
      assert Limits.in_flight(0) == 2
    end

    test "releasing frees a slot" do
      assert Limits.acquire(1, 1) == :ok
      assert Limits.acquire(1, 1) == {:error, :overload}

      Limits.release(1)

      assert Limits.in_flight(1) == 0
      assert Limits.acquire(1, 1) == :ok
    end

    test "partitions are independent" do
      assert Limits.acquire(2, 1) == :ok
      assert Limits.acquire(3, 1) == :ok
      assert Limits.in_flight(2) == 1
      assert Limits.in_flight(3) == 1
    end

    test "an extra release cannot push the counter below zero" do
      Limits.release(4)
      Limits.release(4)

      assert Limits.in_flight(4) == 0
    end
  end

  describe "rate limiting" do
    test "spends the burst and then refuses" do
      address = {192, 0, 2, 1}

      assert Limits.allow?(address, 2)
      assert Limits.allow?(address, 2)
      refute Limits.allow?(address, 2)
    end

    test "addresses in different buckets are metered separately" do
      first = {192, 0, 2, 2}
      second = elsewhere(first)

      assert Limits.allow?(first, 1)
      refute Limits.allow?(first, 1)
      assert Limits.allow?(second, 1)
    end

    test "addresses in the same bucket share one budget" do
      first = {192, 0, 2, 2}
      second = alongside(first)

      # The honest half of the trade. Collision sharing is what buys the hard
      # bound, so it is pinned here rather than left to be discovered.
      assert Limits.allow?(first, 1)
      refute Limits.allow?(second, 1)
    end

    test "the next window starts with a full bucket" do
      address = {192, 0, 2, 4}

      assert Limits.allow?(address, 1)
      refute Limits.allow?(address, 1)

      Process.sleep(80)

      assert Limits.allow?(address, 1)
    end
  end

  describe "the bucket table is bounded by configuration, not by traffic" do
    @tag window_ms: 60_000
    test "holds no more rows than configured however many addresses arrive",
         context do
      # 65 536 IPv4 sources and 4 096 IPv6 ones, three orders of magnitude past
      # the 64 buckets configured. Under the old address-keyed table this was
      # 69 632 rows; the bound was the window timer, and a window is long enough
      # to run a machine out of memory at line rate.
      flood_ipv4(65_536, 1)
      flood_ipv6(4_096, 1)

      assert :ets.info(@rate, :size) <= context.buckets
    end

    @tag window_ms: 60_000
    test "holds no more rows than configured when the first access is concurrent",
         context do
      # Every one of these addresses is seen for the first time, by eight
      # schedulers at once. There is no admission decision to lose a race on:
      # the key is a bucket index, so a colliding pair of callers simply lands
      # on the same `update_counter`.
      1..8
      |> Task.async_stream(fn worker -> flood_ipv4(8_192, 1, worker) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Stream.run()

      assert :ets.info(@rate, :size) <= context.buckets
    end

    @tag window_ms: 10
    test "stays bounded while the refill timer races the callers", context do
      # Rotation is `delete_all_objects` against callers that are mid-insert.
      # Nothing here can drift, because there is no counter of rows to drift
      # from: the row count is a property of the key space.
      sampler =
        Task.async(fn ->
          Enum.map(1..200, fn _ ->
            Process.sleep(1)
            :ets.info(@rate, :size)
          end)
        end)

      flood_ipv4(200_000, 4)

      assert Enum.max(Task.await(sampler, 30_000)) <= context.buckets
      assert :ets.info(@rate, :size) <= context.buckets
    end

    @tag window_ms: 60_000
    test "an admitted bucket keeps its budget while other buckets are flooded" do
      address = {198, 51, 100, 1}
      mine = Limits.slot(address)

      assert Limits.allow?(address, 3)
      assert Limits.tokens(address, 3) == 2

      # Everything except this peer's bucket is driven to the floor.
      Enum.each(1..65_536, fn n ->
        other = ipv4(n)
        if Limits.slot(other) != mine, do: Limits.allow?(other, 1)
      end)

      assert Limits.tokens(address, 3) == 2
      assert Limits.allow?(address, 3)
      assert Limits.allow?(address, 3)
      refute Limits.allow?(address, 3)
    end

    @tag window_ms: 60_000
    test "a spent bucket is not reset by the flood that follows it" do
      address = {198, 51, 100, 2}
      mine = Limits.slot(address)

      assert Limits.allow?(address, 1)
      refute Limits.allow?(address, 1)

      Enum.each(1..20_000, fn n ->
        other = ipv4(n)
        if Limits.slot(other) != mine, do: Limits.allow?(other, 1)
      end)

      refute Limits.allow?(address, 1)
    end

    @tag window_ms: 50
    test "cardinality and memory come back to an empty table after the window",
         context do
      empty = :ets.info(@rate, :memory)

      flood_ipv4(20_000, 1)

      assert :ets.info(@rate, :size) <= context.buckets

      wait_until(fn -> :ets.info(@rate, :size) == 0 end)
      assert :ets.info(@rate, :memory) == empty
    end
  end

  defp ipv4(n), do: {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}

  defp flood_ipv4(count, burst, salt \\ 0) do
    Enum.each(1..count, fn n -> Limits.allow?(ipv4(n * 17 + salt * 7_919), burst) end)
  end

  defp flood_ipv6(count, burst) do
    Enum.each(1..count, fn n ->
      Limits.allow?({0x2001, 0xDB8, 0, 0, 0, 0, div(n, 256), rem(n, 256)}, burst)
    end)
  end

  # The hash is seeded per boot, so which addresses share a bucket is not
  # knowable in advance and has to be searched for.
  defp elsewhere(address), do: find(address, &!=/2)
  defp alongside(address), do: find(address, &==/2)

  defp find(address, match?) do
    want = Limits.slot(address)

    Enum.find(1..1_000_000, fn n ->
      match?.(Limits.slot(ipv4(n)), want) and ipv4(n) != address
    end)
    |> case do
      nil -> flunk("no address found")
      n -> ipv4(n)
    end
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.() do
        :ok
      else
        Process.sleep(5)
        if System.monotonic_time(:millisecond) > deadline, do: flunk("never became true")
        :retry
      end
    end)
    |> Enum.find(&(&1 == :ok))
  end
end
