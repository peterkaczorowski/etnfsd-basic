defmodule Tnfs.Session.LiveTest do
  @moduledoc """
  The arithmetic of a transfer, and the rules about when it is announced.

  Every function here takes the current time as an argument and the destination
  is an ordinary pid, so this whole file is a test process sending itself
  messages: no server, no socket, no timer and no sleep. That is possible
  because the module was written that way, and it is why the awkward cases -
  seeking backwards, reading the same bytes twice, reusing a handle number -
  can be asserted exactly rather than approximately.

  The properties these tests exist to hold are that progress cannot be faked,
  that throughput and progress are different numbers, and that nothing which
  identifies a client is in the message at all.
  """

  use ExUnit.Case, async: false

  alias Tnfs.Session.Live

  @interval 100
  @t0 5_000_000
  @fields ~w(at country covered id path rate served size started transport)a

  setup do
    Live.publish(self(), @interval)
    on_exit(&Live.withdraw/0)
    :ok
  end

  defp opened(live \\ %{}, handle, opts) do
    Live.opened(
      live,
      handle,
      Keyword.get(opts, :path, "/games/a.atr"),
      Keyword.get(opts, :size, 1_000),
      Keyword.get(opts, :address, {198, 51, 100, 7})
    )
  end

  defp read(live, handle, bytes, now, transport \\ :udp) do
    Live.read(live, handle, bytes, transport, now)
  end

  defp update do
    assert_receive {:live_update, event}, 500
    event
  end

  test "a handle that is opened is not yet a transfer" do
    live = opened(0, [])

    refute_receive {:live_update, _event}, 100

    # And closing it announces nothing either, because nothing was announced.
    assert Live.closed(live, 0, @t0) == %{}
    refute_receive {:live_complete, _id, _covered, _now}, 100
  end

  test "the first successful read is what makes it one" do
    _live = opened(0, path: "/games/blue.atr", size: 1_000) |> read(0, 8, @t0)

    event = update()
    assert event.path == "/games/blue.atr"
    assert event.size == 1_000
    assert event.transport == :udp
    assert event.covered == 8
    assert event.served == 8
    assert event.started == @t0
    assert event.at == @t0
    assert event.rate == 0
    assert event.id =~ ~r/\A[0-9a-f]{8}\z/
  end

  test "an emission carries these fields and nothing that identifies anybody" do
    _live = opened(0, []) |> read(0, 8, @t0)

    assert update() |> Map.keys() |> Enum.sort() == @fields
  end

  describe "coalescing" do
    test "a read inside the interval moves the counters and says nothing" do
      live = opened(0, []) |> read(0, 8, @t0)
      assert update().covered == 8

      live = Enum.reduce(1..99, live, fn n, live -> read(live, 0, 8, @t0 + n) end)
      refute_receive {:live_update, _event}, 100

      # Nothing was lost: the next emission carries everything since.
      _live = read(live, 0, 8, @t0 + @interval)
      assert update().covered == 8 * 101
    end

    test "so the number of messages is set by the interval, not by the read rate" do
      live = opened(0, [])

      # Ten thousand reads spread over ten intervals.
      _live =
        Enum.reduce(0..9_999, live, fn n, live ->
          read(live, 0, 1, @t0 + div(n * @interval * 10, 10_000))
        end)

      count = drain(0)
      assert count <= 11, "#{count} messages for 10000 reads"
      assert count >= 10
    end
  end

  describe "progress, which is not throughput" do
    test "reading straight through covers what it serves" do
      live = opened(0, size: 1_000) |> read(0, 400, @t0)
      assert update().covered == 400

      _live = read(live, 0, 400, @t0 + @interval)
      event = update()
      assert event.covered == 800
      assert event.served == 800
    end

    test "reading the same bytes again serves them again and covers nothing new" do
      live = opened(0, size: 1_000) |> read(0, 500, @t0)
      assert update().covered == 500

      live = Live.sought(live, 0, 0)
      _live = read(live, 0, 500, @t0 + @interval)

      event = update()
      assert event.covered == 500
      assert event.served == 1_000
    end

    test "seeking forward is not delivering, so the bar cannot be skipped to the end" do
      live = opened(0, size: 1_000) |> read(0, 10, @t0)
      assert update().covered == 10

      # Straight to the last byte, then read it. Ten bytes have been sent, and
      # the highest position reached is what the bar shows - which is honest,
      # because that is how much of the file this client now has a right end
      # of. What it must not say is that eleven bytes are a hundred per cent.
      live = Live.sought(live, 0, 999)
      _live = read(live, 0, 1, @t0 + @interval)

      event = update()
      assert event.covered == 1_000
      assert event.served == 11
    end

    test "seeking backwards never moves coverage backwards" do
      live = opened(0, size: 1_000) |> read(0, 900, @t0)
      assert update().covered == 900

      live = Live.sought(live, 0, 0)
      _live = read(live, 0, 4, @t0 + @interval)

      assert update().covered == 900
    end

    test "a seek alone announces nothing at all" do
      live = opened(0, []) |> read(0, 8, @t0)
      assert update().covered == 8

      _live = Live.sought(live, 0, 500)
      refute_receive {:live_update, _event}, 100
    end
  end

  describe "rate" do
    test "is zero on the first emission, because there is no interval yet" do
      _live = opened(0, []) |> read(0, 100_000, @t0)
      assert update().rate == 0
    end

    test "is bytes since the last emission, smoothed" do
      live = opened(0, []) |> read(0, 8, @t0)
      assert update().rate == 0

      # 8 more bytes in 100 ms is a sample of 80 B/s; three fifths of the
      # sample and two fifths of the previous 0.
      live = read(live, 0, 8, @t0 + @interval)
      assert update().rate == 48

      # Same sample again: the smoothed value climbs towards it.
      _live = read(live, 0, 8, @t0 + 2 * @interval)
      assert update().rate == div(48 * 2 + 80 * 3, 5)
    end

    test "counts bytes served, so re-reading the same range is real traffic" do
      live = opened(0, size: 1_000) |> read(0, 1_000, @t0)
      assert update().served == 1_000

      live = Live.sought(live, 0, 0)
      _live = read(live, 0, 1_000, @t0 + @interval)

      event = update()
      assert event.covered == 1_000
      assert event.served == 2_000
      assert event.rate > 0
    end
  end

  describe "the end of a transfer" do
    test "a close announces it finished, with the id it was announced under" do
      live = opened(0, []) |> read(0, 8, @t0)
      id = update().id

      assert Live.closed(live, 0, @t0 + 1) == %{}
      assert_receive {:live_complete, ^id, covered, at}, 500
      assert at == @t0 + 1

      # The close carries the position, not just the id. Emission is coalesced
      # to one message per interval, so a transfer that finishes between two
      # emissions has reads the aggregator has not been told about - and a
      # record marked complete at a stale position renders as a full-width
      # label beside a bar that never filled.
      assert covered == 8
    end

    test "the position a close carries includes reads never emitted" do
      # One emission at the first read, then four more reads inside the same
      # interval. Only the close can tell the aggregator where the file ended.
      live = opened(0, []) |> read(0, 100, @t0)
      assert update().covered == 100

      live =
        Enum.reduce(1..4, live, fn i, acc -> Live.read(acc, 0, 100, :udp, @t0 + i) end)

      refute_receive {:live_update, _event}, 100

      Live.closed(live, 0, @t0 + 5)
      assert_receive {:live_complete, _id, 500, _at}, 500
    end

    test "closing every handle retires every one that was visible" do
      live = opened(0, path: "/games/a.atr") |> read(0, 8, @t0)
      seen = update().id

      # A second handle, opened and never read, so never seen.
      live = opened(live, 1, path: "/games/b.atr")

      assert Live.closed_all(live, @t0 + 1) == %{}
      assert_receive {:live_complete, ^seen, _covered, _at}, 500
      refute_receive {:live_complete, _other, _covered, _at}, 100
    end

    test "a handle number handed out again is a different transfer" do
      live = opened(0, path: "/games/a.atr") |> read(0, 500, @t0)
      first = update()
      live = Live.closed(live, 0, @t0 + 1)
      assert_receive {:live_complete, _id, _covered, _at}, 500

      # The same number, a different file, and nothing carried over.
      _live = opened(live, 0, path: "/games/b.atr") |> read(0, 4, @t0 + @interval)

      second = update()
      assert second.id != first.id
      assert second.path == "/games/b.atr"
      assert second.covered == 4
      assert second.served == 4
      assert second.started == @t0 + @interval
    end
  end

  describe "when nothing is listening" do
    test "opening records nothing, so reading has nothing to do" do
      Live.withdraw()

      live = opened(0, [])
      assert live == %{}

      assert read(live, 0, 8, @t0) == %{}
      assert Live.sought(live, 0, 4) == %{}
      assert Live.closed(live, 0, @t0) == %{}
      assert Live.closed_all(live, @t0) == %{}

      refute_receive {:live_update, _event}, 100
    end

    test "a transfer in flight when the sink goes away stops emitting and keeps counting" do
      live = opened(0, size: 1_000) |> read(0, 100, @t0)
      assert update().covered == 100

      Live.withdraw()
      live = read(live, 0, 100, @t0 + @interval)
      refute_receive {:live_update, _event}, 100

      # Back again, and the row resumes with the right numbers rather than
      # restarting from this moment.
      Live.publish(self(), @interval)
      _live = read(live, 0, 100, @t0 + 2 * @interval)

      event = update()
      assert event.covered == 300
      assert event.started == @t0
    end

    test "a dead aggregator costs the session nothing and loses the events" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 500

      Live.publish(dead, @interval)

      live = opened(0, []) |> read(0, 8, @t0)
      assert Live.closed(live, 0, @t0 + 1) == %{}
    end
  end

  describe "the path" do
    test "is whatever the client asked for, carried through unchanged" do
      _live = opened(0, path: "/games/Blue Max.atr") |> read(0, 8, @t0)
      assert update().path == "/games/Blue Max.atr"
    end

    test "is not decoded here, because the export is not UTF-8" do
      hostile = <<"/games/", 0xFF, 0xFE, "\n.atr">>
      _live = opened(0, path: hostile) |> read(0, 8, @t0)

      # Byte for byte. Making it displayable is the display layer's job and
      # doing it here would be work on the critical path.
      assert update().path == hostile
    end

    test "is clamped to a bound the message can afford, keeping the name" do
      long = "/" <> String.duplicate("deep/", 900) <> "wanted.atr"
      assert byte_size(long) > 4_000

      _live = opened(0, path: long) |> read(0, 8, @t0)

      path = update().path
      assert byte_size(path) == 320
      assert String.ends_with?(path, "wanted.atr")
    end
  end

  defp drain(count) do
    receive do
      {:live_update, _event} -> drain(count + 1)
    after
      0 -> count
    end
  end
end
