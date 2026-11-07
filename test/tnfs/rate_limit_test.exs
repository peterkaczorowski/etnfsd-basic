defmodule Tnfs.RateLimitTest do
  @moduledoc """
  The token bucket exists to make unauthenticated traffic expensive, not to
  meter a client that has already mounted.

  The TCP connection process used to take a token for every frame as well, so
  an established session was capped at the handshake rate - and with a small
  enough limit a valid MOUNT was accepted by the connection, then dropped by
  the router, and the client was left without an answer at all. These tests pin
  where the charge happens and how often.
  """

  use Tnfs.ServerCase, async: false

  alias Tnfs.Limits
  alias Tnfs.Status
  alias Tnfs.Transport.TCP.Listener

  @loopback {127, 0, 0, 1}

  # A window long enough that nothing refills mid-test: these assertions are
  # about how many tokens a request costs, not about the refill timer.
  @moduletag config: [read_only: false, rate_limit_window_ms: 60_000]

  setup context do
    File.write!(Path.join(context.root, "hello.txt"), "hello world")
    :ok
  end

  describe "an established session" do
    @tag config: [read_only: false, rate_limit_window_ms: 60_000, rate_limit_per_window: 1]
    test "may issue far more UDP requests than the limit", context do
      sid = mount!(context)

      for seq <- 1..50 do
        assert {%{status: :success}, _args} =
                 call(context, sid, rem(seq, 256), :stat, %{path: "/hello.txt"}),
               "request #{seq} was throttled"
      end
    end

    @tag config: [
           transports: :both,
           read_only: false,
           rate_limit_window_ms: 60_000,
           rate_limit_per_window: 1
         ]
    test "may issue far more TCP requests than the limit", _context do
      socket = connect(Listener.port())

      # The single token this window allows goes to the MOUNT. With a second
      # bucket in the connection process the MOUNT itself went unanswered.
      sid = tcp_mount!(socket)

      for seq <- 1..50 do
        assert tcp_stat(socket, sid, rem(seq, 256)) == Status.code(:success),
               "request #{seq} was throttled"
      end
    end

    @tag config: [read_only: false, rate_limit_window_ms: 60_000, rate_limit_per_window: 5]
    test "spends no tokens once it exists", context do
      sid = mount!(context)

      # The MOUNT itself cost exactly one.
      assert Limits.tokens(@loopback, 5) == 4

      for seq <- 1..20 do
        assert {%{status: :success}, _args} =
                 call(context, sid, rem(seq, 256), :stat, %{path: "/hello.txt"})
      end

      assert Limits.tokens(@loopback, 5) == 4
    end
  end

  describe "sessionless traffic" do
    @tag config: [read_only: false, rate_limit_window_ms: 60_000, rate_limit_per_window: 3]
    test "is charged exactly one token per request", context do
      # An unknown SID is the cheapest way to probe the SID space, so it is
      # metered - once, in the router, and nowhere else.
      assert {%{status: :ebadsession, sid: 0}, _args} =
               call(context, 0xBEEF, 1, :stat, %{path: "/hello.txt"})

      assert Limits.tokens(@loopback, 3) == 2

      assert {%{status: :ebadsession, sid: 0}, _args} =
               call(context, 0xBEEF, 2, :stat, %{path: "/hello.txt"})

      assert Limits.tokens(@loopback, 3) == 1
    end

    @tag config: [read_only: false, rate_limit_window_ms: 60_000, rate_limit_per_window: 2]
    test "goes unanswered over UDP once the budget is spent", context do
      for seq <- 1..2 do
        assert {%{status: :ebadsession}, _args} =
                 call(context, 0xBEEF, seq, :stat, %{path: "/hello.txt"})
      end

      assert call(context, 0xBEEF, 3, :stat, %{path: "/hello.txt"}, timeout: 300) == :timeout
    end

    @tag config: [
           transports: :both,
           read_only: false,
           rate_limit_window_ms: 60_000,
           rate_limit_per_window: 2
         ]
    test "costs the connection over TCP once the budget is spent", _context do
      socket = connect(Listener.port())

      for seq <- 1..2 do
        assert tcp_stat(socket, 0xBEEF, seq) == Status.code(:ebadsession)
      end

      # Unlike UDP there is a connection to take away, so a peer that keeps
      # spending on error traffic loses it rather than being ignored forever.
      {:ok, request} = Protocol.encode_request(0xBEEF, 3, :stat, %{path: "/hello.txt"})
      :ok = :gen_tcp.send(socket, request)
      assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
    end
  end

  describe "the bucket table" do
    @tag config: [read_only: false, rate_limit_window_ms: 100, rate_limit_buckets: 32]
    test "does not grow with the number of forged source addresses", _context do
      # A UDP source address is whatever the sender wrote in the packet, so an
      # address-keyed table is a table whose size the attacker picks. This one
      # is keyed by bucket index instead, and 500 addresses fit in 32 rows the
      # same way 500 million would.
      for octet <- 1..500, do: Limits.allow?({10, 0, div(octet, 256), rem(octet, 256)}, 1)

      assert :ets.info(:tnfs_rate_buckets, :size) <= 32

      # Clearing is still how the window refills, so the table also returns to
      # nothing when the traffic stops. The standing bound, though, is the
      # bucket count - the window timer is no longer what keeps memory finite.
      wait_until(fn -> :ets.info(:tnfs_rate_buckets, :size) == 0 end)
    end
  end

  defp wait_until(fun, timeout \\ 2_000) do
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

  defp connect(port) do
    {:ok, socket} =
      :gen_tcp.connect(@loopback, port, [
        :binary,
        {:active, false},
        {:packet, :raw},
        {:nodelay, true}
      ])

    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp tcp_mount!(socket) do
    args = %{version: 0x0102, mount: "/", user: "", password: ""}
    {:ok, request} = Protocol.encode_request(0, 0, :mount, args)
    :ok = :gen_tcp.send(socket, request)

    assert {:ok, <<sid::unsigned-little-16, 0, 0x00, status, _rest::binary>>} =
             :gen_tcp.recv(socket, 9, 1_000)

    assert status == Status.code(:success)
    sid
  end

  # STAT answers with a 22 byte payload on success, and nothing on failure. The
  # payload has to be drained or the next response is read misaligned.
  @stat_payload 22

  defp tcp_stat(socket, sid, seq) do
    {:ok, request} = Protocol.encode_request(sid, seq, :stat, %{path: "/hello.txt"})
    :ok = :gen_tcp.send(socket, request)

    {:ok, <<_sid::unsigned-little-16, ^seq, 0x24, status>>} = :gen_tcp.recv(socket, 5, 1_000)

    if status == Status.code(:success) do
      {:ok, _payload} = :gen_tcp.recv(socket, @stat_payload, 1_000)
    end

    status
  end
end
