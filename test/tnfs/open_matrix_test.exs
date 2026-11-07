defmodule Tnfs.OpenMatrixTest do
  @moduledoc """
  The full OPEN `0x29` flag matrix.

  TNFS flags are POSIX `open(2)` flags and Erlang's mode list is not, so every
  combination is checked rather than assumed. Status codes are checked through
  the session, where a client would see them; filesystem effects are checked
  against the adapter, where "did this file keep its permissions" is an
  observable fact rather than an inference from a status byte.
  """

  use Tnfs.ServerCase, async: false

  import Bitwise

  alias Tnfs.Filesystem

  @rdonly 0x0001
  @wronly 0x0002
  @rdwr 0x0003
  @append 0x0008
  @creat 0x0100
  @trunc 0x0200
  @excl 0x0400

  @writable [read_only: false, mode_mask: 0o777]

  @moduletag config: [read_only: false]

  setup context do
    File.write!(Path.join(context.root, "hello.txt"), "hello world")
    %{sid: mount!(context)}
  end

  describe "the creation mode" do
    test "is applied to a file this call creates", context do
      path = Path.join(context.root, "fresh.txt")

      assert {:ok, file} = Filesystem.open(path, @wronly ||| @creat, 0o640, @writable)
      assert :ok = Filesystem.close(file)
      assert mode(path) == 0o640
    end

    test "is not applied to a file that already exists", context do
      path = Path.join(context.root, "hello.txt")
      File.chmod!(path, 0o600)

      # The confirmed defect: O_CREAT on an existing file re-permissioned it to
      # whatever the request happened to carry, so a client reading a file
      # could widen it to 0644.
      assert {:ok, file} = Filesystem.open(path, @rdonly ||| @creat, 0o644, @writable)
      assert :ok = Filesystem.close(file)
      assert mode(path) == 0o600
    end

    test "is ignored without CREAT", context do
      path = Path.join(context.root, "hello.txt")
      File.chmod!(path, 0o600)

      assert {:ok, file} = Filesystem.open(path, @rdwr, 0o777, @writable)
      assert :ok = Filesystem.close(file)
      assert mode(path) == 0o600
    end

    test "is rejected before anything is created when it carries stray bits",
         context do
      path = Path.join(context.root, "stray.txt")

      # Same rule as CHMOD (handoff 14.1, ADR 5): bits outside the supported
      # profile are refused, not quietly dropped. And refused early enough that
      # no file and no descriptor exist to clean up.
      assert {:error, :einval} =
               Filesystem.open(path, @wronly ||| @creat, 0o4755, @writable)

      refute File.exists?(path)
    end

    @tag config: [read_only: false, max_file_handles: 2]
    test "leaks no session handle when it is rejected", context do
      for seq <- 1..20 do
        assert {%{status: :einval}, _args} =
                 call(context, context.sid, seq, :open, %{
                   flags: @wronly ||| @creat,
                   mode: 0o4755,
                   path: "/stray-#{seq}.txt"
                 })
      end

      # The table is two handles wide; if a rejected OPEN had consumed one,
      # these would fail with ENFILE.
      assert open!(context, 100, "/hello.txt", @rdonly) != nil
      assert open!(context, 101, "/hello.txt", @rdonly) != nil
    end
  end

  describe "access modes" do
    test "RDONLY reads and refuses to write", context do
      path = Path.join(context.root, "hello.txt")

      assert {:ok, file} = Filesystem.open(path, @rdonly, 0, @writable)
      assert {:ok, "hello"} = Filesystem.read(file, 5)
      assert {:error, :eacces} = Filesystem.write(file, "x")
      assert :ok = Filesystem.close(file)
    end

    test "WRONLY without TRUNC keeps the existing contents", context do
      path = Path.join(context.root, "hello.txt")

      assert {:ok, file} = Filesystem.open(path, @wronly, 0, @writable)
      assert {:ok, 2} = Filesystem.write(file, "HE")
      assert :ok = Filesystem.close(file)

      # `[:write]` would have truncated the file to nothing here.
      assert File.read!(path) == "HEllo world"
    end

    test "WRONLY|TRUNC empties the file", context do
      path = Path.join(context.root, "hello.txt")

      assert {:ok, file} = Filesystem.open(path, @wronly ||| @trunc, 0, @writable)
      assert :ok = Filesystem.close(file)
      assert File.read!(path) == ""
    end

    test "RDWR keeps the contents and can both read and write", context do
      path = Path.join(context.root, "hello.txt")

      assert {:ok, file} = Filesystem.open(path, @rdwr, 0, @writable)
      assert {:ok, "hello"} = Filesystem.read(file, 5)
      assert {:ok, 1} = Filesystem.write(file, "!")
      assert :ok = Filesystem.close(file)
      assert File.read!(path) == "hello!world"
    end

    test "RDWR|TRUNC empties the file and still reads", context do
      path = Path.join(context.root, "hello.txt")

      # The confirmed defect: this was opened as `[:write]`, so the client got
      # a handle it could not read from and every READ answered EBADF.
      assert {:ok, file} = Filesystem.open(path, @rdwr ||| @trunc, 0, @writable)
      assert {:ok, 4} = Filesystem.write(file, "new!")
      assert {:ok, 0} = Filesystem.seek(file, 0, 0)
      assert {:ok, "new!"} = Filesystem.read(file, 16)
      assert :ok = Filesystem.close(file)
      assert File.read!(path) == "new!"
    end

    test "APPEND writes at the end whatever the position says", context do
      path = Path.join(context.root, "hello.txt")

      assert {:ok, file} = Filesystem.open(path, @wronly ||| @append, 0, @writable)
      assert {:ok, 0} = Filesystem.seek(file, 0, 0)
      assert {:ok, 1} = Filesystem.write(file, "!")
      assert :ok = Filesystem.close(file)
      assert File.read!(path) == "hello world!"
    end

    test "RDWR|APPEND reads from the start and writes at the end", context do
      path = Path.join(context.root, "hello.txt")

      assert {:ok, file} = Filesystem.open(path, @rdwr ||| @append, 0, @writable)
      assert {:ok, "hello"} = Filesystem.read(file, 5)
      assert {:ok, 1} = Filesystem.write(file, "!")
      assert :ok = Filesystem.close(file)
      assert File.read!(path) == "hello world!"
    end

    test "APPEND|TRUNC empties the file first", context do
      path = Path.join(context.root, "hello.txt")

      assert {:ok, file} =
               Filesystem.open(path, @rdwr ||| @append ||| @trunc, 0, @writable)

      assert {:ok, 3} = Filesystem.write(file, "abc")
      assert :ok = Filesystem.close(file)
      assert File.read!(path) == "abc"
    end

    test "no access bit at all is EINVAL", context do
      assert {:error, :einval} =
               Filesystem.open(Path.join(context.root, "hello.txt"), 0, 0, @writable)
    end

    test "an unknown flag bit is EINVAL", context do
      assert {%{status: :einval}, _args} =
               call(context, context.sid, 1, :open, %{
                 flags: 0x8000 ||| @rdonly,
                 mode: 0o644,
                 path: "/hello.txt"
               })
    end
  end

  describe "existence" do
    test "opening a missing file without CREAT is ENOENT", context do
      path = Path.join(context.root, "nope.txt")

      # Every Erlang write mode implies O_CREAT, so without this check a plain
      # WRONLY would quietly bring the file into existence.
      assert {:error, :enoent} = Filesystem.open(path, @wronly, 0, @writable)
      refute File.exists?(path)
    end

    test "CREAT makes a missing file", context do
      path = Path.join(context.root, "made.txt")

      assert {:ok, file} = Filesystem.open(path, @rdwr ||| @creat, 0o644, @writable)
      assert :ok = Filesystem.close(file)
      assert File.read!(path) == ""
    end

    test "EXCL without CREAT is EINVAL", context do
      assert {:error, :einval} =
               Filesystem.open(
                 Path.join(context.root, "hello.txt"),
                 @rdwr ||| @excl,
                 0,
                 @writable
               )
    end

    test "CREAT|EXCL on an existing file is EEXIST and changes nothing", context do
      path = Path.join(context.root, "hello.txt")
      File.chmod!(path, 0o600)

      assert {:error, :eexist} =
               Filesystem.open(path, @wronly ||| @creat ||| @excl, 0o666, @writable)

      assert File.read!(path) == "hello world"
      assert mode(path) == 0o600
    end

    test "CREAT|EXCL has exactly one winner among concurrent callers", context do
      path = Path.join(context.root, "race.txt")

      # Previously the existence check was a separate lstat, so every caller
      # that looked before any caller created could believe it had won.
      results =
        1..50
        |> Task.async_stream(
          fn _index ->
            case Filesystem.open(path, @wronly ||| @creat ||| @excl, 0o600, @writable) do
              {:ok, file} ->
                :ok = Filesystem.close(file)
                :created

              {:error, reason} ->
                reason
            end
          end,
          max_concurrency: 50
        )
        |> Enum.map(fn {:ok, outcome} -> outcome end)

      assert Enum.count(results, &(&1 == :created)) == 1
      assert Enum.count(results, &(&1 == :eexist)) == 49
      assert mode(path) == 0o600
    end

    test "a directory is EISDIR and a symlink is refused", context do
      File.mkdir_p!(Path.join(context.root, "dir"))
      File.ln_s!(Path.join(context.root, "hello.txt"), Path.join(context.root, "link"))

      assert {:error, :eisdir} =
               Filesystem.open(Path.join(context.root, "dir"), @rdonly, 0, @writable)

      assert {:error, :eloop} =
               Filesystem.open(Path.join(context.root, "link"), @rdonly, 0, @writable)
    end
  end

  describe "a read-only export" do
    @describetag config: [read_only: true]

    setup do
      %{read_only: [read_only: true, mode_mask: 0o777]}
    end

    test "refuses every write-intent combination before touching anything",
         context do
      existing = Path.join(context.root, "hello.txt")
      missing = Path.join(context.root, "missing.txt")

      for flags <- [
            @wronly,
            @rdwr,
            @wronly ||| @trunc,
            @rdwr ||| @trunc,
            @wronly ||| @append,
            @rdonly ||| @creat,
            @rdonly ||| @creat ||| @excl
          ] do
        assert {:error, :eperm} =
                 Filesystem.open(existing, flags, 0o644, context.read_only),
               "flags #{inspect(flags, base: :hex)} were not refused"

        assert {:error, :eperm} = Filesystem.open(missing, flags, 0o644, context.read_only)
      end

      assert File.read!(existing) == "hello world"
      refute File.exists?(missing)
    end

    test "still allows a plain read", context do
      assert {:ok, file} =
               Filesystem.open(
                 Path.join(context.root, "hello.txt"),
                 @rdonly,
                 0,
                 context.read_only
               )

      assert {:ok, "hello world"} = Filesystem.read(file, 64)
      assert :ok = Filesystem.close(file)
    end
  end

  describe "the one combination Erlang cannot express" do
    test "WRONLY on a file that cannot be read is refused rather than truncated",
         context do
      path = Path.join(context.root, "writeonly.bin")
      File.write!(path, "precious")
      File.chmod!(path, 0o222)
      on_exit(fn -> File.chmod(path, 0o644) end)

      # `[:write]` is Erlang's only write-without-read mode and it carries
      # O_TRUNC, which would destroy exactly the data the client asked to write
      # into. `[:read, :write]` is used instead, so the deviation is visible
      # here and nowhere else: an unreadable file cannot be opened for writing.
      assert {:error, :eacces} = Filesystem.open(path, @wronly, 0, @writable)

      File.chmod!(path, 0o644)
      assert File.read!(path) == "precious"
    end
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o7777

  defp open!(context, seq, path, flags) do
    {response, args} =
      call(context, context.sid, seq, :open, %{flags: flags, mode: 0o644, path: path})

    assert response.status == :success
    args.handle
  end
end
