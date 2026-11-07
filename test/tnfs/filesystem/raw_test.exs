defmodule Tnfs.Filesystem.RawTest do
  @moduledoc """
  The contract between this server and `:prim_file`.

  `:prim_file` is an OTP internal module with no compatibility promise, so the
  whole of the risk is that an upgrade changes it under us. This test is what
  turns that from a production incident into a failing build: it checks that
  every `:prim_file` function the adapter calls still exists, and that each one
  still does what its caller assumes.

  The list of functions is read out of the adapter's own BEAM file rather than
  written down here, so a call added to `Tnfs.Filesystem.Raw` is covered without
  anyone remembering to extend this test.
  """

  use ExUnit.Case, async: true

  alias Tnfs.Filesystem.Raw

  setup do
    root = Path.join(System.tmp_dir!(), "etnfsd-raw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  describe "availability" do
    test "every :prim_file function the adapter calls is exported" do
      imports = prim_file_imports()

      # A guard against the test passing because the extraction broke and found
      # nothing to check.
      assert length(imports) >= 8

      Code.ensure_loaded!(:prim_file)

      for {:prim_file, function, arity} <- imports do
        assert function_exported?(:prim_file, function, arity),
               ":prim_file.#{function}/#{arity} is gone on OTP #{otp_release()}. " <>
                 "See the compatibility notes in Tnfs.Filesystem.Raw."
      end
    end

    test "the running release is at least the declared minimum" do
      # Availability can only be checked on the release actually running, so
      # this records which one that was rather than claiming to have tested the
      # minimum itself.
      assert otp_release() >= Raw.minimum_otp(),
             "running OTP #{otp_release()}, below the declared minimum of #{Raw.minimum_otp()}"
    end
  end

  describe "lstat/1" do
    test "does not follow a final symlink", %{root: root} do
      target = Path.join(root, "target.txt")
      link = Path.join(root, "link")
      File.write!(target, "abc")
      File.ln_s!(target, link)

      # The whole symlink deny policy rests on this one property.
      assert {:ok, %File.Stat{type: :symlink}} = Raw.lstat(link)
      assert {:ok, %File.Stat{type: :regular, size: 3}} = Raw.lstat(target)
    end

    test "returns POSIX integer timestamps", %{root: root} do
      path = Path.join(root, "t.txt")
      File.write!(path, "")
      File.touch!(path, 1_600_000_000)

      {:ok, stat} = Raw.lstat(path)

      # The wire format carries u32 seconds. A datetime tuple here would crash
      # the encoder, and a local-time integer would be off by the offset.
      assert is_integer(stat.mtime)
      assert stat.mtime == 1_600_000_000
    end

    test "reports the type of a directory", %{root: root} do
      assert {:ok, %File.Stat{type: :directory}} = Raw.lstat(root)
    end

    test "returns a posix reason for a missing path", %{root: root} do
      assert {:error, :enoent} = Raw.lstat(Path.join(root, "nope"))
    end
  end

  describe "stat/1" do
    test "follows a symlink", %{root: root} do
      target = Path.join(root, "target.txt")
      link = Path.join(root, "link")
      File.write!(target, "abc")
      File.ln_s!(target, link)

      assert {:ok, %File.Stat{type: :regular, size: 3}} = Raw.stat(link)
    end

    test "reports a broken symlink as missing", %{root: root} do
      link = Path.join(root, "broken")
      File.ln_s!(Path.join(root, "gone"), link)

      assert {:error, :enoent} = Raw.stat(link)
    end
  end

  describe "list_dir/1" do
    test "returns binaries without `.` or `..`", %{root: root} do
      File.write!(Path.join(root, "a"), "")
      File.mkdir_p!(Path.join(root, "b"))

      assert {:ok, names} = Raw.list_dir(root)
      assert Enum.sort(names) == ["a", "b"]
      assert Enum.all?(names, &is_binary/1)
    end

    test "keeps a name that is not valid in the system encoding", %{root: root} do
      # TNFS names are opaque bytes (handoff section 2.2). `list_dir/1` skips
      # such an entry; `list_dir_all/1` is used precisely so it does not.
      name = <<0xFF, 0xFE>>

      case :prim_file.write_file(Path.join(root, name), "") do
        :ok ->
          assert {:ok, names} = Raw.list_dir(root)
          assert name in names

        {:error, _reason} ->
          # Some filesystems reject the bytes outright, which is a refusal by
          # the kernel rather than by us.
          :ok
      end
    end

    test "returns a posix reason for a file", %{root: root} do
      path = Path.join(root, "a")
      File.write!(path, "")

      assert {:error, :enotdir} = Raw.list_dir(path)
    end
  end

  describe "read_link/1" do
    test "returns the target as bytes", %{root: root} do
      link = Path.join(root, "link")
      File.ln_s!("some/target", link)

      assert {:ok, "some/target"} = Raw.read_link(link)
    end

    test "refuses a regular file", %{root: root} do
      path = Path.join(root, "a")
      File.write!(path, "")

      assert {:error, :einval} = Raw.read_link(path)
    end
  end

  describe "the mutating delegates" do
    test "make_dir/1 creates one directory and refuses to replace it", %{root: root} do
      path = Path.join(root, "d")

      assert :ok = Raw.make_dir(path)
      assert File.dir?(path)
      assert {:error, :eexist} = Raw.make_dir(path)
      # No `mkdir -p`: MKDIR must not create intermediate components.
      assert {:error, :enoent} = Raw.make_dir(Path.join(root, "x/y"))
    end

    test "del_dir/1 removes an empty directory only", %{root: root} do
      path = Path.join(root, "d")
      File.mkdir_p!(path)
      File.write!(Path.join(path, "a"), "")

      assert {:error, reason} = Raw.del_dir(path)
      assert reason in [:eexist, :enotempty]

      File.rm!(Path.join(path, "a"))
      assert :ok = Raw.del_dir(path)
      refute File.exists?(path)
    end

    test "delete/1 removes a file and refuses a directory", %{root: root} do
      path = Path.join(root, "a")
      File.write!(path, "")

      assert :ok = Raw.delete(path)
      assert {:error, :enoent} = Raw.delete(path)

      dir = Path.join(root, "d")
      File.mkdir_p!(dir)
      assert {:error, reason} = Raw.delete(dir)
      assert reason in [:eperm, :eisdir, :eacces]
    end

    test "delete/1 removes the link rather than its target", %{root: root} do
      target = Path.join(root, "target.txt")
      link = Path.join(root, "link")
      File.write!(target, "abc")
      File.ln_s!(target, link)

      assert :ok = Raw.delete(link)
      assert File.exists?(target)
    end

    test "rename/2 moves a file and reports a missing source", %{root: root} do
      source = Path.join(root, "a")
      destination = Path.join(root, "b")
      File.write!(source, "abc")

      assert :ok = Raw.rename(source, destination)
      assert File.read!(destination) == "abc"
      assert {:error, :enoent} = Raw.rename(source, destination)
    end
  end

  defp prim_file_imports do
    {:ok, {_module, [imports: imports]}} =
      Tnfs.Filesystem.Raw |> :code.which() |> :beam_lib.chunks([:imports])

    Enum.filter(imports, &match?({:prim_file, _function, _arity}, &1))
  end

  defp otp_release, do: :erlang.system_info(:otp_release) |> List.to_integer()
end
