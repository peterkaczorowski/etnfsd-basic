defmodule Tnfs.ProtocolTest do
  use ExUnit.Case, async: true

  alias Tnfs.Command
  alias Tnfs.Config
  alias Tnfs.Protocol
  alias Tnfs.Protocol.Header
  alias Tnfs.Protocol.Request
  alias Tnfs.Protocol.Response

  @strict %Config{}
  @lax %Config{strict_decode: false}

  # Golden request vectors: {command, raw bytes, decoded args}.
  # Byte strings are written out literally so that a change in the codec cannot
  # quietly change the wire format.
  defp request_vectors do
    [
      {:mount, <<0x00, 0x00, 0x2A, 0x00, 0x03, 0x01, "/media", 0, "user", 0, "pass", 0>>,
       %{version: 0x0103, mount: "/media", user: "user", password: "pass"}},
      {:mount, <<0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0, 0, 0>>,
       %{version: 0x0103, mount: "", user: "", password: ""}},
      {:umount, <<0x34, 0x12, 0x01, 0x01>>, %{}},
      {:opendir, <<0x34, 0x12, 0x02, 0x10, "/", 0>>, %{path: "/"}},
      {:readdir, <<0x34, 0x12, 0x03, 0x11, 0x03>>, %{handle: 3}},
      {:closedir, <<0x34, 0x12, 0x04, 0x12, 0x07>>, %{handle: 7}},
      {:mkdir, <<0x34, 0x12, 0x05, 0x13, "/new", 0>>, %{path: "/new"}},
      {:rmdir, <<0x34, 0x12, 0x06, 0x14, "/old", 0>>, %{path: "/old"}},
      {:telldir, <<0x34, 0x12, 0x07, 0x15, 0x00>>, %{handle: 0}},
      {:seekdir, <<0x34, 0x12, 0x08, 0x16, 0x00, 0x04, 0x03, 0x02, 0x01>>,
       %{handle: 0, position: 0x01020304}},
      {:opendirx, <<0x34, 0x12, 0x09, 0x17, 0x10, 0x04, 0x00, 0x01, "*.atr", 0, "/games", 0>>,
       %{diropts: 0x10, sortopts: 0x04, max_results: 256, pattern: "*.atr", path: "/games"}},
      {:readdirx, <<0x34, 0x12, 0x0A, 0x18, 0x02, 0x00>>, %{handle: 2, requested: 0}},
      {:read, <<0x34, 0x12, 0x0B, 0x21, 0x05, 0x00, 0x02>>, %{handle: 5, requested: 512}},
      {:write, <<0x34, 0x12, 0x0C, 0x22, 0x05, 0x03, 0x00, "abc">>, %{handle: 5, data: "abc"}},
      {:write, <<0x34, 0x12, 0x0C, 0x22, 0x05, 0x00, 0x00>>, %{handle: 5, data: ""}},
      {:close, <<0x34, 0x12, 0x0D, 0x23, 0x0F>>, %{handle: 15}},
      {:stat, <<0x34, 0x12, 0x0E, 0x24, "/f.txt", 0>>, %{path: "/f.txt"}},
      {:lseek, <<0x34, 0x12, 0x0F, 0x25, 0x01, 0x02, 0xFF, 0xFF, 0xFF, 0xFF>>,
       %{handle: 1, whence: 2, offset: -1}},
      {:lseek, <<0x34, 0x12, 0x0F, 0x25, 0x01, 0x00, 0x00, 0x00, 0x00, 0x80>>,
       %{handle: 1, whence: 0, offset: -2_147_483_648}},
      {:unlink, <<0x34, 0x12, 0x10, 0x26, "/f.txt", 0>>, %{path: "/f.txt"}},
      {:chmod, <<0x34, 0x12, 0x11, 0x27, 0xA4, 0x01, "/f.txt", 0>>,
       %{mode: 0o644, path: "/f.txt"}},
      {:rename, <<0x34, 0x12, 0x12, 0x28, "/a", 0, "/b", 0>>, %{source: "/a", destination: "/b"}},
      {:open, <<0x34, 0x12, 0x13, 0x29, 0x03, 0x00, 0xA4, 0x01, "/f.txt", 0>>,
       %{flags: 0x0003, mode: 0o644, path: "/f.txt"}},
      {:size, <<0x34, 0x12, 0x14, 0x30>>, %{}},
      {:free, <<0x34, 0x12, 0x15, 0x31>>, %{}},
      {:sizebytes, <<0x34, 0x12, 0x16, 0x32>>, %{}},
      {:freebytes, <<0x34, 0x12, 0x17, 0x33>>, %{}}
    ]
  end

  describe "decode_request/2 golden vectors" do
    test "every vector decodes to the documented command and fields" do
      for {command, raw, args} <- request_vectors() do
        assert {:ok, %Request{} = request} = Protocol.decode_request(raw, @strict),
               "failed to decode #{command}"

        assert request.command == command
        assert request.command_id == Command.id(command)
        assert request.args == args
        assert request.raw == raw
      end
    end

    test "the vector table covers every command except legacy OPEN" do
      covered = request_vectors() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
      expected = Command.names() |> List.delete(:open_legacy) |> Enum.sort()
      assert covered == expected
    end

    test "header fields are little-endian and echoed verbatim" do
      for sid <- [0x0000, 0x0001, 0x00FF, 0x0100, 0xFFFF], seq <- [0x00, 0x01, 0xFF] do
        raw = <<sid::unsigned-little-16, seq, 0x30>>
        assert {:ok, request} = Protocol.decode_request(raw, @strict)
        assert request.sid == sid
        assert request.seq == seq
      end
    end

    test "legacy OPEN decodes but carries an opaque payload" do
      raw = <<0x34, 0x12, 0x01, 0x20, 1, 2, 3>>
      assert {:ok, request} = Protocol.decode_request(raw, @strict)
      assert request.command == :open_legacy
      assert request.args == %{payload: <<1, 2, 3>>}
    end
  end

  describe "decode_request/2 rejection matrix (handoff section 11)" do
    test "a header shorter than four bytes is dropped, not answered" do
      for size <- 0..3 do
        assert {:drop, :short_header} =
                 Protocol.decode_request(:binary.copy(<<0>>, size), @strict)
      end
    end

    test "an oversized datagram is dropped without partial processing" do
      raw = <<0x00, 0x00, 0x01, 0x24, :binary.copy("a", 600)::binary, 0>>
      assert {:drop, :oversize} = Protocol.decode_request(raw, @strict)
    end

    test "a datagram of exactly max_datagram bytes is still accepted" do
      padding = @strict.max_datagram - 5
      raw = <<0x00, 0x00, 0x01, 0x24, :binary.copy("a", padding)::binary, 0>>
      assert byte_size(raw) == @strict.max_datagram
      assert {:ok, _request} = Protocol.decode_request(raw, @strict)
    end

    test "an unknown command id is answered with ENOSYS and an echoed header" do
      raw = <<0x34, 0x12, 0x2A, 0x99, "junk">>

      assert {:error, %Header{sid: 0x1234, seq: 0x2A, command_id: 0x99}, :enosys} =
               Protocol.decode_request(raw, @strict)
    end

    test "a string without a NUL terminator is EINVAL" do
      assert {:error, %Header{}, :einval} =
               Protocol.decode_request(<<0x34, 0x12, 0x01, 0x10, "/no-nul">>, @strict)
    end

    test "a second string missing its terminator is EINVAL" do
      assert {:error, %Header{}, :einval} =
               Protocol.decode_request(<<0x34, 0x12, 0x01, 0x28, "/a", 0, "/b">>, @strict)
    end

    test "MOUNT with a truncated version field is EINVAL" do
      assert {:error, %Header{}, :einval} =
               Protocol.decode_request(<<0x00, 0x00, 0x01, 0x00, 0x03>>, @strict)
    end

    test "MOUNT with an empty payload never dereferences a missing byte" do
      assert {:error, %Header{}, :einval} =
               Protocol.decode_request(<<0x00, 0x00, 0x01, 0x00>>, @strict)
    end

    test "every vector truncated by one byte is EINVAL, never a crash" do
      for {command, raw, _args} <- request_vectors(), byte_size(raw) > 4 do
        short = binary_part(raw, 0, byte_size(raw) - 1)

        case Protocol.decode_request(short, @strict) do
          {:error, %Header{}, :einval} ->
            :ok

          other ->
            flunk("#{command} truncated by one byte gave #{inspect(other)}")
        end
      end
    end

    test "trailing bytes are EINVAL in strict mode and ignored in compatibility mode" do
      raw = <<0x34, 0x12, 0x01, 0x11, 0x03, "extra">>
      assert {:error, %Header{}, :einval} = Protocol.decode_request(raw, @strict)
      assert {:ok, request} = Protocol.decode_request(raw, @lax)
      assert request.args == %{handle: 3}
    end

    test "WRITE never trusts a declared length longer than the received bytes" do
      raw = <<0x34, 0x12, 0x01, 0x22, 0x05, 0xFF, 0x00, "abc">>
      assert {:error, %Header{}, :einval} = Protocol.decode_request(raw, @strict)
      assert {:error, %Header{}, :einval} = Protocol.decode_request(raw, @lax)
    end

    test "WRITE with more bytes than declared is rejected in strict mode" do
      raw = <<0x34, 0x12, 0x01, 0x22, 0x05, 0x01, 0x00, "abc">>
      assert {:error, %Header{}, :einval} = Protocol.decode_request(raw, @strict)
      assert {:ok, request} = Protocol.decode_request(raw, @lax)
      assert request.args == %{handle: 5, data: "a"}
    end
  end

  describe "encode_response/2" do
    test "produces the documented header layout" do
      response = %Response{
        sid: 0x1234,
        seq: 0x2A,
        command_id: Command.id(:mount),
        status: :success,
        payload: <<0x03, 0x01, 0xE8, 0x03>>
      }

      assert {:ok, <<0x34, 0x12, 0x2A, 0x00, 0x00, 0x03, 0x01, 0xE8, 0x03>>} =
               Protocol.encode_response(response, @strict)
    end

    test "EBADSESSION is reported with SID zero (handoff section 14.1)" do
      response = %Response{
        sid: 0x0000,
        seq: 0x07,
        command_id: Command.id(:read),
        status: :ebadsession
      }

      assert {:ok, <<0x00, 0x00, 0x07, 0x21, 0xFF>>} =
               Protocol.encode_response(response, @strict)
    end

    test "an oversized payload is refused instead of truncated" do
      response = %Response{
        sid: 1,
        seq: 1,
        command_id: Command.id(:read),
        status: :success,
        payload: :binary.copy("x", @strict.max_response_payload + 1)
      }

      assert {:error, :response_too_large} = Protocol.encode_response(response, @strict)
    end

    test "a payload at the limit is accepted and the datagram stays within bounds" do
      payload = :binary.copy("x", @strict.max_response_payload)

      response = %Response{
        sid: 1,
        seq: 1,
        command_id: Command.id(:read),
        status: :success,
        payload: payload
      }

      assert {:ok, encoded} = Protocol.encode_response(response, @strict)
      assert byte_size(encoded) <= @strict.max_datagram
    end
  end

  describe "encode_payload/2 golden vectors" do
    test "MOUNT advertises version and retry delay little-endian" do
      assert {:ok, <<0x03, 0x01, 0xE8, 0x03>>} =
               Protocol.encode_payload(:mount, %{version: 0x0103, retry_ms: 1000})
    end

    test "STAT is exactly 22 bytes in the documented order" do
      args = %{
        mode: 0o100_644,
        uid: 1000,
        gid: 1000,
        size: 0x01020304,
        atime: 1,
        mtime: 2,
        ctime: 3
      }

      assert {:ok, payload} = Protocol.encode_payload(:stat, args)
      assert byte_size(payload) == 22

      assert <<mode::unsigned-little-16, uid::unsigned-little-16, gid::unsigned-little-16,
               size::unsigned-little-32, atime::unsigned-little-32, mtime::unsigned-little-32,
               ctime::unsigned-little-32>> = payload

      assert {mode, uid, gid, size, atime, mtime, ctime} ==
               {0o100_644, 1000, 1000, 0x01020304, 1, 2, 3}
    end

    test "READ prefixes the data with its actual length" do
      assert {:ok, <<0x03, 0x00, "abc">>} = Protocol.encode_payload(:read, %{data: "abc"})
    end

    test "device sizes use u32 and u64 variants" do
      assert {:ok, <<0xFF, 0xFF, 0xFF, 0xFF>>} =
               Protocol.encode_payload(:size, %{kib: 0xFFFFFFFF})

      assert {:ok, <<1, 0, 0, 0, 0, 0, 0, 0>>} =
               Protocol.encode_payload(:sizebytes, %{bytes: 1})
    end

    test "a value that does not fit its field is refused, never wrapped" do
      assert {:error, {:out_of_range, :kib}} =
               Protocol.encode_payload(:size, %{kib: 0x1_0000_0000})

      assert {:error, {:out_of_range, :handle}} =
               Protocol.encode_payload(:open, %{handle: 256})

      assert {:error, {:out_of_range, :matched}} =
               Protocol.encode_payload(:opendirx, %{handle: 0, matched: 65_536})
    end

    test "a name containing NUL cannot be encoded as a string field" do
      assert {:error, {:out_of_range, :name}} =
               Protocol.encode_payload(:readdir, %{name: <<"a", 0, "b">>})
    end

    test "READDIRX has no schema-driven payload" do
      assert {:error, :unsupported} = Protocol.encode_payload(:readdirx, %{})
    end
  end

  describe "response round-trip" do
    test "decode(encode(x)) == x for schema-driven success payloads" do
      cases = [
        {:mount, %{version: 0x0103, retry_ms: 1000}},
        {:umount, %{}},
        {:opendir, %{handle: 0}},
        {:readdir, %{name: "DOS.SYS"}},
        {:telldir, %{position: 0xFFFFFFFF}},
        {:opendirx, %{handle: 7, matched: 65_535}},
        {:read, %{data: :binary.copy("z", 512)}},
        {:write, %{actual: 512}},
        {:lseek, %{position: 0}},
        {:open, %{handle: 15}},
        {:free, %{kib: 1024}},
        {:freebytes, %{bytes: 0xFFFFFFFFFFFFFFFF}}
      ]

      for {command, args} <- cases do
        assert {:ok, payload} = Protocol.encode_payload(command, args)

        response = %Response{
          sid: 0x1234,
          seq: 0x2A,
          command_id: Command.id(command),
          status: :success,
          payload: payload
        }

        assert {:ok, encoded} = Protocol.encode_response(response, @strict)
        assert {:ok, decoded, decoded_args} = Protocol.decode_response(encoded, @strict)
        assert decoded == response
        assert decoded_args == args
      end
    end

    test "an error response carries no schema payload" do
      response = %Response{
        sid: 0,
        seq: 3,
        command_id: Command.id(:stat),
        status: :enoent
      }

      assert {:ok, encoded} = Protocol.encode_response(response, @strict)
      assert {:ok, ^response, %{}} = Protocol.decode_response(encoded, @strict)
    end

    test "malformed responses are reported, not raised" do
      assert {:error, :short_response} = Protocol.decode_response(<<1, 2, 3, 4>>, @strict)
      assert {:error, :unknown_code} = Protocol.decode_response(<<0, 0, 0, 0x99, 0>>, @strict)
      assert {:error, :unknown_code} = Protocol.decode_response(<<0, 0, 0, 0x24, 0x7F>>, @strict)

      assert {:error, :malformed_payload} =
               Protocol.decode_response(<<0, 0, 0, 0x24, 0x00, 1, 2, 3>>, @strict)

      assert {:error, :trailing_bytes} =
               Protocol.decode_response(<<0, 0, 0, 0x15, 0x00, 1, 2, 3, 4, 5>>, @strict)
    end
  end

  describe "frame_length/2 for stream transports" do
    test "returns the exact length of every golden vector" do
      for {command, raw, _args} <- request_vectors() do
        assert {:ok, byte_size(raw)} == Protocol.frame_length(raw, @strict),
               "wrong frame length for #{command}"
      end
    end

    test "every prefix of every vector is incomplete" do
      for {command, raw, _args} <- request_vectors(), size <- 0..(byte_size(raw) - 1) do
        prefix = binary_part(raw, 0, size)

        assert :incomplete == Protocol.frame_length(prefix, @strict),
               "prefix of #{size} bytes of #{command} was not reported incomplete"
      end
    end

    test "trailing bytes of a following frame do not extend the current one" do
      for {_command, raw, _args} <- request_vectors() do
        assert {:ok, byte_size(raw)} ==
                 Protocol.frame_length(raw <> :binary.copy(<<0xAA>>, 16), @strict)
      end
    end

    test "an unframeable or unknown command is reported rather than guessed" do
      assert {:error, :unframeable} =
               Protocol.frame_length(<<0x00, 0x00, 0x01, 0x20, 1, 2, 3>>, @strict)

      assert {:error, :enosys} =
               Protocol.frame_length(<<0x00, 0x00, 0x01, 0x99, 1, 2, 3>>, @strict)
    end

    test "a frame that cannot fit the maximum datagram is E2BIG" do
      # A path string that never terminates must not buffer without bound.
      buffer = <<0x00, 0x00, 0x01, 0x24, :binary.copy("a", @strict.max_datagram)::binary>>
      assert {:error, :e2big} = Protocol.frame_length(buffer, @strict)
    end

    test "a WRITE declaring more than the datagram limit is E2BIG" do
      buffer = <<0x00, 0x00, 0x01, 0x22, 0x00, 0xFF, 0xFF, :binary.copy("a", 600)::binary>>
      assert {:error, :e2big} = Protocol.frame_length(buffer, @strict)
    end
  end
end
