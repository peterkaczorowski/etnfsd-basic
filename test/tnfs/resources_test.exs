defmodule Tnfs.ResourcesTest do
  @moduledoc """
  What must be given back when a session ends, however it ends.

  A leak here is invisible in a functional test and fatal in production: the
  server keeps running and slowly stops accepting anyone.
  """

  use Tnfs.ServerCase, async: false

  import Bitwise

  alias Tnfs.Limits
  alias Tnfs.SessionRegistry

  @create 0x0100 ||| 0x0002

  @moduletag config: [read_only: false, max_sessions_per_ip: 4, max_file_handles: 4]

  setup context do
    File.write!(Path.join(context.root, "hello.txt"), "hello")
    :ok
  end

  describe "UMOUNT" do
    test "stops the session and drops the registry entry", context do
      sid = mount!(context)
      pid = hold_descriptor(context, sid)

      assert {response, _args} = call(context, sid, 9, :umount, %{})
      assert response.status == :success

      # The session sends its answer and only then stops, so the reply can
      # legitimately arrive a moment before the process is gone.
      #
      # The descriptors were opened `:raw`, so they belong to that process and
      # the VM reclaims them with it. What the test can observe is that the
      # process really does go away rather than lingering with its files.
      wait_until(fn -> not Process.alive?(pid) end)
      wait_until(fn -> SessionRegistry.lookup(sid) == :error end)
    end

    test "frees the per-IP slot so the same client can mount again", context do
      for seq <- 0..(4 * 3) do
        sid = mount!(context, seq: seq)
        {response, _args} = call(context, sid, 200, :umount, %{})
        assert response.status == :success

        # UMOUNT is answered before the session finishes stopping, so the slot
        # is freed just after the reply, not with it. The limit is 4 per IP;
        # without the release this loop would still fail on the fifth mount.
        wait_until(fn -> SessionRegistry.count() == 0 end)
      end

      assert SessionRegistry.count() == 0
    end
  end

  describe "a session that dies" do
    test "leaves nothing registered and is not resurrected", context do
      sid = mount!(context)
      pid = hold_descriptor(context, sid)

      Process.exit(pid, :kill)
      wait_until(fn -> SessionRegistry.lookup(sid) == :error end)

      # It is not silently resurrected as an empty session under the old
      # SID: the client is told to mount again (handoff section 3.1).
      {response, _args} = call(context, sid, 9, :stat, %{path: "/hello.txt"})
      assert response.status == :ebadsession
    end

    test "does not take the server with it", context do
      first = mount!(context)
      Process.exit(hold_descriptor(context, first), :kill)

      second = mount!(context, seq: 1, socket: client_socket())
      {response, _args} = call(context, second, 1, :stat, %{path: "/hello.txt"})
      assert response.status == :success
    end

    test "gives back its queue counter instead of charging it to the next SID",
         context do
      # The counter is incremented before the request is sent to the session and
      # decremented when the answer comes back. A session killed with requests
      # still queued never decrements them, so the count has to be dropped with
      # the session rather than left for whoever is handed that SID next - a
      # leftover count is permanent, and a SID inheriting `max_session_queue` of
      # it would be answered EAGAIN forever.
      sid = mount!(context)
      pid = hold_descriptor(context, sid)

      # Queued directly rather than by sending real requests. A request that is
      # answered decrements its own counter, so a test made of ordinary traffic
      # would read zero whether or not the session's counter is dropped, and
      # would pass against a server that leaks. These three stand for requests
      # that were queued and will now never be answered.
      for _queued <- 1..3, do: :ok = Limits.enqueue(sid, context.config.max_session_queue)
      assert Limits.backlog(sid) == 3

      Process.exit(pid, :kill)
      wait_until(fn -> SessionRegistry.lookup(sid) == :error end)

      assert Limits.backlog(sid) == 0
    end
  end

  describe "idle timeout" do
    @tag config: [read_only: false, session_timeout_ms: 120]
    test "reaps a session that stopped talking", context do
      sid = mount!(context)
      pid = hold_descriptor(context, sid)

      wait_until(fn -> not Process.alive?(pid) end, 2_000)
      assert SessionRegistry.lookup(sid) == :error
    end

    @tag config: [read_only: false, session_timeout_ms: 300]
    test "a session that keeps talking is not reaped", context do
      sid = mount!(context)

      for seq <- 1..4 do
        Process.sleep(100)
        {response, _args} = call(context, sid, seq, :stat, %{path: "/hello.txt"})
        assert response.status == :success
      end
    end
  end

  describe "in-flight accounting" do
    test "every request gives its slot back", context do
      sid = mount!(context)

      for seq <- 1..30 do
        {response, _args} = call(context, sid, seq, :stat, %{path: "/hello.txt"})
        assert response.status == :success
      end

      # A slot that is taken and never released is the failure mode that only
      # shows up under load, so it is asserted directly.
      wait_until(fn -> Enum.all?(partitions(context), &(Limits.in_flight(&1) == 0)) end)
    end

    test "a request that is rejected does not consume a slot", context do
      # An unknown SID never reaches a session, and the listener must still
      # balance its own counter.
      for _index <- 1..20 do
        assert {%{status: :ebadsession}, _args} =
                 call(context, 0xBEEF, 1, :stat, %{path: "/hello.txt"})
      end

      wait_until(fn -> Enum.all?(partitions(context), &(Limits.in_flight(&1) == 0)) end)
    end
  end

  describe "handle exhaustion" do
    test "is reported and then recovers on CLOSE", context do
      sid = mount!(context)

      handles =
        for seq <- 1..4 do
          {response, args} =
            call(context, sid, seq, :open, %{flags: @create, mode: 0o644, path: "/f#{seq}"})

          assert response.status == :success
          args.handle
        end

      {response, _args} =
        call(context, sid, 5, :open, %{flags: @create, mode: 0o644, path: "/overflow"})

      assert response.status == :emfile

      {response, _args} = call(context, sid, 6, :close, %{handle: hd(handles)})
      assert response.status == :success

      {response, _args} =
        call(context, sid, 7, :open, %{flags: @create, mode: 0o644, path: "/again"})

      assert response.status == :success
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Leaves the session holding an open descriptor and returns its pid, so that
  # a test can end the session the hard way and still expect a clean exit.
  defp hold_descriptor(context, sid) do
    {:ok, pid, _address} = SessionRegistry.lookup(sid)

    {response, _args} =
      call(context, sid, 1, :open, %{flags: @create, mode: 0o644, path: "/held"})

    assert response.status == :success
    pid
  end

  defp partitions(context), do: 0..(context.config.dispatch_partitions - 1)

  defp wait_until(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition never became true")
      true -> Process.sleep(10) && do_wait(fun, deadline)
    end
  end
end
