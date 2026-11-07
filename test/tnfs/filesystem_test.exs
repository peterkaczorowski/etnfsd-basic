defmodule Tnfs.FilesystemTest do
  @moduledoc """
  File, directory and device commands driven end to end over UDP.
  """

  use Tnfs.ServerCase, async: false

  import Bitwise

  @rdonly 0x0001
  @wronly 0x0002
  @rdwr 0x0003
  @append 0x0008
  @creat 0x0100
  @trunc 0x0200
  @excl 0x0400

  @writable [read_only: false]

  setup context do
    File.write!(Path.join(context.root, "hello.txt"), "hello world")
    File.mkdir_p!(Path.join(context.root, "sub"))
    File.write!(Path.join([context.root, "sub", "inner.txt"]), "inner")

    %{sid: mount!(context)}
  end

  describe "open and read" do
    test "reads a file back", context do
      handle = open!(context, 1, "/hello.txt", @rdonly)

      {response, args} = call(context, context.sid, 2, :read, %{handle: handle, requested: 5})
      assert response.status == :success
      assert args.data == "hello"

      {response, args} = call(context, context.sid, 3, :read, %{handle: handle, requested: 512})
      assert response.status == :success
      assert args.data == " world"

      # Only a read that starts at the end of the file is EOF; the short read
      # above was still a success (handoff section 3.3).
      {response, _args} = call(context, context.sid, 4, :read, %{handle: handle, requested: 512})
      assert response.status == :eof
    end

    test "a read request larger than the wire limit is clamped, not refused", context do
      handle = open!(context, 1, "/hello.txt", @rdonly)

      {response, args} =
        call(context, context.sid, 2, :read, %{handle: handle, requested: 0xFFFF})

      assert response.status == :success
      assert args.data == "hello world"
      assert byte_size(response.payload) <= context.config.max_response_payload
    end

    test "a missing file is ENOENT", context do
      {response, _args} =
        call(context, context.sid, 1, :open, %{flags: @rdonly, mode: 0o644, path: "/nope"})

      assert response.status == :enoent
    end

    test "a directory cannot be opened as a file", context do
      {response, _args} =
        call(context, context.sid, 1, :open, %{flags: @rdonly, mode: 0o644, path: "/sub"})

      assert response.status == :eisdir
    end

    test "unknown flag bits are EINVAL instead of being ignored", context do
      {response, _args} =
        call(context, context.sid, 1, :open, %{flags: 0x8000, mode: 0o644, path: "/hello.txt"})

      assert response.status == :einval
    end

    test "EXCL without CREAT is a contradiction", context do
      {response, _args} =
        call(context, context.sid, 1, :open, %{
          flags: @rdonly ||| @excl,
          mode: 0o644,
          path: "/hello.txt"
        })

      assert response.status == :einval
    end

    test "an unknown handle is EBADF", context do
      {response, _args} = call(context, context.sid, 1, :read, %{handle: 9, requested: 1})
      assert response.status == :ebadf
    end

    @tag config: @writable
    test "handles run out at the configured limit", context do
      # Every slot is taken by the same file, which is legal.
      for seq <- 1..context.config.max_file_handles do
        open!(context, seq, "/hello.txt", @rdonly)
      end

      {response, _args} =
        call(context, context.sid, 200, :open, %{flags: @rdonly, mode: 0o644, path: "/hello.txt"})

      assert response.status == :emfile
    end

    test "closing frees the handle for reuse", context do
      first = open!(context, 1, "/hello.txt", @rdonly)

      {response, _args} = call(context, context.sid, 2, :close, %{handle: first})
      assert response.status == :success

      assert open!(context, 3, "/hello.txt", @rdonly) == first
    end
  end

  describe "lseek" do
    test "moves the position from every origin", context do
      handle = open!(context, 1, "/hello.txt", @rdonly)

      assert seek!(context, 2, handle, 0, 6) == 6
      assert seek!(context, 3, handle, 1, -1) == 5
      assert seek!(context, 4, handle, 2, 0) == 11

      {response, args} = call(context, context.sid, 5, :read, %{handle: handle, requested: 10})
      assert response.status == :eof or args == %{}
    end

    test "an unknown origin is EINVAL rather than a guess", context do
      handle = open!(context, 1, "/hello.txt", @rdonly)

      {response, _args} =
        call(context, context.sid, 2, :lseek, %{handle: handle, whence: 9, offset: 0})

      assert response.status == :einval
    end

    test "seeking before the start of the file is refused", context do
      handle = open!(context, 1, "/hello.txt", @rdonly)

      {response, _args} =
        call(context, context.sid, 2, :lseek, %{handle: handle, whence: 0, offset: -5})

      assert response.status == :einval
    end
  end

  describe "stat" do
    test "returns exactly the 22 byte structure", context do
      {response, args} = call(context, context.sid, 1, :stat, %{path: "/hello.txt"})

      assert response.status == :success
      assert byte_size(response.payload) == 22
      assert args.size == 11
      assert args.mtime > 0
    end

    test "a missing path is ENOENT", context do
      {response, _args} = call(context, context.sid, 1, :stat, %{path: "/nope"})
      assert response.status == :enoent
    end

    test "escaping the root is refused", context do
      {response, _args} = call(context, context.sid, 1, :stat, %{path: "/../../etc/passwd"})
      assert response.status == :eacces
    end
  end

  describe "directories" do
    test "lists a directory through a stable snapshot", context do
      handle = opendir!(context, 1, "/")

      names = drain(context, handle, 2, [])

      assert "." in names
      assert ".." in names
      assert "hello.txt" in names
      assert "sub" in names
    end

    test "telldir and seekdir address entries by index", context do
      handle = opendir!(context, 1, "/")

      {_response, first} = call(context, context.sid, 2, :readdir, %{handle: handle})

      {response, args} = call(context, context.sid, 3, :telldir, %{handle: handle})
      assert response.status == :success
      assert args.position == 1

      {response, _args} =
        call(context, context.sid, 4, :seekdir, %{handle: handle, position: 0})

      assert response.status == :success

      {_response, again} = call(context, context.sid, 5, :readdir, %{handle: handle})
      assert again.name == first.name
    end

    test "seeking past the end of the snapshot is EINVAL", context do
      handle = opendir!(context, 1, "/")

      {response, _args} =
        call(context, context.sid, 2, :seekdir, %{handle: handle, position: 10_000})

      assert response.status == :einval
    end

    test "closedir frees the handle", context do
      handle = opendir!(context, 1, "/")

      {response, _args} = call(context, context.sid, 2, :closedir, %{handle: handle})
      assert response.status == :success

      {response, _args} = call(context, context.sid, 3, :readdir, %{handle: handle})
      assert response.status == :ebadf
    end

    test "opening a file as a directory is ENOTDIR", context do
      {response, _args} = call(context, context.sid, 1, :opendir, %{path: "/hello.txt"})
      assert response.status == :enotdir
    end
  end

  describe "read-only mode" do
    test "every mutating command is refused before the filesystem is touched",
         context do
      mutations = [
        {:mkdir, %{path: "/new"}},
        {:rmdir, %{path: "/sub"}},
        {:unlink, %{path: "/hello.txt"}},
        {:rename, %{source: "/hello.txt", destination: "/other"}},
        {:chmod, %{mode: 0o600, path: "/hello.txt"}}
      ]

      for {{command, args}, seq} <- Enum.with_index(mutations, 1) do
        {response, _args} = call(context, context.sid, seq, command, args)
        assert response.status == :eperm, "#{command} was not refused"
      end

      assert File.exists?(Path.join(context.root, "hello.txt"))
      assert File.dir?(Path.join(context.root, "sub"))
    end

    test "opening for writing is EPERM", context do
      {response, _args} =
        call(context, context.sid, 1, :open, %{
          flags: @wronly ||| @creat,
          mode: 0o644,
          path: "/new.txt"
        })

      assert response.status == :eperm
      refute File.exists?(Path.join(context.root, "new.txt"))
    end
  end

  describe "writing" do
    @tag config: @writable
    test "creates, writes and reads back", context do
      handle =
        open!(context, 1, "/new.txt", @rdwr ||| @creat ||| @excl)

      {response, args} =
        call(context, context.sid, 2, :write, %{handle: handle, data: "payload"})

      assert response.status == :success
      assert args.actual == 7

      assert seek!(context, 3, handle, 0, 0) == 0

      {response, args} = call(context, context.sid, 4, :read, %{handle: handle, requested: 512})
      assert response.status == :success
      assert args.data == "payload"

      assert File.read!(Path.join(context.root, "new.txt")) == "payload"
    end

    @tag config: @writable
    test "EXCL refuses an existing file", context do
      {response, _args} =
        call(context, context.sid, 1, :open, %{
          flags: @wronly ||| @creat ||| @excl,
          mode: 0o644,
          path: "/hello.txt"
        })

      assert response.status == :eexist
      assert File.read!(Path.join(context.root, "hello.txt")) == "hello world"
    end

    @tag config: @writable
    test "TRUNC empties the file, and opening without it does not", context do
      handle = open!(context, 1, "/hello.txt", @rdwr)
      call(context, context.sid, 2, :close, %{handle: handle})
      assert File.read!(Path.join(context.root, "hello.txt")) == "hello world"

      handle = open!(context, 3, "/hello.txt", @rdwr ||| @trunc)
      call(context, context.sid, 4, :close, %{handle: handle})
      assert File.read!(Path.join(context.root, "hello.txt")) == ""
    end

    @tag config: @writable
    test "APPEND writes at the end", context do
      handle = open!(context, 1, "/hello.txt", @wronly ||| @append)
      call(context, context.sid, 2, :write, %{handle: handle, data: "!"})

      assert File.read!(Path.join(context.root, "hello.txt")) == "hello world!"
    end

    @tag config: @writable
    test "a read-only handle refuses a write", context do
      handle = open!(context, 1, "/hello.txt", @rdonly)

      {response, _args} =
        call(context, context.sid, 2, :write, %{handle: handle, data: "x"})

      assert response.status == :eacces
      assert File.read!(Path.join(context.root, "hello.txt")) == "hello world"
    end

    @tag config: @writable
    test "a write-only handle refuses a read", context do
      handle = open!(context, 1, "/hello.txt", @wronly)

      {response, _args} = call(context, context.sid, 2, :read, %{handle: handle, requested: 1})
      assert response.status == :eacces
    end
  end

  describe "mutations" do
    @tag config: @writable
    test "mkdir, rmdir, unlink and rename", context do
      {response, _args} = call(context, context.sid, 1, :mkdir, %{path: "/made"})
      assert response.status == :success
      assert File.dir?(Path.join(context.root, "made"))

      {response, _args} = call(context, context.sid, 2, :mkdir, %{path: "/made"})
      assert response.status == :eexist

      {response, _args} = call(context, context.sid, 3, :rmdir, %{path: "/made"})
      assert response.status == :success
      refute File.exists?(Path.join(context.root, "made"))

      {response, _args} = call(context, context.sid, 4, :rmdir, %{path: "/sub"})
      assert response.status == :enotempty

      {response, _args} =
        call(context, context.sid, 5, :rename, %{source: "/hello.txt", destination: "/moved.txt"})

      assert response.status == :success
      assert File.read!(Path.join(context.root, "moved.txt")) == "hello world"

      {response, _args} = call(context, context.sid, 6, :unlink, %{path: "/moved.txt"})
      assert response.status == :success
      refute File.exists?(Path.join(context.root, "moved.txt"))
    end

    @tag config: @writable
    test "rename cannot move a file out of the root", context do
      {response, _args} =
        call(context, context.sid, 1, :rename, %{
          source: "/hello.txt",
          destination: "/../escaped.txt"
        })

      assert response.status == :eacces
      assert File.exists?(Path.join(context.root, "hello.txt"))
    end

    @tag config: @writable
    test "chmod changes the permission bits", context do
      path = Path.join(context.root, "hello.txt")

      {response, _args} =
        call(context, context.sid, 1, :chmod, %{mode: 0o600, path: "/hello.txt"})

      assert response.status == :success
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    @tag config: @writable ++ [chmod_mask: 0o777]
    test "chmod refuses bits outside the mask", context do
      {response, _args} =
        call(context, context.sid, 1, :chmod, %{mode: 0o4755, path: "/hello.txt"})

      assert response.status == :einval
    end

    @tag config: @writable ++ [chmod_enabled: false]
    test "chmod can be turned off and then answers ENOSYS", context do
      {response, _args} =
        call(context, context.sid, 1, :chmod, %{mode: 0o600, path: "/hello.txt"})

      assert response.status == :enosys
    end
  end

  describe "device information" do
    test "reports a plausible size in both units", context do
      {response, size} = call(context, context.sid, 1, :size, %{})
      assert response.status == :success

      {response, free} = call(context, context.sid, 2, :free, %{})
      assert response.status == :success

      {response, size_bytes} = call(context, context.sid, 3, :sizebytes, %{})
      assert response.status == :success

      {response, free_bytes} = call(context, context.sid, 4, :freebytes, %{})
      assert response.status == :success

      assert size.kib > 0
      assert free.kib <= size.kib
      assert size_bytes.bytes >= free_bytes.bytes
      assert div(size_bytes.bytes, 1024) == size.kib or size.kib == 0xFFFFFFFF
    end
  end

  describe "mounting a subdirectory" do
    test "confines the session to that subdirectory", context do
      sid = mount!(context, mount: "/sub", seq: 100)

      {response, _args} = call(context, sid, 1, :stat, %{path: "/inner.txt"})
      assert response.status == :success

      # The file one level up is simply not there any more.
      {response, _args} = call(context, sid, 2, :stat, %{path: "/hello.txt"})
      assert response.status == :enoent
    end

    test "a mountpoint outside the export root is refused", context do
      args = %{version: 0x0102, mount: "/../..", user: "", password: ""}
      {response, _args} = call(context, 0, 100, :mount, args)

      assert response.status == :eacces
      assert response.sid == 0
    end

    test "a mountpoint that is a file is ENOTDIR", context do
      args = %{version: 0x0102, mount: "/hello.txt", user: "", password: ""}
      {response, _args} = call(context, 0, 100, :mount, args)

      assert response.status == :enotdir
    end
  end

  describe "unimplemented commands" do
    test "legacy OPEN answers ENOSYS instead of staying silent", context do
      reply = roundtrip(context, <<context.sid::unsigned-little-16, 1, 0x20, 0, 0>>)

      assert <<_sid::16, 1, 0x20, status>> <> _rest = reply
      assert status == Tnfs.Status.code(:enosys)
    end
  end

  defp open!(context, seq, path, flags) do
    {response, args} =
      call(context, context.sid, seq, :open, %{flags: flags, mode: 0o644, path: path})

    assert response.status == :success, "OPEN #{path} failed with #{inspect(response.status)}"
    args.handle
  end

  defp opendir!(context, seq, path) do
    {response, args} = call(context, context.sid, seq, :opendir, %{path: path})

    assert response.status == :success, "OPENDIR #{path} failed with #{inspect(response.status)}"
    args.handle
  end

  defp seek!(context, seq, handle, whence, offset) do
    {response, args} =
      call(context, context.sid, seq, :lseek, %{handle: handle, whence: whence, offset: offset})

    assert response.status == :success, "LSEEK failed with #{inspect(response.status)}"
    args.position
  end

  defp drain(context, handle, seq, acc) do
    case call(context, context.sid, seq, :readdir, %{handle: handle}) do
      {%{status: :success}, args} -> drain(context, handle, seq + 1, [args.name | acc])
      {%{status: :eof}, _args} -> acc
    end
  end
end
