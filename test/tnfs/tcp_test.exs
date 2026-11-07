defmodule Tnfs.TCPTest do
  @moduledoc """
  Legacy TCP transport: frame reassembly, coalescing, limits and teardown.
  """

  use Tnfs.ServerCase, async: false

  import Bitwise

  alias Tnfs.SessionRegistry
  alias Tnfs.Status
  alias Tnfs.Transport.TCP.Listener

  @moduletag config: [transports: :both, read_only: false]

  setup context do
    File.write!(Path.join(context.root, "hello.txt"), "hello world")
    %{tcp_port: Listener.port()}
  end

  describe "framing" do
    test "answers a request sent in one piece", context do
      socket = connect(context)
      sid = tcp_mount!(socket, context)

      response = exchange(socket, context, sid, 1, :stat, %{path: "/hello.txt"})
      assert response.status == :success
    end

    test "reassembles a request split into single bytes", context do
      socket = connect(context)
      sid = tcp_mount!(socket, context)

      {:ok, request} = Protocol.encode_request(sid, 1, :stat, %{path: "/hello.txt"})

      for <<byte <- request>> do
        :ok = :gen_tcp.send(socket, <<byte>>)
      end

      assert %{status: :success} = receive_response(socket, context)
    end

    test "reassembles at every possible split point", context do
      socket = connect(context)
      sid = tcp_mount!(socket, context)

      {:ok, request} = Protocol.encode_request(sid, 1, :stat, %{path: "/hello.txt"})

      for split <- 1..(byte_size(request) - 1) do
        <<head::binary-size(^split), tail::binary>> = request

        :ok = :gen_tcp.send(socket, head)
        :ok = :gen_tcp.send(socket, tail)

        assert %{status: :success} = receive_response(socket, context),
               "split after #{split} bytes was not reassembled"
      end
    end

    test "separates two requests that arrive coalesced", context do
      socket = connect(context)
      sid = tcp_mount!(socket, context)

      {:ok, first} = Protocol.encode_request(sid, 1, :stat, %{path: "/hello.txt"})
      {:ok, second} = Protocol.encode_request(sid, 2, :stat, %{path: "/missing"})

      :ok = :gen_tcp.send(socket, first <> second)

      assert %{status: :success, seq: 1} = receive_response(socket, context)
      assert %{status: :enoent, seq: 2} = receive_response(socket, context)
    end

    test "frames a WRITE by its declared length, not by a terminator", context do
      socket = connect(context)
      sid = tcp_mount!(socket, context)

      handle = tcp_open!(socket, context, sid, 1, "/new.bin", 0x0002 ||| 0x0100)

      # The payload deliberately contains NUL bytes: a parser looking for a
      # string terminator would cut the frame in the wrong place.
      data = <<0, 1, 2, 0, 0, 3>>
      response = exchange(socket, context, sid, 2, :write, %{handle: handle, data: data})

      assert response.status == :success
      assert exchange(socket, context, sid, 3, :close, %{handle: handle}).status == :success
      assert File.read!(Path.join(context.root, "new.bin")) == data
    end
  end

  describe "connection teardown" do
    test "an unknown command is answered once and then the connection closes",
         context do
      socket = connect(context)
      sid = tcp_mount!(socket, context)

      # 0x7f has no schema, so the server cannot know where this frame ends.
      :ok = :gen_tcp.send(socket, <<sid::unsigned-little-16, 1, 0x7F>>)

      assert {:ok, <<_sid::16, 1, 0x7F, status>>} = :gen_tcp.recv(socket, 0, 1_000)
      assert status == Status.code(:enosys)
      assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
    end

    test "legacy OPEN cannot be delimited and closes the connection", context do
      socket = connect(context)
      sid = tcp_mount!(socket, context)

      :ok = :gen_tcp.send(socket, <<sid::unsigned-little-16, 1, 0x20, 0, 0>>)

      assert {:ok, <<_sid::16, 1, 0x20, status>>} = :gen_tcp.recv(socket, 0, 1_000)
      assert status == Status.code(:enosys)
      assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
    end

    test "a frame larger than one datagram closes the connection", context do
      socket = connect(context)
      sid = tcp_mount!(socket, context)

      # An OPENDIR whose path never terminates: the buffer grows and must be
      # cut off at the wire limit rather than forever.
      :ok = :gen_tcp.send(socket, <<sid::unsigned-little-16, 1, 0x10>>)
      :ok = :gen_tcp.send(socket, :binary.copy("a", 600))

      # The client is told why before the connection goes away, otherwise it
      # could not tell this apart from a network failure.
      assert {:ok, <<_sid::16, 1, 0x10, status>>} = :gen_tcp.recv(socket, 0, 1_000)
      assert status == Status.code(:e2big)
      assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
    end

    @tag config: [transports: :both, read_only: false, tcp_frame_timeout_ms: 100]
    test "a frame that is never finished times out", context do
      socket = connect(context)
      sid = tcp_mount!(socket, context)

      :ok = :gen_tcp.send(socket, <<sid::unsigned-little-16, 1, 0x10, ?a>>)

      assert :gen_tcp.recv(socket, 0, 2_000) == {:error, :closed}
    end

    test "closing a connection leaves the session alive for a reconnect",
         context do
      socket = connect(context)
      sid = tcp_mount!(socket, context)

      :ok = :gen_tcp.close(socket)
      Process.sleep(50)

      # The session belongs to the address, not to the connection, so it may
      # migrate to a new one (handoff section 3.1).
      assert {:ok, _pid, _address} = SessionRegistry.lookup(sid)

      other = connect(context)
      response = exchange(other, context, sid, 1, :stat, %{path: "/hello.txt"})
      assert response.status == :success
    end

    @tag config: [transports: :both, max_tcp_connections: 1]
    test "connections beyond the limit are closed immediately", context do
      first = connect(context)
      assert tcp_mount!(first, context) != 0

      second = connect(context)
      assert :gen_tcp.recv(second, 0, 1_000) == {:error, :closed}
    end

    @tag config: [transports: :both, read_only: false, tcp_send_timeout_ms: 200]
    test "a client that sends but never reads does not hold its slot forever",
         context do
      # A READ costs eight bytes on the wire and answers with 517, so a client
      # that pipelines requests and never reads makes the server produce 65
      # bytes for every one it spends. Both socket buffers fill, and then
      # `:gen_tcp.send/2` blocks inside `handle_info/2`.
      #
      # That is the part worth a test. A blocked connection process never
      # reaches its `:check` message, so neither the frame timeout nor the idle
      # timeout can fire, and it keeps one of `max_tcp_connections` slots for as
      # long as the peer cares to leave the socket open. `max_children` bounds
      # how many connections exist, not how long a connection may last, so
      # without a send timeout the admission limit can be filled permanently by
      # clients that never read a byte.
      socket = connect(context, recbuf: 1024)
      sid = tcp_mount!(socket, context)

      # The file has to be big enough that every one of the reads below returns
      # a full payload. A first attempt used a 4 KB file, and after eight reads
      # the handle was at EOF and every further answer was a five-byte status:
      # the buffers never filled, the send never blocked and the test passed
      # against the unfixed server for the wrong reason.
      reads = 4_000
      File.write!(Path.join(context.root, "big.bin"), :binary.copy("x", reads * 512))
      handle = tcp_open!(socket, context, sid, 1, "/big.bin", 0x0001)

      connection = only_connection()
      down = Process.monitor(connection)

      # The blast runs in its own process because the client's own `send` blocks
      # too once the server stops reading, and this test is about the server.
      blast =
        Task.async(fn ->
          Enum.each(2..reads, fn seq ->
            {:ok, request} =
              Protocol.encode_request(sid, rem(seq, 256), :read, %{
                handle: handle,
                requested: 512
              })

            :gen_tcp.send(socket, request)
          end)
        end)

      assert_receive {:DOWN, ^down, :process, ^connection, :normal}, 10_000

      Task.shutdown(blast, :brutal_kill)
    end
  end

  describe "both transports" do
    test "a session mounted over UDP can be used over TCP", context do
      sid = mount!(context)

      socket = connect(context)
      response = exchange(socket, context, sid, 1, :stat, %{path: "/hello.txt"})

      assert response.status == :success
    end
  end

  defp connect(context, opts \\ []) do
    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        context.tcp_port,
        [
          :binary,
          {:active, false},
          {:packet, :raw},
          {:nodelay, true}
        ] ++ opts
      )

    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  # The connection this test is about. Asserting there is exactly one is part of
  # the point: it proves the process being monitored is the one under test and
  # not a leftover from an earlier connection in the same server.
  defp only_connection do
    assert [{_id, pid, _type, _modules}] =
             DynamicSupervisor.which_children(Tnfs.Transport.TCP.ConnectionSupervisor)

    pid
  end

  defp exchange(socket, context, sid, seq, command, args) do
    {:ok, request} = Protocol.encode_request(sid, seq, command, args)
    :ok = :gen_tcp.send(socket, request)
    receive_response(socket, context)
  end

  # The client is the one that has to know how long a response is, so the test
  # reads the header first and then exactly the rest of the payload.
  defp receive_response(socket, context) do
    {:ok, header} = :gen_tcp.recv(socket, 5, 1_000)

    payload =
      case :gen_tcp.recv(socket, 0, 100) do
        {:ok, rest} -> rest
        {:error, :timeout} -> <<>>
      end

    {:ok, response, args} = Protocol.decode_response(header <> payload, context.config)
    Map.put(Map.from_struct(response), :args, args)
  end

  defp tcp_mount!(socket, context) do
    args = %{version: 0x0102, mount: "/", user: "", password: ""}
    response = exchange(socket, context, 0, 0, :mount, args)

    assert response.status == :success
    assert response.sid != 0
    response.sid
  end

  defp tcp_open!(socket, context, sid, seq, path, flags) do
    response =
      exchange(socket, context, sid, seq, :open, %{flags: flags, mode: 0o644, path: path})

    assert response.status == :success
    response.args.handle
  end
end
