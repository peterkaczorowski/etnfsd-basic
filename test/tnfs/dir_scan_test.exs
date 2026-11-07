defmodule Tnfs.DirScanTest do
  @moduledoc """
  What an OPENDIRX walk is allowed to cost.

  The snapshot used to be built by collecting every match, sorting all of them
  and only then applying `max_results`, so asking for one entry could still cost
  a full traversal - and `max_dir_scan`, the bound that is supposed to stop
  exactly that, was only consulted between directories. These tests pin both the
  bound and the fact that bounding it did not change any answer.
  """

  use Tnfs.ServerCase, async: false

  import Bitwise

  @no_foldersfirst 0x01
  @no_folders 0x20
  @traverse 0x10

  @sort_none 0x01
  @sort_descending 0x04
  @sort_modified 0x08
  @sort_size 0x10

  @moduletag config: [read_only: false]

  setup context do
    %{sid: mount!(context)}
  end

  describe "max_results" do
    @tag config: [read_only: false, max_dir_scan: 4]
    test "stops the walk instead of being applied to a finished listing", context do
      # `a.txt` is the whole answer and it is the first thing found. Everything
      # after it is there to be expensive: `zbig` alone holds more entries than
      # the scan budget, so a walk that keeps going runs out of budget and the
      # client gets E2BIG instead of the one entry it asked for.
      File.write!(Path.join(context.root, "a.txt"), "")
      fill(Path.join(context.root, "zbig"), 200)
      fill(Path.join(context.root, "zzlast"), 1)

      assert listing(context, "/",
               max_results: 1,
               diropts: @no_foldersfirst ||| @no_folders ||| @traverse,
               sortopts: @sort_none
             ) == ["a.txt"]
    end

    test "returns exactly the prefix of the unlimited answer", context do
      fill(context.root, 20)

      full = listing(context, "/", seq: 1)
      limited = listing(context, "/", max_results: 5, seq: 10)

      assert limited == Enum.take(full, 5)
    end

    test "of zero still means no limit", context do
      fill(context.root, 20)
      assert length(listing(context, "/", max_results: 0)) == 20
    end
  end

  describe "a limit combined with sorting" do
    setup context do
      # More than twice any limit used below, so the bounded selection has to
      # trim at least once and cannot be a plain "keep everything".
      fill(context.root, 30)
      :ok
    end

    test "ascending by name gives the smallest entries, not the first found",
         context do
      full = listing(context, "/", seq: 1)
      assert listing(context, "/", max_results: 4, seq: 10) == Enum.take(full, 4)
    end

    test "descending by name gives the largest entries", context do
      full = listing(context, "/", sortopts: @sort_descending, seq: 1)

      assert listing(context, "/", sortopts: @sort_descending, max_results: 4, seq: 10) ==
               Enum.take(full, 4)
    end

    test "by size gives the smallest files", context do
      full = listing(context, "/", sortopts: @sort_size, seq: 1)

      assert listing(context, "/", sortopts: @sort_size, max_results: 4, seq: 10) ==
               Enum.take(full, 4)
    end

    test "by modification time gives the oldest files", context do
      full = listing(context, "/", sortopts: @sort_modified, seq: 1)

      assert listing(context, "/", sortopts: @sort_modified, max_results: 4, seq: 10) ==
               Enum.take(full, 4)
    end

    test "with folders first spans both groups", context do
      for index <- 1..8, do: File.mkdir_p!(Path.join(context.root, "d#{index}"))

      full = listing(context, "/", seq: 1)
      limited = listing(context, "/", max_results: 10, seq: 10)

      # Ten entries starting with all eight directories: the limit has to be
      # split across two independently collected groups and still land on the
      # same boundary the unlimited answer has.
      assert limited == Enum.take(full, 10)
      assert Enum.count(limited, &String.starts_with?(&1, "d")) == 8
    end
  end

  # Counting `:prim_file` calls (bench/syscalls.exs) showed which of these
  # combinations actually bounds the walk. Asking a 2000-entry directory of
  # nothing but directories for one entry cost 2001 filesystem calls, the same
  # as asking for all of them, because the collector waited for a group that
  # could never be filled. `max_dir_scan` pins that here exactly: a walk that
  # stops early stays inside a budget of four, one that does not returns E2BIG.
  describe "a limit with folders first" do
    @tag config: [read_only: false, max_dir_scan: 4]
    test "stops once the directories alone fill it", context do
      # The answer is `take(dirs ++ files, max_results)`. As soon as
      # `max_results` directories are in hand no file can reach the answer,
      # seen or unseen, so there is nothing left to learn. The collector used
      # to require the file group to be full as well - a condition a directory
      # containing no files at all can never meet.
      for index <- 1..50, do: File.mkdir_p!(numbered(context.root, index))

      assert listing(context, "/", max_results: 1, sortopts: @sort_none) == ["d01"]
    end

    @tag config: [read_only: false, max_dir_scan: 4]
    test "stops on the files alone when NO_FOLDERS removes the other group", context do
      # NO_FOLDERS discards every directory, so the directory group stays empty
      # for the whole walk and waiting for it to fill means never stopping.
      # With no directories in the answer there is nothing to group by, and the
      # files are already in their final order.
      fill(context.root, 50)

      assert listing(context, "/",
               max_results: 1,
               diropts: @no_folders,
               sortopts: @sort_none
             ) == ["f0001.txt"]
    end

    @tag config: [read_only: false, max_dir_scan: 100_000]
    test "keeps walking while the directories found so far cannot fill it", context do
      # Two directories and a limit of four: the two remaining places belong to
      # files, and which files they are is not known until the walk ends. A
      # directory appearing after every file still has to come first.
      File.mkdir_p!(Path.join(context.root, "adir"))
      fill(context.root, 20)
      File.mkdir_p!(Path.join(context.root, "zdir"))

      full = listing(context, "/", sortopts: @sort_none, seq: 1)
      limited = listing(context, "/", max_results: 4, sortopts: @sort_none, seq: 10)

      assert limited == Enum.take(full, 4)
      assert ["adir", "zdir" | _] = limited
    end

    @tag config: [read_only: false, max_dir_scan: 100_000]
    test "gives the same prefix for a directory holding only files", context do
      # Nothing here can ever fill the directory group, so this is the case
      # that has to keep costing a full walk. It is pinned so that a future
      # attempt to stop early cannot quietly return the wrong prefix.
      fill(context.root, 20)

      full = listing(context, "/", sortopts: @sort_none, seq: 1)
      limited = listing(context, "/", max_results: 3, sortopts: @sort_none, seq: 10)

      assert limited == Enum.take(full, 3)
    end
  end

  describe "the scan budget" do
    @tag config: [read_only: false, max_dir_scan: 16]
    test "is enforced inside a single directory, not only between them", context do
      # One flat directory was walked to its end whatever the budget said,
      # because the only check happened when the walk moved to the next
      # directory - and a flat directory never has a next one.
      fill(context.root, 100)

      assert {%{status: :e2big}, _args} = opendirx(context, "/", [])
    end

    @tag config: [read_only: false, max_dir_scan: 16]
    test "is reported even when nothing matched", context do
      fill(context.root, 100)

      # An empty listing and a listing cut short look the same to a client, so
      # running out of budget has to be an error rather than "no results".
      assert {%{status: :e2big}, _args} = opendirx(context, "/", pattern: "*.none")
    end

    @tag config: [read_only: false, max_dir_scan: 100_000]
    test "leaves a listing that fits well inside it alone", context do
      fill(context.root, 50)
      assert length(listing(context, "/")) == 50
    end
  end

  describe "a wide tree" do
    @tag config: [read_only: false, max_dir_scan: 100_000]
    test "is traversed without copying the pending queue per subdirectory",
         context do
      # Each subdirectory found used to be appended with `queue ++ [entry]`,
      # which copies the whole queue every time. In isolation that is 6 ms at
      # 1500 directories and 1160 ms at 20 000, against 0.1 ms and 2 ms for
      # `:queue`. At the width a test can afford to create, the difference is
      # smaller than the filesystem noise around it, so this asserts the answer
      # and a ceiling rather than the exponent.
      for index <- 1..1_500 do
        File.mkdir_p!(Path.join(context.root, "d#{String.pad_leading("#{index}", 4, "0")}"))
      end

      {elapsed, listed} =
        :timer.tc(fn ->
          listing(context, "/", diropts: @traverse, sortopts: @sort_none, timeout: 10_000)
        end)

      assert length(listed) == 1_500
      assert elapsed < 5_000_000, "traversal took #{div(elapsed, 1000)} ms"
    end

    @tag config: [read_only: false, max_dir_scan: 100_000]
    test "is still visited breadth first", context do
      File.mkdir_p!(Path.join(context.root, "a/deep"))
      File.mkdir_p!(Path.join(context.root, "b"))
      File.write!(Path.join(context.root, "a/deep/leaf.txt"), "")
      File.write!(Path.join(context.root, "b/shallow.txt"), "")

      listed =
        listing(context, "/",
          diropts: @traverse ||| @no_folders ||| @no_foldersfirst,
          sortopts: @sort_none
        )

      # `b/shallow.txt` sits one level up from `a/deep/leaf.txt`, so breadth
      # first has to reach it first even though `a` was queued first.
      assert listed == ["b/shallow.txt", "a/deep/leaf.txt"]
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Names, sizes and timestamps all disagree with each other, so a test that
  # claims to sort by one of them cannot pass by accident on another.
  defp fill(dir, count) do
    File.mkdir_p!(dir)

    for index <- 1..count do
      path = Path.join(dir, "f#{String.pad_leading("#{index}", 4, "0")}.txt")
      File.write!(path, String.duplicate("x", rem(index * 7, count) + 1))
      File.touch!(path, 1_600_000_000 + rem(index * 13, count))
    end
  end

  # Zero padded so that the sorted order the walk sees is the numeric one.
  defp numbered(root, index),
    do: Path.join(root, "d#{String.pad_leading("#{index}", 2, "0")}")

  defp opendirx(context, path, opts) do
    args = %{
      diropts: Keyword.get(opts, :diropts, 0),
      sortopts: Keyword.get(opts, :sortopts, 0),
      max_results: Keyword.get(opts, :max_results, 0),
      pattern: Keyword.get(opts, :pattern, ""),
      path: path
    }

    # The reply timeout is passed through rather than left at the helper's
    # default of one second. OPENDIRX does the whole walk before it answers, so
    # a test that allows five seconds for a wide traversal but reads the reply
    # with a one second timeout can never reach its own ceiling - it fails with
    # `:timeout` on a busy machine and the failure looks like a lost datagram
    # rather than a slow walk.
    call(context, context.sid, Keyword.get(opts, :seq, 1), :opendirx, args,
      timeout: Keyword.get(opts, :timeout, 1_000)
    )
  end

  defp listing(context, path, opts \\ []) do
    {response, args} = opendirx(context, path, opts)
    assert response.status == :success

    drain(context, args.handle, Keyword.get(opts, :seq, 1) + 1, [])
  end

  # READDIRX rather than READDIR: it is the reader the limit is meant for, and
  # it returns whole chunks instead of one name per datagram.
  defp drain(context, handle, seq, acc) do
    case call(context, context.sid, rem(seq, 256), :readdirx, %{handle: handle, requested: 0}) do
      {%{status: :success, payload: payload}, _args} ->
        drain(context, handle, seq + 1, acc ++ names_in(payload))

      {%{status: :eof}, _args} ->
        acc
    end
  end

  defp names_in(<<_count, _status, _position::unsigned-little-16, body::binary>>) do
    entries(body, [])
  end

  defp entries(<<>>, acc), do: Enum.reverse(acc)

  defp entries(
         <<_flags, _size::unsigned-little-32, _mtime::unsigned-little-32,
           _ctime::unsigned-little-32, rest::binary>>,
         acc
       ) do
    [name, rest] = :binary.split(rest, <<0>>)
    entries(rest, [name | acc])
  end
end
