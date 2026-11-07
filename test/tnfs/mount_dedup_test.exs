defmodule Tnfs.MountDedupTest do
  @moduledoc """
  MOUNT deduplication must not confuse "the same client twice" with "two
  clients that look alike".

  A retransmitted MOUNT has to return the first answer, or every lost reply
  leaks a session. But the retry cache used to be keyed by source address
  alone, and an address is not a client: two machines behind one NAT send the
  same bytes from the same address, and inside the retry window they were handed
  one SID - and with it one shared handle table.

  These tests pin both halves: the cache is keyed by transport identity, while
  session binding stays address-based as ADR 2 requires.
  """

  use Tnfs.ServerCase, async: false

  alias Tnfs.MountCache
  alias Tnfs.SessionRegistry
  alias Tnfs.Transport.TCP.Listener

  @loopback {127, 0, 0, 1}
  @moduletag config: [read_only: false]

  setup context do
    File.write!(Path.join(context.root, "hello.txt"), "hello world")
    :ok
  end

  describe "UDP" do
    test "a retransmitted MOUNT returns the first SID and starts no second session",
         context do
      before = SessionRegistry.count()

      first = mount!(context, seq: 7)
      second = mount!(context, seq: 7)

      assert first == second
      assert SessionRegistry.count() == before + 1
    end

    test "two sockets behind one address get two sessions, not one", context do
      left = client_socket()
      right = client_socket()

      # Byte for byte the same request, from the same address, inside the retry
      # window - the situation two clients behind a NAT actually produce.
      left_sid = mount!(context, socket: left, seq: 0)
      right_sid = mount!(context, socket: right, seq: 0)

      refute left_sid == right_sid
      assert length(SessionRegistry.sids_for(@loopback)) == 2

      # Two sessions, so two handle tables: the point of not merging them.
      handle = open!(context, left_sid, 1, "/hello.txt", socket: left)

      assert {%{status: :ebadf}, _args} =
               call(context, right_sid, 1, :read, %{handle: handle, requested: 4}, socket: right)
    end

    test "an established session is reachable from any source port of its address",
         context do
      sid = mount!(context)
      other = client_socket()

      # ADR 2 binds a session to the address, deliberately not to the port: a
      # NAT may rewrite the port between two datagrams of one client.
      assert {%{status: :success}, _args} =
               call(context, sid, 1, :stat, %{path: "/hello.txt"}, socket: other)
    end
  end

  describe "TCP" do
    @describetag config: [transports: :both, read_only: false]

    setup do
      %{tcp_port: Listener.port()}
    end

    test "a retransmitted MOUNT on one connection returns the first SID", context do
      socket = connect(context)
      before = SessionRegistry.count()

      first = tcp_mount!(socket, context, 3)
      second = tcp_mount!(socket, context, 3)

      assert first == second
      assert SessionRegistry.count() == before + 1
    end

    test "two connections from one address get two sessions", context do
      left = connect(context)
      right = connect(context)

      left_sid = tcp_mount!(left, context, 0)
      right_sid = tcp_mount!(right, context, 0)

      refute left_sid == right_sid
      assert length(SessionRegistry.sids_for(@loopback)) == 2
    end

    test "a reconnecting client is not handed the closed connection's session",
         context do
      socket = connect(context)
      first = tcp_mount!(socket, context, 0)

      :ok = :gen_tcp.close(socket)
      Process.sleep(50)

      # The connection identity is a reference, so the kernel reusing the
      # source port cannot make the next connection look like this one.
      second = tcp_mount!(connect(context), context, 0)
      refute first == second
    end
  end

  describe "the retry cache" do
    @describetag config: [read_only: false, mount_dedup_ttl_ms: 50]

    test "stops deduplicating once the window has passed", context do
      first = mount!(context, seq: 9)
      Process.sleep(120)
      second = mount!(context, seq: 9)

      refute first == second
    end

    @tag config: [
           read_only: false,
           max_sessions: 1,
           max_sessions_per_ip: 1,
           max_mount_dedup_entries: 8
         ]
    test "stays bounded however many peers mount", context do
      limit = context.config.max_mount_dedup_entries

      # Every cycle is a distinct peer, so per-address keying could not have
      # grown the cache at all and per-peer keying would grow it without bound.
      for _cycle <- 1..(limit * 5) do
        socket = client_socket()
        sid = mount!(context, socket: socket, seq: 0)

        assert {%{status: :success}, _args} =
                 call(context, sid, 1, :umount, %{}, socket: socket)

        wait_until(fn -> SessionRegistry.count() == 0 end)

        assert MountCache.size() <= limit
      end

      assert MountCache.size() <= limit

      # The expiry index is a second table, and a second table is a second
      # thing to leak. It must hold exactly one key per entry: eviction and
      # replacement both have to remove the key they are superseding.
      assert MountCache.index_size() == MountCache.size()
    end

    test "empties itself after the window without another MOUNT", context do
      # The cache used to be pruned only by an insert that found it at its
      # limit, which was `4 * max_sessions` - so a server configured for many
      # sessions kept every expired entry until it was four times that far
      # along, and one that went quiet after a burst kept them for ever. A soak
      # measured 14,520 entries and 8.6 MB still resident three windows after
      # the last MOUNT.
      #
      # Distinct peers, because that is the shape that grows the cache: one
      # socket mounting repeatedly reuses a single key.
      for _client <- 1..8 do
        mount!(context, socket: client_socket(), seq: 0)
      end

      assert MountCache.size() > 0

      # Nothing mounts from here on. Every entry is past the window well before
      # this wait ends, so anything still resident is memory that no request
      # could ever have been served from.
      wait_until(fn -> MountCache.size() == 0 end)
      assert MountCache.index_size() == 0
    end

    @tag config: [read_only: false, mount_dedup_ttl_ms: 5_000]
    test "one peer mounting again and again costs one entry", context do
      socket = client_socket()

      # Replacement is the case that leaks an index: the entry is overwritten in
      # place, so the key of the expiry record it used to own has to be deleted
      # explicitly or the ordered set grows for ever while the cache does not.
      for seq <- 0..40 do
        sid = mount!(context, socket: socket, seq: seq)

        assert {%{status: :success}, _args} =
                 call(context, sid, 200, :umount, %{}, socket: socket)

        wait_until(fn -> SessionRegistry.count() == 0 end)
      end

      assert MountCache.size() == 1
      assert MountCache.index_size() == 1
    end
  end

  defp open!(context, sid, seq, path, opts) do
    {response, args} =
      call(context, sid, seq, :open, %{flags: 0x0001, mode: 0o644, path: path}, opts)

    assert response.status == :success
    args.handle
  end

  defp connect(context) do
    {:ok, socket} =
      :gen_tcp.connect(@loopback, context.tcp_port, [
        :binary,
        {:active, false},
        {:packet, :raw},
        {:nodelay, true}
      ])

    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp tcp_mount!(socket, _context, seq) do
    args = %{version: 0x0102, mount: "/", user: "", password: ""}
    {:ok, request} = Protocol.encode_request(0, seq, :mount, args)
    :ok = :gen_tcp.send(socket, request)

    {:ok, <<sid::unsigned-little-16, ^seq, 0x00, status, _rest::binary>>} =
      :gen_tcp.recv(socket, 9, 1_000)

    assert status == Tnfs.Status.code(:success)
    assert sid != 0
    sid
  end

  defp wait_until(check, attempts \\ 100) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(check, attempts - 1)
    end
  end
end
