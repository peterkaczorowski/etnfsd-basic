defmodule Tnfs.TCPPipelineTest do
  @moduledoc """
  What one TCP connection may hold, and what it may do before it looks at its
  mailbox again.

  A TCP read is not a request, and the two bounds that follow from that are
  different bounds. `Tnfs.Protocol.frame_length/2` already refuses a *partial*
  frame longer than one datagram, so a client that dribbles cannot grow the
  buffer. It says nothing about a read made entirely of complete frames: at the
  driver's default read size of 9216 bytes one message can carry two thousand
  four-byte requests, and the connection used to answer every one of them in a
  single callback - during which it read neither its own frame timeout, nor its
  idle timeout, nor a shutdown.

  So these tests pin both: the bytes this process holds, and the frames it
  answers before handing the mailbox back.
  """

  use Tnfs.ServerCase, async: false

  alias Tnfs.Status
  alias Tnfs.Transport.TCP.ConnectionSupervisor
  alias Tnfs.Transport.TCP.Listener

  @loopback {127, 0, 0, 1}

  # A STAT of a path that does not exist is answered with a bare five byte
  # header, which is what makes a flood countable: N requests are exactly 5 * N
  # bytes of answer, in order, and nothing else can be in the stream.
  @miss_size 5

  # The READ size the speed tool uses, and the protocol maximum.
  @chunk 512

  # TNFS O_RDONLY.
  @rdonly 0x0001

  @moduletag config: [transports: :both, read_only: false]

  setup do
    %{tcp_port: Listener.port()}
  end

  describe "reassembly" do
    test "a frame of exactly max_datagram bytes survives arriving one byte at a time",
         context do
      socket = connect(context)
      sid = mount(socket)

      request = miss(sid, 1, longest_path(context))
      assert byte_size(request) == context.config.max_datagram

      for <<byte <- request>>, do: :ok = :gen_tcp.send(socket, <<byte>>)

      assert answers(socket, 1) == [1]
    end

    test "a complete frame followed by an unfinished one answers the first and waits",
         context do
      socket = connect(context)
      sid = mount(socket)

      # An OPENDIR whose path has not been terminated yet. The first request is
      # complete and must not be held up by it, and the second must not be
      # guessed at.
      :ok = :gen_tcp.send(socket, miss(sid, 1, "/nope") <> <<sid::unsigned-little-16, 2, 0x10>>)

      assert answers(socket, 1) == [1]
      assert :gen_tcp.recv(socket, 0, 200) == {:error, :timeout}

      :ok = :gen_tcp.send(socket, "/" <> <<0>>)
      assert {:ok, <<_sid::16, 2, 0x10, _status, _handle>>} = :gen_tcp.recv(socket, 6, 1_000)
    end
  end

  describe "pipelining" do
    test "a batch of coalesced requests is answered in order", context do
      socket = connect(context)
      sid = mount(socket)

      count = context.config.max_tcp_frames_per_batch
      :ok = :gen_tcp.send(socket, flood(sid, count))

      assert answers(socket, count) == Enum.to_list(1..count)
    end

    test "far more coalesced requests than one batch are answered in order, once each",
         context do
      socket = connect(context)
      sid = mount(socket)

      count = 250
      assert count > 4 * context.config.max_tcp_frames_per_batch

      :ok = :gen_tcp.send(socket, flood(sid, count))

      # In order and exactly once: a batched reader that restarted a batch would
      # repeat a sequence number, and one that lost its place would skip one.
      assert answers(socket, count) == Enum.to_list(1..count)
      assert :gen_tcp.recv(socket, 0, 200) == {:error, :timeout}
    end

    test "the buffer never exceeds the configured maximum while a flood drains",
         context do
      socket = connect(context)
      sid = mount(socket)
      connection = only_connection()

      # Sent and not read, which is the whole point: the server may not use this
      # client's silence as a reason to hold more than it said it would.
      :ok = :gen_tcp.send(socket, flood(sid, 250))

      samples = sample(connection, 400, fn state -> byte_size(state.buffer) end)

      assert Enum.max(samples) <= context.config.max_tcp_buffer
      assert answers(socket, 250) == Enum.to_list(1..250)
    end

    test "no callback answers more frames than the batch allows", context do
      socket = connect(context)
      sid = mount(socket)

      # Attached after the MOUNT, so every event counted below belongs to the
      # flood and the arithmetic at the end is exact.
      attach_telemetry([:tnfs, :tcp, :batch])

      count = 250
      :ok = :gen_tcp.send(socket, flood(sid, count))
      assert answers(socket, count) == Enum.to_list(1..count)

      batches = batch_sizes(count)

      # The bound itself, asserted rather than timed. A clock would have made
      # this a question about the machine; the count is the same fact without
      # the noise, and it is one the connection has to publish anyway to be
      # operable.
      assert Enum.max(batches) <= context.config.max_tcp_frames_per_batch

      # Every frame answered exactly once, and in more than one callback: the
      # sum says nothing was dropped or repeated, the length says the work was
      # actually handed back to the mailbox in between.
      assert Enum.sum(batches) == count
      assert length(batches) >= div(count, context.config.max_tcp_frames_per_batch)
    end

    test "a connection that is behind answers its mailbox anyway", context do
      socket = connect(context)
      sid = mount(socket)
      connection = only_connection()

      :ok = :gen_tcp.send(socket, flood(sid, 250))

      # `:sys.get_state/2` is a system message: it is answered between
      # callbacks and never inside one. So this cannot return at all until the
      # connection puts the flood down, which is what the batch bound makes it
      # do. The timeout is the assertion; the value is not looked at.
      assert %{buffer: _} = :sys.get_state(connection, 2_000)

      assert answers(socket, 250) == Enum.to_list(1..250)
    end

    test "another connection is answered while one floods", context do
      flooding = connect(context)
      flooding_sid = mount(flooding)

      quiet = connect(context)
      quiet_sid = mount(quiet)

      # Four floods queued back to back, so there is certainly one in flight
      # while the other connection is measured.
      blast =
        Task.async(fn ->
          for _ <- 1..4, do: :gen_tcp.send(flooding, flood(flooding_sid, 250))
        end)

      waits =
        for seq <- 1..20 do
          {us, answered} =
            :timer.tc(fn ->
              :ok = :gen_tcp.send(quiet, miss(quiet_sid, seq, "/nope"))
              answers(quiet, 1)
            end)

          assert answered == [seq]
          us
        end

      assert Enum.max(waits) < 500_000

      Task.await(blast, 10_000)
    end
  end

  describe "pipelined READ on one handle" do
    # The tests above flood with STATs, which are stateless: any order would
    # produce the same bytes and a repeat would go unnoticed. READ is the
    # opposite - every answer moves the file position, so the stream is the
    # only thing that says which answer belongs to which request. A downloader
    # that pipelines is betting its file on that, and these are the cases where
    # the bet could lose.

    test "consecutive READs return disjoint fragments that reassemble into the file",
         context do
      contents = fixture(context, "pipelined.bin", 4 * @chunk + 100)

      socket = connect(context)
      sid = mount(socket)
      handle = open!(socket, sid, 1, "/pipelined.bin")

      # All five at once, before any answer is read. This is exactly what the
      # downloader does, and the batch bound is smaller than five.
      batch =
        Enum.map_join(2..6, fn seq -> read_frame(sid, seq, handle, @chunk) end)

      :ok = :gen_tcp.send(socket, batch)

      answers = for _ <- 2..6, do: read_answer(socket)

      assert Enum.map(answers, &elem(&1, 0)) == Enum.to_list(2..6)
      assert Enum.all?(answers, &(elem(&1, 1) == :success))

      # Disjoint and in order: concatenating them in the order they arrived
      # reproduces the file. A duplicated or reordered answer fails here.
      assert answers |> Enum.map_join(&elem(&1, 2)) == contents
    end

    test "a repeated sequence number replays the previous answer and does not advance",
         context do
      contents = fixture(context, "replay.bin", 4 * @chunk)

      socket = connect(context)
      sid = mount(socket)
      handle = open!(socket, sid, 1, "/replay.bin")

      attach_telemetry([:tnfs, :session, :retry_hit])

      # Consecutive READs on one handle have byte-identical payloads, so a
      # client that forgets to increment `seq` hands the session a perfect
      # retransmission. The cached answer comes back with a success status and
      # the position does not move - a silently duplicated block, which is why
      # the pipelining client increments `seq` for every frame.
      repeat = read_frame(sid, 3, handle, @chunk)

      :ok =
        :gen_tcp.send(
          socket,
          read_frame(sid, 2, handle, @chunk) <>
            repeat <> repeat <> read_frame(sid, 4, handle, @chunk)
        )

      assert [first, second, replay, fourth] = for(_ <- 1..4, do: read_answer(socket))

      assert {2, :success, _} = first
      assert {3, :success, _} = second
      assert {3, :success, _} = replay
      assert {4, :success, _} = fourth

      assert_receive {:telemetry, [:tnfs, :session, :retry_hit], _measurements, _meta}, 1_000

      # The replay is the same bytes as the request it repeats, and the next
      # READ carries on from where the *first* of the two left off: three
      # answers covering only two chunks.
      assert elem(replay, 2) == elem(second, 2)
      assert elem(first, 2) <> elem(second, 2) == binary_part(contents, 0, 2 * @chunk)
      assert elem(fourth, 2) == binary_part(contents, 2 * @chunk, @chunk)
    end

    test "an error in the middle of a batch is answered in its place and the rest survive",
         context do
      contents = fixture(context, "midfail.bin", 4 * @chunk)

      socket = connect(context)
      sid = mount(socket)
      handle = open!(socket, sid, 1, "/midfail.bin")

      # A handle that was never opened, so the failure is the session's and not
      # the filesystem's, and it lands between two requests that must not be
      # disturbed by it.
      bad = handle + 1

      :ok =
        :gen_tcp.send(
          socket,
          read_frame(sid, 2, handle, @chunk) <>
            read_frame(sid, 3, bad, @chunk) <> read_frame(sid, 4, handle, @chunk)
        )

      assert [good, failed, after_failure] = for(_ <- 1..3, do: read_answer(socket))

      assert {2, :success, _} = good
      assert {3, :ebadf, <<>>} = failed
      assert {4, :success, _} = after_failure

      # The failure occupies its own position in the stream and consumes no
      # file position: the answer behind it is the *second* chunk, not the
      # third. A client that dropped the error frame would splice these two
      # together and produce a short file with no error anywhere in it.
      assert elem(good, 2) <> elem(after_failure, 2) == binary_part(contents, 0, 2 * @chunk)
    end

    test "a batch that overruns the end of the file gets EOF in order, data intact",
         context do
      # Server robustness, not downloader behaviour: the downloader's read plan
      # comes from STAT and never asks past the end. This says that a client
      # which does ask is answered rather than desynchronising the stream.
      contents = fixture(context, "short.bin", @chunk + 88)

      socket = connect(context)
      sid = mount(socket)
      handle = open!(socket, sid, 1, "/short.bin")

      :ok = :gen_tcp.send(socket, Enum.map_join(2..5, &read_frame(sid, &1, handle, @chunk)))

      assert [full, short, first_eof, second_eof] = for(_ <- 2..5, do: read_answer(socket))

      assert {2, :success, _} = full
      assert {3, :success, _} = short
      assert {4, :eof, <<>>} = first_eof
      assert {5, :eof, <<>>} = second_eof

      # A short read is a success, and EOF only once the position is at the
      # end. Everything before the overrun is the file, unaltered.
      assert byte_size(elem(short, 2)) == 88
      assert elem(full, 2) <> elem(short, 2) == contents
    end

    test "closing with answers still outstanding takes the connection, and only the connection",
         context do
      fixture(context, "abandoned.bin", 64 * @chunk)

      socket = connect(context)
      sid = mount(socket)
      handle = open!(socket, sid, 1, "/abandoned.bin")

      connection = only_connection()
      down = Process.monitor(connection)

      # Far more answers than the socket buffers will hold, then the client
      # walks away in the middle of one. The connection process must go with
      # it rather than sitting on a dead socket with a full send queue.
      :ok = :gen_tcp.send(socket, Enum.map_join(2..250, &read_frame(sid, &1, handle, @chunk)))
      :ok = :gen_tcp.close(socket)

      assert_receive {:DOWN, ^down, :process, ^connection, _reason}, 5_000
      wait_until(fn -> DynamicSupervisor.which_children(ConnectionSupervisor) == [] end)

      # The session, however, stays. A SID is not a connection: TNFS lets a
      # client come back to the same mount, so a dropped connection may not
      # take the session's handles with it. What collects an abandoned session
      # is the idle timeout, which `Tnfs.ResourcesTest` covers. A client that
      # expects its handles to be freed by hanging up is relying on something
      # the protocol does not promise.
      assert {:ok, _pid, _address} = Tnfs.SessionRegistry.lookup(sid)
    end

    test "the batch bound does not limit how many READs a client may have in flight",
         context do
      contents = fixture(context, "deep.bin", 40 * @chunk)
      depth = 5 * context.config.max_tcp_frames_per_batch

      socket = connect(context)
      sid = mount(socket)
      handle = open!(socket, sid, 1, "/deep.bin")

      # `max_tcp_frames_per_batch` bounds how many frames one callback answers
      # before it looks at its mailbox again. It is not a window: a client that
      # sends five times that many is not refused, and the documentation says
      # so. The speed tool's pipeline depth rests on this.
      assert depth > context.config.max_tcp_frames_per_batch

      :ok =
        :gen_tcp.send(socket, Enum.map_join(2..(depth + 1), &read_frame(sid, &1, handle, @chunk)))

      answers = for _ <- 1..depth, do: read_answer(socket)

      assert Enum.map(answers, &elem(&1, 0)) == Enum.to_list(2..(depth + 1))
      assert Enum.all?(answers, &(elem(&1, 1) == :success))
      assert answers |> Enum.map_join(&elem(&1, 2)) == binary_part(contents, 0, depth * @chunk)
    end
  end

  describe "the retained-byte bound" do
    test "the accepted socket may not hand over more than one datagram at a time",
         context do
      _socket = connect(context)
      state = :sys.get_state(only_connection())

      # The listener sets this, and the value matters: `inet_drv` picks 9216 by
      # default, which is two thousand four-byte requests in one message.
      assert {:ok, [buffer: buffer]} = :inet.getopts(state.socket, [:buffer])
      assert buffer == context.config.max_datagram
    end

    test "a delivery larger than the bound closes the connection even though the socket could not have produced it",
         context do
      _socket = connect(context)
      connection = only_connection()
      down = Process.monitor(connection)

      attach_telemetry([:tnfs, :tcp, :oversize])

      # Handed straight to the process rather than through the socket. The
      # option above is what makes this impossible in practice, and that is
      # exactly why the check may not rest on it: an invariant that holds only
      # because a driver accepted an option is the driver's invariant.
      send(
        connection,
        {:tcp, :not_a_socket, :binary.copy("x", context.config.max_tcp_buffer + 1)}
      )

      assert_receive {:telemetry, [:tnfs, :tcp, :oversize], measurements, _meta}, 1_000
      assert measurements.bytes == context.config.max_tcp_buffer + 1
      assert_receive {:DOWN, ^down, :process, ^connection, :normal}, 1_000
    end

    test "max_tcp_buffer must leave room for a datagram of leftover and a datagram delivered" do
      # 900 is more than one datagram and less than two, which is the size at
      # which a legal request split across two reads would trip the bound meant
      # to protect it.
      assert_raise ArgumentError, ~r/max_tcp_buffer/, fn ->
        Config.build!(max_tcp_buffer: 900)
      end
    end
  end

  describe "teardown" do
    test "everything answered before a policy close arrives once and in order", context do
      socket = connect(context)
      sid = mount(socket)

      count = 40

      # 0x7f has no schema, so the stream cannot be resynchronised after it and
      # the connection is closed. Everything in front of it was already a valid
      # request and is still owed an answer.
      :ok =
        :gen_tcp.send(socket, flood(sid, count) <> <<sid::unsigned-little-16, 250, 0x7F>>)

      assert answers(socket, count) == Enum.to_list(1..count)

      assert {:ok, <<_sid::16, 250, 0x7F, status>>} = :gen_tcp.recv(socket, 5, 1_000)
      assert status == Status.code(:enosys)
      assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
    end

    test "the connection and everything it held are gone once the client closes", context do
      socket = connect(context)
      sid = mount(socket)

      :ok = :gen_tcp.send(socket, flood(sid, 250))
      assert answers(socket, 250) == Enum.to_list(1..250)

      connection = only_connection()
      down = Process.monitor(connection)

      # Drained before the close, so what is measured is a connection that did
      # its work and then went away rather than one that was interrupted.
      state = :sys.get_state(connection)
      assert state.buffer == <<>>
      assert {:message_queue_len, 0} = Process.info(connection, :message_queue_len)

      :ok = :gen_tcp.close(socket)

      assert_receive {:DOWN, ^down, :process, ^connection, :normal}, 2_000
      assert DynamicSupervisor.which_children(ConnectionSupervisor) == []
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp connect(context, opts \\ []) do
    {:ok, socket} =
      :gen_tcp.connect(
        @loopback,
        context.tcp_port,
        [:binary, {:active, false}, {:packet, :raw}, {:nodelay, true}] ++ opts
      )

    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp mount(socket) do
    args = %{version: 0x0102, mount: "/", user: "", password: ""}
    {:ok, request} = Protocol.encode_request(0, 0, :mount, args)
    :ok = :gen_tcp.send(socket, request)

    assert {:ok, <<sid::unsigned-little-16, 0, 0x00, status, _rest::binary>>} =
             :gen_tcp.recv(socket, 9, 2_000)

    assert status == Status.code(:success)
    assert sid != 0
    sid
  end

  # A file of known, incompressible bytes: every chunk of it is distinguishable
  # from every other, so a duplicated or reordered answer cannot pass as the
  # right one.
  defp fixture(context, name, size) do
    contents = :crypto.strong_rand_bytes(size)
    File.write!(Path.join(context.root, name), contents)
    contents
  end

  defp open!(socket, sid, seq, path) do
    {:ok, request} =
      Protocol.encode_request(sid, seq, :open, %{flags: @rdonly, mode: 0, path: path})

    :ok = :gen_tcp.send(socket, request)

    assert {:ok, <<_sid::16, ^seq, 0x29, status, handle>>} = :gen_tcp.recv(socket, 6, 2_000)
    assert status == Status.code(:success)
    handle
  end

  defp read_frame(sid, seq, handle, requested) do
    {:ok, request} =
      Protocol.encode_request(sid, seq, :read, %{handle: handle, requested: requested})

    request
  end

  # One READ answer taken off the stream, framed the way the stream frames it:
  # five bytes of header, and on success a 16-bit length followed by exactly
  # that many bytes. Returns `{seq, status, data}`.
  defp read_answer(socket) do
    assert {:ok, <<_sid::16, seq, 0x21, code>>} = :gen_tcp.recv(socket, 5, 5_000)
    assert {:ok, status} = Status.fetch_name(code)

    if status == :success do
      assert {:ok, <<count::unsigned-little-16>>} = :gen_tcp.recv(socket, 2, 5_000)
      assert {:ok, data} = :gen_tcp.recv(socket, count, 5_000)
      {seq, status, data}
    else
      {seq, status, <<>>}
    end
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end

  # A STAT that is certain to miss, so the answer is a bare header.
  defp miss(sid, seq, path) do
    {:ok, request} = Protocol.encode_request(sid, seq, :stat, %{path: path})
    request
  end

  # `count` distinct requests as one binary. Distinct paths, so none of them can
  # be served from the session's retry cache, and distinct sequence numbers, so
  # none of them is a protocol error.
  defp flood(sid, count) do
    Enum.map_join(1..count, fn seq -> miss(sid, seq, "/missing-#{seq}") end)
  end

  # Reads exactly `count` miss answers and returns their sequence numbers.
  defp answers(socket, count) do
    assert {:ok, data} = :gen_tcp.recv(socket, @miss_size * count, 10_000)
    for <<_sid::16, seq, _command, _status <- data>>, do: seq
  end

  # The frame counts of every batch until `count` frames have been accounted
  # for. Waiting on the sum rather than draining the mailbox once, because the
  # last event is emitted just after the last response is written and the
  # client can therefore have read it already.
  defp batch_sizes(count) do
    collect = fn collect, acc ->
      if Enum.sum(acc) >= count do
        Enum.reverse(acc)
      else
        assert_receive {:telemetry, [:tnfs, :tcp, :batch], %{frames: frames}, _meta}, 2_000
        collect.(collect, [frames | acc])
      end
    end

    collect.(collect, [])
  end

  defp longest_path(context) do
    # header, the NUL the string codec writes, and the rest is path.
    "/" <> String.duplicate("a", context.config.max_datagram - 6)
  end

  # `:gen_tcp.connect/3` returns as soon as the handshake is done, which is
  # before the listener has accepted and handed the socket to a process. So this
  # waits rather than asserting on a race it would lose about half the time.
  defp only_connection(attempts \\ 200) do
    case DynamicSupervisor.which_children(ConnectionSupervisor) do
      [{_id, pid, _type, _modules}] ->
        pid

      other ->
        if attempts == 0, do: flunk("expected one connection, got #{inspect(other)}")
        Process.sleep(10)
        only_connection(attempts - 1)
    end
  end

  # `count` readings of a live connection's state, or as many as it stays alive
  # for. A dead process is not a failure here: the flood may simply have
  # finished, and what is being asserted is a maximum.
  defp sample(pid, count, fun) do
    Enum.reduce_while(1..count, [], fn _, acc ->
      case Process.alive?(pid) && safe_state(pid) do
        {:ok, state} -> {:cont, [fun.(state) | acc]}
        _gone -> {:halt, acc}
      end
    end)
  end

  defp safe_state(pid) do
    {:ok, :sys.get_state(pid, 5_000)}
  catch
    :exit, _reason -> :gone
  end

  defp attach_telemetry(event) do
    test = self()
    id = {__MODULE__, event, System.unique_integer()}

    :telemetry.attach(
      id,
      event,
      fn name, measurements, metadata, _ ->
        send(test, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end
end
