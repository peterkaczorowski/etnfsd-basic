defmodule Tnfs.SessionTest do
  @moduledoc """
  Session lifecycle over a real UDP socket: MOUNT, UMOUNT, retransmission,
  sequence conflicts, timeouts and the session limits.
  """

  use Tnfs.ServerCase, async: false

  alias Tnfs.Session
  alias Tnfs.SessionRegistry

  describe "mount" do
    test "allocates a non-zero sid and reports the server version", context do
      {response, args} = call(context, 0, 0, :mount, mount_args())

      assert response.status == :success
      assert response.sid != 0
      assert args.version == context.config.server_version
      assert args.retry_ms == context.config.retry_ms
    end

    test "two mounts get different sessions", context do
      first = mount!(context, seq: 0)
      second = mount!(context, seq: 1)

      refute first == second
      assert SessionRegistry.count() == 2
    end

    @tag config: [root: nil]
    test "without an export root there is nothing to serve", context do
      {response, _args} = call(context, 0, 0, :mount, mount_args())

      assert response.status == :eacces
      assert response.sid == 0
      # Even a refused MOUNT carries the version, so a client can tell an old
      # server from a broken one.
      assert byte_size(response.payload) == 2
    end

    @tag config: [max_sessions: 2]
    test "the global session limit answers EUSERS", context do
      mount!(context, seq: 0)
      mount!(context, seq: 1)

      {response, _args} = call(context, 0, 2, :mount, mount_args())

      assert response.status == :eusers
      assert SessionRegistry.count() == 2
    end

    @tag config: [max_sessions_per_ip: 1]
    test "the per-address limit answers EUSERS", context do
      mount!(context, seq: 0)

      {response, _args} = call(context, 0, 1, :mount, mount_args())

      assert response.status == :eusers
    end

    test "a retransmitted mount replays the same sid instead of leaking one",
         context do
      {:ok, data} = Protocol.encode_request(0, 0, :mount, mount_args())

      first = roundtrip(context, data)
      second = roundtrip(context, data)

      assert first == second
      assert SessionRegistry.count() == 1
    end

    test "a different mount under the same sequence number is a new session",
         context do
      File.mkdir_p!(Path.join(context.root, "other"))

      first = mount!(context, seq: 0, mount: "/")
      second = mount!(context, seq: 0, mount: "/other")

      refute first == second
      assert SessionRegistry.count() == 2
    end
  end

  describe "umount" do
    test "closes the session and frees the sid", context do
      sid = mount!(context)

      {response, _args} = call(context, sid, 1, :umount, %{})
      assert response.status == :success

      # The registry entry disappears through the monitor, which is
      # asynchronous with respect to the reply.
      assert eventually(fn -> SessionRegistry.lookup(sid) == :error end)

      {response, _args} = call(context, sid, 2, :umount, %{})
      assert response.status == :ebadsession
      assert response.sid == 0
    end
  end

  describe "routing" do
    test "an unknown sid is answered with EBADSESSION and sid 0", context do
      {response, _args} = call(context, 0x1234, 0, :umount, %{})

      assert response.status == :ebadsession
      assert response.sid == 0
    end

    test "an unknown command is answered with ENOSYS and the header echoed back",
         context do
      sid = mount!(context)
      reply = roundtrip(context, <<sid::unsigned-little-16, 7, 0x7F>>)

      assert <<^sid::unsigned-little-16, 7, 0x7F, status>> = reply
      assert status == Tnfs.Status.code(:enosys)
    end

    test "a datagram too short to hold a header is dropped", context do
      assert roundtrip(context, <<1, 2, 3>>, timeout: 200) == :timeout
    end

    test "sessions of different sids run in parallel", context do
      first = mount!(context, seq: 0)
      second = mount!(context, seq: 1)

      {:ok, first_pid, _address} = SessionRegistry.lookup(first)
      {:ok, second_pid, _address} = SessionRegistry.lookup(second)

      refute first_pid == second_pid
      assert Session.info(first_pid).sid == first
      assert Session.info(second_pid).sid == second
    end
  end

  describe "retry cache" do
    test "an identical retransmission replays the stored bytes", context do
      sid = mount!(context)
      {:ok, data} = Protocol.encode_request(sid, 1, :stat, %{path: "/nothing"})

      first = roundtrip(context, data)
      second = roundtrip(context, data)

      assert first == second
    end

    test "the same sequence number with a different body is EPROTO and does not \
          destroy the cached answer",
         context do
      sid = mount!(context)

      {:ok, original} = Protocol.encode_request(sid, 1, :stat, %{path: "/a"})
      {:ok, conflicting} = Protocol.encode_request(sid, 1, :stat, %{path: "/b"})

      answer = roundtrip(context, original)

      conflict = roundtrip(context, conflicting)
      assert <<_sid::16, 1, _command, status>> <> _rest = conflict
      assert status == Tnfs.Status.code(:eproto)

      # The original answer must still be replayable: the conflict was refused
      # without executing and without overwriting the cache (ADR 8).
      assert roundtrip(context, original) == answer
    end
  end

  describe "timeout" do
    @tag config: [session_timeout_ms: 50]
    test "an idle session is collected and its resources freed", context do
      sid = mount!(context)
      {:ok, pid, _address} = SessionRegistry.lookup(sid)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      assert eventually(fn -> SessionRegistry.lookup(sid) == :error end)

      {response, _args} = call(context, sid, 1, :umount, %{})
      assert response.status == :ebadsession
    end
  end

  describe "crash isolation" do
    test "a dying session leaves the others alone", context do
      victim = mount!(context, seq: 0)
      survivor = mount!(context, seq: 1)

      {:ok, pid, _address} = SessionRegistry.lookup(victim)
      Process.exit(pid, :kill)

      assert eventually(fn -> SessionRegistry.lookup(victim) == :error end)

      # A killed session must not come back as an empty session under the old
      # sid; the client is told to mount again.
      {response, _args} = call(context, victim, 1, :umount, %{})
      assert response.status == :ebadsession

      {response, _args} = call(context, survivor, 2, :umount, %{})
      assert response.status == :success
    end
  end

  defp mount_args, do: %{version: 0x0102, mount: "/", user: "", password: ""}

  defp eventually(check, attempts \\ 50)
  defp eventually(_check, 0), do: false

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(10)
      eventually(check, attempts - 1)
    end
  end
end
