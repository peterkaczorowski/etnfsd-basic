defmodule Tnfs.IgnoreFileTest do
  @moduledoc """
  The `.ignore` file is the one path the server opens on its own initiative.

  It is also the one path a client can create inside a writable export, so it
  gets the same treatment as a client-supplied path: `lstat` first, regular
  files only, bounded read. `File.read/1` followed symlinks, which turned a
  cosmetic listing filter into a way to read any file the server user could
  reach.
  """

  use Tnfs.ServerCase, async: false

  @moduletag config: [read_only: false, dir_ignore_file: true]

  setup context do
    File.write!(Path.join(context.root, "beta.txt"), "B")
    File.write!(Path.join(context.root, "gamma.dat"), "")
    %{sid: mount!(context)}
  end

  describe "a `.ignore` that is not a regular file" do
    test "is not followed when it is a symlink out of the export", context do
      # The file the server must not read. It lives outside the export, which
      # is exactly why a symlink to it is worth planting.
      outside = Path.join(System.tmp_dir!(), "etnfsd-outside-#{System.unique_integer()}")
      File.write!(outside, "*.dat\n")
      on_exit(fn -> File.rm(outside) end)

      File.ln_s!(outside, Path.join(context.root, ".ignore"))

      # If the patterns had been applied, `gamma.dat` would be missing - and
      # its absence would be proof that a file outside the export had been read
      # into the server.
      assert "gamma.dat" in names(context, "/")
    end

    test "is not followed when it is a symlink inside the export", context do
      # The deny profile does not care where a symlink points (handoff section
      # 14.1, ADR 4); a link that resolves inside the root is still a link.
      File.write!(Path.join(context.root, "rules.txt"), "*.dat\n")
      File.ln_s!(Path.join(context.root, "rules.txt"), Path.join(context.root, ".ignore"))

      assert "gamma.dat" in names(context, "/")
    end

    test "does not fail the listing when it is a directory", context do
      # `File.read/1` answered EISDIR here and the whole OPENDIRX failed, so a
      # directory called `.ignore` made its parent unlistable.
      File.mkdir_p!(Path.join(context.root, ".ignore"))

      assert "gamma.dat" in names(context, "/")
    end

    test "is never opened when it is a FIFO", context do
      fifo = Path.join(context.root, ".ignore")

      case System.cmd("mkfifo", [fifo], stderr_to_stdout: true) do
        {_output, 0} ->
          # Opening a FIFO for reading blocks until someone writes to it, which
          # would hang the session process - and with it every other request
          # that session owes an answer to. The `lstat` refuses it first.
          task = Task.async(fn -> names(context, "/") end)

          assert {:ok, listed} = Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill)
          assert "gamma.dat" in listed

        {_output, _status} ->
          # No mkfifo on this platform; the lstat clause that covers it is
          # exercised by the directory case above.
          :ok
      end
    end
  end

  describe "a regular `.ignore`" do
    test "is still honoured", context do
      File.write!(Path.join(context.root, ".ignore"), "# comment\n\n  *.dat  \n")

      listed = names(context, "/")
      refute "gamma.dat" in listed
      assert "beta.txt" in listed
    end

    @tag config: [read_only: false, dir_ignore_file: true, max_ignore_bytes: 64]
    test "is read up to the byte limit", context do
      # 64 bytes exactly: the limit is a maximum, not an exclusive bound.
      contents = "*.dat\n" <> String.duplicate("#", 64 - byte_size("*.dat\n"))
      assert byte_size(contents) == 64
      File.write!(Path.join(context.root, ".ignore"), contents)

      refute "gamma.dat" in names(context, "/")
    end

    @tag config: [read_only: false, dir_ignore_file: true, max_ignore_bytes: 64]
    test "contributes nothing at all when it is larger than the limit", context do
      # Refused rather than truncated. A read cut at 64 bytes would end
      # mid-pattern, and half of `*.dat` is a pattern that hides something the
      # client never asked to hide.
      File.write!(
        Path.join(context.root, ".ignore"),
        "*.dat\n" <> String.duplicate("# padding\n", 100)
      )

      assert "gamma.dat" in names(context, "/")
    end

    @tag config: [read_only: false, dir_ignore_file: true, max_ignore_patterns: 1]
    test "still stops at the pattern limit", context do
      File.write!(Path.join(context.root, ".ignore"), "*.dat\n*.txt\n")

      listed = names(context, "/")
      refute "gamma.dat" in listed
      assert "beta.txt" in listed
    end
  end

  defp names(context, path) do
    args = %{diropts: 0, sortopts: 0, max_results: 0, pattern: "", path: path}
    {response, args} = call(context, context.sid, 1, :opendirx, args)
    assert response.status == :success

    drain(context, args.handle, 2, [])
  end

  defp drain(context, handle, seq, acc) do
    case call(context, context.sid, seq, :readdir, %{handle: handle}) do
      {%{status: :success}, args} -> drain(context, handle, seq + 1, [args.name | acc])
      {%{status: :eof}, _args} -> Enum.reverse(acc)
    end
  end
end
