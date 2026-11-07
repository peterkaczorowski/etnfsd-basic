defmodule Tnfs.ReadPathCharacterizationTest do
  @moduledoc """
  What the read path actually does, established before anything watches it.

  The live transfer panel has to derive a position, a size and a rate from
  OPEN, READ, LSEEK and CLOSE. Every one of those derivations rests on an
  assumption about the existing server, and an assumption that is only written
  down in a design note is one that can quietly stop being true. These tests
  are the assumptions, asserted against the unmodified server over a real
  socket.

  Nothing here is about the panel. Each test would have been worth writing
  anyway; they are collected in one file because they were written for one
  reason.
  """

  use Tnfs.ServerCase, async: false

  @rdonly 0x0001

  setup %{root: root} do
    File.write!(Path.join(root, "a.bin"), :binary.copy(<<0xAA>>, 100))
    File.write!(Path.join(root, "b.bin"), :binary.copy(<<0xBB>>, 40))
    :ok
  end

  defp open!(context, sid, seq, path) do
    {response, args} =
      call(context, sid, seq, :open, %{flags: @rdonly, mode: 0, path: path})

    assert response.status == :success
    args.handle
  end

  defp read!(context, sid, seq, handle, count) do
    {response, args} = call(context, sid, seq, :read, %{handle: handle, requested: count})
    {response.status, Map.get(args, :data, <<>>)}
  end

  defp lseek!(context, sid, seq, handle, whence, offset) do
    {response, args} =
      call(context, sid, seq, :lseek, %{handle: handle, whence: whence, offset: offset})

    assert response.status == :success
    args.position
  end

  test "one session holds several read handles at once, and they do not share a position",
       context do
    sid = mount!(context)

    a = open!(context, sid, 1, "/a.bin")
    b = open!(context, sid, 2, "/b.bin")

    # Distinct handles for distinct files. If this ever collapsed to one, a
    # panel keyed on the session alone would merge two downloads into one.
    assert a != b

    assert {:success, <<0xAA, 0xAA, 0xAA, 0xAA>>} = read!(context, sid, 3, a, 4)
    # Reading `a` did not move `b`.
    assert {:success, <<0xBB, 0xBB>>} = read!(context, sid, 4, b, 2)
    assert {:success, <<0xAA>>} = read!(context, sid, 5, a, 1)

    assert lseek!(context, sid, 6, a, 1, 0) == 5
    assert lseek!(context, sid, 7, b, 1, 0) == 2
  end

  test "a closed handle number is handed out again, with no trace of the file it was",
       context do
    sid = mount!(context)

    a = open!(context, sid, 1, "/a.bin")
    assert {:success, _data} = read!(context, sid, 2, a, 50)
    assert lseek!(context, sid, 3, a, 1, 0) == 50

    {response, _args} = call(context, sid, 4, :close, %{handle: a})
    assert response.status == :success

    # The lowest free number, so the same integer comes back. Identity for
    # anything tracking a transfer therefore cannot be the handle alone: it
    # has to carry something that distinguishes this open from the last one.
    b = open!(context, sid, 5, "/b.bin")
    assert b == a

    # And the position starts at zero, not at 50.
    assert lseek!(context, sid, 6, b, 1, 0) == 0
    assert {:success, <<0xBB, 0xBB, 0xBB>>} = read!(context, sid, 7, b, 3)
  end

  test "a retransmitted READ replays the stored bytes and does not advance the file",
       context do
    sid = mount!(context)
    handle = open!(context, sid, 1, "/a.bin")

    {:ok, request} =
      Protocol.encode_request(sid, 2, :read, %{handle: handle, requested: 8})

    first = roundtrip(context, request)
    second = roundtrip(context, request)

    # Byte for byte, because it is the cached response and not a second read.
    assert first == second

    # The proof that it was not executed twice: eight bytes were consumed, not
    # sixteen. Anything counting delivered bytes at this layer would count
    # sixteen and would be wrong about the file, though right about the wire.
    assert lseek!(context, sid, 3, handle, 1, 0) == 8
  end

  test "LSEEK backwards makes the following READ return bytes already returned", context do
    sid = mount!(context)
    handle = open!(context, sid, 1, "/a.bin")

    assert {:success, first} = read!(context, sid, 2, handle, 16)
    assert byte_size(first) == 16
    assert lseek!(context, sid, 3, handle, 0, 4) == 4
    assert {:success, again} = read!(context, sid, 4, handle, 16)

    # Twelve of these sixteen bytes have been sent before. A counter of bytes
    # served would now read 32 for a 100 byte file, so coverage and throughput
    # cannot be the same number.
    assert byte_size(again) == 16
    assert lseek!(context, sid, 5, handle, 1, 0) == 20
  end

  test "a short read is a success and only a read at the end is EOF", context do
    sid = mount!(context)
    handle = open!(context, sid, 1, "/b.bin")

    assert lseek!(context, sid, 2, handle, 2, 0) == 40
    assert lseek!(context, sid, 3, handle, 0, 36) == 36

    # Asked for 512, got the last four bytes: a success, not a truncation and
    # not an error.
    assert {:success, tail} = read!(context, sid, 4, handle, 512)
    assert byte_size(tail) == 4

    # Now at the end. This one is EOF, and EOF carries no payload.
    assert {:eof, <<>>} = read!(context, sid, 5, handle, 512)

    # Seeking past the end is legal and a read there is still EOF, never a
    # negative or wrapped position.
    assert lseek!(context, sid, 6, handle, 0, 1_000) == 1_000
    assert {:eof, <<>>} = read!(context, sid, 7, handle, 16)
  end

  test "a READ is clamped to the wire limit however much the client asks for", context do
    sid = mount!(context)
    handle = open!(context, sid, 1, "/a.bin")

    assert {:success, data} = read!(context, sid, 2, handle, 0xFFFF)
    assert byte_size(data) == min(100, context.config.max_io)
  end
end
