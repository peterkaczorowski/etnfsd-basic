defmodule Tnfs.PathTest do
  use ExUnit.Case, async: true

  alias Tnfs.Config
  alias Tnfs.Path, as: SafePath

  setup do
    root = Path.join(System.tmp_dir!(), "etnfsd-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "dir"))
    File.write!(Path.join(root, "file.txt"), "x")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, canonical} = SafePath.canonical_root(root)

    %{root: canonical, config: Config.build!(root: canonical)}
  end

  describe "resolve" do
    test "an empty path is the root itself", %{root: root, config: config} do
      assert SafePath.resolve(root, "", config) == {:ok, root}
      assert SafePath.resolve(root, "/", config) == {:ok, root}
    end

    test "an absolute client path stays inside the root", %{root: root, config: config} do
      assert SafePath.resolve(root, "/dir", config) == {:ok, Path.join(root, "dir")}
      assert SafePath.resolve(root, "dir", config) == {:ok, Path.join(root, "dir")}
    end

    test "redundant separators and dots are normalised", %{root: root, config: config} do
      assert SafePath.resolve(root, "//dir///./", config) == {:ok, Path.join(root, "dir")}
    end

    test "a nonexistent path resolves so the filesystem can report ENOENT",
         %{root: root, config: config} do
      assert SafePath.resolve(root, "/dir/new.txt", config) ==
               {:ok, Path.join([root, "dir", "new.txt"])}
    end

    test "names that merely contain dots are legal", %{root: root, config: config} do
      # The substring test used by REFERENCE rejects these; a segment test
      # does not (handoff section 6).
      assert {:ok, _path} = SafePath.resolve(root, "file..bak", config)
      assert {:ok, _path} = SafePath.resolve(root, "...", config)
      assert {:ok, _path} = SafePath.resolve(root, "a/..b/c", config)
    end
  end

  describe "escape attempts" do
    test "a parent segment is refused wherever it appears",
         %{root: root, config: config} do
      for path <- ["..", "../", "/..", "dir/../..", "/../etc/passwd", "a/b/../../.."] do
        assert SafePath.resolve(root, path, config) == {:error, :eacces},
               "#{inspect(path)} was not refused"
      end
    end

    test "an absolute path cannot replace the root", %{root: root, config: config} do
      assert {:ok, resolved} = SafePath.resolve(root, "/etc/passwd", config)
      assert resolved == Path.join([root, "etc", "passwd"])
    end

    test "a NUL inside a segment is refused", %{root: root, config: config} do
      assert SafePath.resolve(root, "dir/a\0b", config) == {:error, :einval}
    end

    test "a path longer than the limit is ENAMETOOLONG", %{root: root} do
      config = Config.build!(root: root, max_path_length: byte_size(root) + 4)

      assert SafePath.resolve(root, "abcdef", config) == {:error, :enametoolong}
    end

    test "a non-directory in the middle of a path is ENOTDIR",
         %{root: root, config: config} do
      assert SafePath.resolve(root, "file.txt/below", config) == {:error, :enotdir}
    end
  end

  describe "symlinks" do
    setup %{root: root} do
      File.ln_s!("/etc", Path.join(root, "escape"))
      File.ln_s!("dir", Path.join(root, "inside"))
      File.ln_s!(Path.join(root, "file.txt"), Path.join([root, "dir", "alias"]))
      :ok
    end

    test "a symlink leading outside is refused", %{root: root, config: config} do
      assert SafePath.resolve(root, "escape/passwd", config) == {:error, :eloop}
    end

    test "a symlink is refused even as the final object", %{root: root, config: config} do
      assert SafePath.resolve(root, "escape", config) == {:error, :eloop}
    end

    test "a symlink staying inside the root is refused too",
         %{root: root, config: config} do
      # The deny profile does not care where a link points: v1 follows none of
      # them (handoff section 14.1, ADR 3).
      assert SafePath.resolve(root, "inside", config) == {:error, :eloop}
      assert SafePath.resolve(root, "inside/alias", config) == {:error, :eloop}
      assert SafePath.resolve(root, "dir/alias", config) == {:error, :eloop}
    end
  end

  describe "canonical_root" do
    test "resolves a symlinked root, because the root is administrator supplied",
         %{root: root} do
      link = Path.join(System.tmp_dir!(), "etnfsd-link-#{System.unique_integer([:positive])}")
      File.ln_s!(root, link)
      on_exit(fn -> File.rm_rf(link) end)

      assert SafePath.canonical_root(link) == {:ok, root}
    end

    test "a file is not a root", %{root: root} do
      assert SafePath.canonical_root(Path.join(root, "file.txt")) == {:error, :enotdir}
    end

    test "a missing root is reported instead of silently accepted", %{root: root} do
      assert SafePath.canonical_root(Path.join(root, "missing")) == {:error, :enoent}
    end
  end
end
