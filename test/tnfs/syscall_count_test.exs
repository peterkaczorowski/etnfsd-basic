defmodule Tnfs.SyscallCountTest do
  @moduledoc """
  What a request is allowed to cost in filesystem calls.

  Timing tests cannot answer this. On the development machine a single `lstat`
  moved between 35 and 53 microseconds over consecutive runs, which is more than
  the difference these tests are about, so "it got slower" would be noise. A
  call count is exact: it does not move with machine load and it is the same
  number on every platform.

  The counts come from the VM's call-count tracer, which increments a counter on
  function entry rather than sending a trace message, so it does not perturb what
  it measures. `bench/syscalls.exs` prints the same numbers for a wider matrix;
  these are the ones worth failing a build over.
  """

  use Tnfs.ServerCase, async: false

  @no_foldersfirst 0x01
  @no_folders 0x20
  @sort_none 0x01

  @moduletag config: [read_only: false]

  # Resolving `/many` costs one `lstat` on `many` before the walk starts. It is
  # named rather than folded into the expected totals so that the entry counts
  # below stay readable as entry counts.
  @resolve 1

  # 200 directories and 200 files, and the sorted order puts every `d` before
  # every `f`.
  @entries 400
  @dirs 200

  setup context do
    File.write!(Path.join(context.root, "payload.bin"), "x")
    File.mkdir_p!(Path.join(context.root, "a/b/c"))
    File.write!(Path.join(context.root, "a/b/c/deep.bin"), "x")

    %{sid: mount!(context)}
  end

  describe "a path command" do
    test "checks each component once and does not repeat the last one", context do
      # Path resolution refuses a symlink anywhere in the path rather than
      # following it, so every component costs an `lstat`. The final component's
      # `lstat` is also the entire answer to STAT, and it used to be taken twice:
      # once to prove it was not a symlink and once to build the reply.
      assert lstats(fn -> stat!(context, "/payload.bin", 1) end) == 1
      assert lstats(fn -> stat!(context, "/a/b/c/deep.bin", 2) end) == 4
    end

    test "costs nothing at all when it never reaches the filesystem", context do
      # TELLDIR on a handle that was never opened is answered from session state.
      # Without this control a count of "one" above could just as well mean the
      # tracer was not running.
      assert lstats(fn ->
               assert {%{status: :ebadf}, _args} =
                        call(context, context.sid, 3, :telldir, %{
                          handle: 200
                        })
             end) == 0
    end
  end

  describe "an OPENDIRX walk" do
    setup context do
      dir = Path.join(context.root, "many")
      File.mkdir_p!(dir)
      for index <- 1..@dirs, do: File.mkdir_p!(Path.join(dir, "d#{index}"))
      for index <- 1..(@entries - @dirs), do: File.write!(Path.join(dir, "f#{index}.txt"), "")
      :ok
    end

    test "examines one entry per result when nothing found later can displace one",
         context do
      # Unsorted and ungrouped: entries stay in the order they were found, so the
      # first `max_results` of them are the answer and the rest are never looked
      # at.
      assert lstats(fn ->
               listing!(context, 4, max_results: 5, diropts: @no_foldersfirst)
             end) == @resolve + 5
    end

    test "examines one entry per result once the directories alone fill it", context do
      # Folders first: the answer is `take(directories ++ files, max_results)`, so
      # five directories fill it and no file can reach it. Waiting for the file
      # group to fill as well used to cost a walk over all 400 entries.
      assert lstats(fn -> listing!(context, 5, max_results: 5) end) == @resolve + 5
    end

    test "stops on the files alone when NO_FOLDERS leaves one group", context do
      # NO_FOLDERS discards every directory, so the directory group can never
      # fill and grouping by it means never stopping. It still costs an `lstat`
      # per directory - that is how a directory is discovered to be one - but it
      # stops five files in rather than walking all 400.
      assert lstats(fn ->
               listing!(context, 6, max_results: 5, diropts: @no_folders)
             end) == @resolve + @dirs + 5
    end

    test "examines every entry when the answer is not settled until the end", context do
      # Two cases that have to keep costing a full walk, pinned so that a future
      # attempt to bound them cannot quietly return the wrong prefix.
      #
      #   * sorted, because the entry belonging at position one can be the last
      #     one found;
      #   * folders first with more places than there are directories, because a
      #     directory found later is placed ahead of every file already held.
      assert lstats(fn -> listing!(context, 7, max_results: 5, sortopts: 0) end) ==
               @resolve + @entries

      assert lstats(fn -> listing!(context, 8, max_results: 250) end) ==
               @resolve + @entries
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Counts `lstat` and nothing else. `list_dir_all` is one call for a whole
  # directory however large, so including it would add a constant that hides the
  # per-entry number these tests are about.
  defp lstats(fun) do
    :erlang.trace_pattern({:prim_file, :read_link_info, 2}, true, [:call_count])
    :erlang.trace_pattern({:prim_file, :read_link_info, 2}, :restart, [:call_count])

    fun.()

    {:call_count, count} = :erlang.trace_info({:prim_file, :read_link_info, 2}, :call_count)
    :erlang.trace_pattern({:prim_file, :read_link_info, 2}, false, [:call_count])
    count
  end

  defp stat!(context, path, seq) do
    assert {%{status: :success}, _args} = call(context, context.sid, seq, :stat, %{path: path})
  end

  defp listing!(context, seq, opts) do
    args = %{
      diropts: Keyword.get(opts, :diropts, 0),
      sortopts: Keyword.get(opts, :sortopts, @sort_none),
      max_results: Keyword.fetch!(opts, :max_results),
      pattern: "*",
      path: "/many"
    }

    assert {%{status: :success}, _args} = call(context, context.sid, seq, :opendirx, args)
  end
end
