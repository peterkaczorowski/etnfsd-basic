defmodule Tnfs.DirectoryTest do
  @moduledoc """
  OPENDIRX and READDIRX end to end: filtering, ordering, chunking and the
  bounds that keep a hostile request cheap.
  """

  use Tnfs.ServerCase, async: false

  import Bitwise

  @moduletag config: [read_only: false]

  # diropts
  @no_foldersfirst 0x01
  @no_skiphidden 0x02
  @dir_pattern 0x08
  @traverse 0x10
  @no_folders 0x20

  # sortopts
  @sort_none 0x01
  @sort_case 0x02
  @sort_descending 0x04
  @sort_modified 0x08
  @sort_size 0x10

  setup context do
    root = context.root

    # Sizes deliberately disagree with the alphabetical order, so a test that
    # claims to sort by size has to actually do it.
    File.write!(Path.join(root, "beta.txt"), "B")
    File.write!(Path.join(root, "Alpha.txt"), "AA")
    File.write!(Path.join(root, "gamma.dat"), "")
    File.write!(Path.join(root, ".hidden"), "")
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "sub/nested.txt"), "nested")

    %{sid: mount!(context)}
  end

  describe "listing" do
    test "returns every visible entry, directories first", context do
      assert names(context, "/") == ["sub", "Alpha.txt", "beta.txt", "gamma.dat"]
    end

    test "hidden entries are skipped unless asked for", context do
      refute ".hidden" in names(context, "/")
      assert ".hidden" in names(context, "/", diropts: @no_skiphidden)
    end

    test "`.` and `..` are never results", context do
      all = names(context, "/", diropts: @no_skiphidden)

      # They are not entries a client can do anything with, and under TRAVERSE
      # they would be a cycle.
      refute "." in all
      refute ".." in all
    end

    test "the matched count is the length of the snapshot", context do
      {response, args} = opendirx(context, "/", [])

      assert response.status == :success
      assert args.matched == 4
    end

    test "an unknown option bit is refused rather than ignored", context do
      {response, _args} = opendirx(context, "/", diropts: 0x40)
      assert response.status == :einval

      {response, _args} = opendirx(context, "/", sortopts: 0x20, seq: 2)
      assert response.status == :einval
    end

    test "a missing directory is ENOENT", context do
      {response, _args} = opendirx(context, "/nope", [])
      assert response.status == :enoent
    end

    test "the snapshot is taken once and does not see later changes", context do
      handle = open!(context, "/", [])
      File.write!(Path.join(context.root, "late.txt"), "")

      refute "late.txt" in drain(context, handle)
    end
  end

  describe "patterns" do
    test "a pattern selects files", context do
      assert names(context, "/", pattern: "*.txt") == ["sub", "Alpha.txt", "beta.txt"]
    end

    test "directories are kept regardless of the pattern by default", context do
      # The pattern is about files unless DIR_PATTERN says otherwise.
      assert "sub" in names(context, "/", pattern: "*.nothing")
    end

    test "DIR_PATTERN applies the pattern to directories too", context do
      refute "sub" in names(context, "/", pattern: "*.txt", diropts: @dir_pattern)
      assert "sub" in names(context, "/", pattern: "s*", diropts: @dir_pattern)
    end

    test "NO_FOLDERS drops directories", context do
      assert names(context, "/", diropts: @no_folders) == [
               "Alpha.txt",
               "beta.txt",
               "gamma.dat"
             ]
    end

    test "matching folds case unless CASE is set", context do
      assert "Alpha.txt" in names(context, "/", pattern: "alpha*")
      refute "Alpha.txt" in names(context, "/", pattern: "alpha*", sortopts: @sort_case)
    end
  end

  describe "ordering" do
    test "the default is by name, case-insensitive, ascending", context do
      assert names(context, "/", diropts: @no_folders) == [
               "Alpha.txt",
               "beta.txt",
               "gamma.dat"
             ]
    end

    test "CASE compares raw bytes, so uppercase sorts before lowercase", context do
      dir = Path.join(context.root, "mixed")
      File.mkdir_p!(dir)
      for name <- ~w(Zeta.txt apple.txt), do: File.write!(Path.join(dir, name), "")

      assert names(context, "/mixed") == ["apple.txt", "Zeta.txt"]
      assert names(context, "/mixed", sortopts: @sort_case) == ["Zeta.txt", "apple.txt"]
    end

    test "DESCENDING reverses the entries but not the grouping", context do
      assert names(context, "/", sortopts: @sort_descending) == [
               "sub",
               "gamma.dat",
               "beta.txt",
               "Alpha.txt"
             ]
    end

    test "SIZE sorts by size", context do
      assert names(context, "/", diropts: @no_folders, sortopts: @sort_size) == [
               "gamma.dat",
               "beta.txt",
               "Alpha.txt"
             ]
    end

    test "SIZE wins over MODIFIED", context do
      both = @sort_size ||| @sort_modified

      assert names(context, "/", diropts: @no_folders, sortopts: both) ==
               names(context, "/", diropts: @no_folders, sortopts: @sort_size)
    end

    test "NO_FOLDERSFIRST leaves directories in the sorted order", context do
      assert names(context, "/", diropts: @no_foldersfirst) == [
               "Alpha.txt",
               "beta.txt",
               "gamma.dat",
               "sub"
             ]
    end

    test "NONE disables sorting but not grouping", context do
      listed = names(context, "/", sortopts: @sort_none)

      assert hd(listed) == "sub"
      assert Enum.sort(listed) == ["Alpha.txt", "beta.txt", "gamma.dat", "sub"]
    end
  end

  describe "traversal" do
    test "TRAVERSE descends and reports paths relative to the opened directory",
         context do
      assert "sub/nested.txt" in names(context, "/", diropts: @traverse)
    end

    test "a symlinked subdirectory is a special entry and is not descended into",
         context do
      File.ln_s!("/etc", Path.join(context.root, "escape"))

      listed = names(context, "/", diropts: @traverse)
      refute Enum.any?(listed, &String.starts_with?(&1, "escape/"))
    end

    @tag config: [read_only: false, max_dir_scan: 3]
    test "a traversal that scans too much fails loudly instead of truncating",
         context do
      {response, _args} = opendirx(context, "/", diropts: @traverse)
      assert response.status == :e2big
    end
  end

  describe "limits" do
    test "max_results caps the snapshot", context do
      assert names(context, "/", max_results: 2) == ["sub", "Alpha.txt"]
    end

    test "max_results 0 means no limit", context do
      assert length(names(context, "/", max_results: 0)) == 4
    end
  end

  describe "READDIRX" do
    test "a chunk carries the entries and their metadata", context do
      handle = open!(context, "/", diropts: @no_folders)
      {response, _args} = readdirx(context, handle, 0, 20)

      assert response.status == :success

      assert <<count, status, position::unsigned-little-16, body::binary>> = response.payload
      assert count == 3
      assert status == 1
      assert position == 0

      assert [alpha, beta, gamma] = entries(body)
      assert alpha.name == "Alpha.txt"
      assert alpha.size == 2
      assert beta.size == 1
      assert gamma.size == 0
      assert alpha.flags == 0
      assert alpha.mtime > 0
      assert alpha.ctime > 0
    end

    test "a directory entry is flagged as one", context do
      handle = open!(context, "/", [])

      assert [first | _rest] = entries_of(context, handle, 0, 20)
      assert first.name == "sub"
      assert (first.flags &&& 0x01) != 0
    end

    test "a hidden entry is flagged as one", context do
      handle = open!(context, "/", diropts: @no_folders ||| @no_skiphidden, pattern: ".hidden")

      assert [entry] = entries_of(context, handle, 0, 20)
      assert entry.name == ".hidden"
      assert (entry.flags &&& 0x02) != 0
    end

    test "requested_count limits the chunk and first_position tracks the cursor",
         context do
      handle = open!(context, "/", diropts: @no_folders)

      {response, _args} = readdirx(context, handle, 2, 20)
      assert <<2, 0, 0::unsigned-little-16, body::binary>> = response.payload
      assert Enum.map(entries(body), & &1.name) == ["Alpha.txt", "beta.txt"]

      {response, _args} = readdirx(context, handle, 2, 21)
      assert <<1, 1, 2::unsigned-little-16, body::binary>> = response.payload
      assert Enum.map(entries(body), & &1.name) == ["gamma.dat"]
    end

    test "the EOF flag is set on the response that carries the last entry",
         context do
      handle = open!(context, "/", diropts: @no_folders)

      {response, _args} = readdirx(context, handle, 0, 20)
      assert <<_count, 1, _position::16, _body::binary>> = response.payload

      # And the next call is a bare EOF, exactly once.
      {response, _args} = readdirx(context, handle, 0, 21)
      assert response.status == :eof
      assert response.payload == <<>>
    end

    test "a chunk never exceeds the response payload limit", context do
      for index <- 1..40 do
        File.write!(Path.join(context.root, String.duplicate("n", 60) <> "#{index}"), "")
      end

      handle = open!(context, "/", diropts: @no_folders)
      {response, _args} = readdirx(context, handle, 0, 20)

      assert byte_size(response.payload) <= context.config.max_response_payload
      assert <<count, 0, 0::16, _body::binary>> = response.payload
      assert count > 0 and count < 43
    end

    test "READDIRX works on a handle opened with plain OPENDIR", context do
      {response, args} = call(context, context.sid, 20, :opendir, %{path: "/"})
      assert response.status == :success

      {response, _args} = readdirx(context, args.handle, 2, 21)
      assert response.status == :success

      # `.` and `..` are part of a plain OPENDIR listing and keep their
      # metadata here.
      assert <<2, 0, 0::16, body::binary>> = response.payload
      assert Enum.map(entries(body), & &1.name) == [".", ".."]
    end

    test "an unknown handle is EBADF", context do
      {response, _args} = readdirx(context, 7, 0, 20)
      assert response.status == :ebadf
    end

    test "SEEKDIR repositions the cursor for both readers", context do
      handle = open!(context, "/", diropts: @no_folders)

      {response, _args} =
        call(context, context.sid, 20, :seekdir, %{handle: handle, position: 2})

      assert response.status == :success

      {response, _args} = readdirx(context, handle, 0, 21)
      assert <<1, 1, 2::unsigned-little-16, body::binary>> = response.payload
      assert Enum.map(entries(body), & &1.name) == ["gamma.dat"]
    end
  end

  describe ".ignore" do
    test "is off by default", context do
      File.write!(Path.join(context.root, ".ignore"), "*.dat\n")
      assert "gamma.dat" in names(context, "/")
    end

    @tag config: [read_only: false, dir_ignore_file: true]
    test "excludes matching entries when enabled", context do
      File.write!(Path.join(context.root, ".ignore"), "# comment\n\n  *.dat  \n")

      listed = names(context, "/")
      refute "gamma.dat" in listed
      assert "beta.txt" in listed
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp opendirx(context, path, opts) do
    args = %{
      diropts: Keyword.get(opts, :diropts, 0),
      sortopts: Keyword.get(opts, :sortopts, 0),
      max_results: Keyword.get(opts, :max_results, 0),
      pattern: Keyword.get(opts, :pattern, ""),
      path: path
    }

    call(context, context.sid, Keyword.get(opts, :seq, 1), :opendirx, args)
  end

  defp open!(context, path, opts) do
    {response, args} = opendirx(context, path, opts)
    assert response.status == :success
    args.handle
  end

  defp names(context, path, opts \\ []) do
    drain(context, open!(context, path, opts))
  end

  # Reads the whole snapshot with READDIR, one name per request.
  defp drain(context, handle) do
    Enum.reduce_while(2..300, [], fn seq, acc ->
      case call(context, context.sid, rem(seq, 256), :readdir, %{handle: handle}) do
        {%{status: :success}, args} -> {:cont, [args.name | acc]}
        {%{status: :eof}, _args} -> {:halt, Enum.reverse(acc)}
      end
    end)
  end

  defp readdirx(context, handle, requested, seq) do
    call(context, context.sid, seq, :readdirx, %{handle: handle, requested: requested})
  end

  defp entries_of(context, handle, requested, seq) do
    {response, _args} = readdirx(context, handle, requested, seq)
    <<_count, _status, _position::16, body::binary>> = response.payload
    entries(body)
  end

  defp entries(<<>>), do: []

  defp entries(
         <<flags, size::unsigned-little-32, mtime::unsigned-little-32, ctime::unsigned-little-32,
           rest::binary>>
       ) do
    [name, remaining] = :binary.split(rest, <<0>>)

    [
      %{flags: flags, size: size, mtime: mtime, ctime: ctime, name: name}
      | entries(remaining)
    ]
  end
end
