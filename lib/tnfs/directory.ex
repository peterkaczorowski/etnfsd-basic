defmodule Tnfs.Directory do
  @moduledoc """
  The materialised listing behind OPENDIRX and the chunking behind READDIRX
  (handoff section 3.2).

  OPENDIRX takes a snapshot: filter, sort and cap happen once, and the position
  a client tells and seeks is a plain index into that snapshot. Changes made to
  the directory afterwards are invisible until it is opened again, which is the
  price of a deterministic, portable cookie.

  Two things bound the work, because both the pattern and the tree are outside
  the server's control:

    * the result set is capped at 65535 entries, since the wire counter is a
      u16 and the handoff forbids letting it wrap silently;
    * the walk has a visit budget (`max_dir_scan`). A TRAVERSE over a huge tree
      that matches almost nothing fails with E2BIG rather than silently
      returning a truncated listing that the client would read as complete.

  The walk runs inside the session process, so a slow directory delays that one
  session and nothing else.
  """

  import Bitwise

  alias Tnfs.Config
  alias Tnfs.Filesystem
  alias Tnfs.Filesystem.Entry
  alias Tnfs.Filesystem.Raw
  alias Tnfs.Glob

  # diropts (handoff section 3.2).
  @no_foldersfirst 0x01
  @no_skiphidden 0x02
  @no_skipspecial 0x04
  @dir_pattern 0x08
  @traverse 0x10
  @no_folders 0x20
  @known_diropts @no_foldersfirst ||| @no_skiphidden ||| @no_skipspecial ||| @dir_pattern |||
                   @traverse ||| @no_folders

  # sortopts.
  @sort_none 0x01
  @sort_case 0x02
  @sort_descending 0x04
  @sort_modified 0x08
  @sort_size 0x10
  @known_sortopts @sort_none ||| @sort_case ||| @sort_descending ||| @sort_modified ||| @sort_size

  # `matched_count` and `first_position` are both u16.
  @wire_max 0xFFFF

  # count:u8, dir_status:u8, first_position:u16.
  @chunk_header 4
  # entry_flags:u8, size:u32, mtime:u32, ctime:u32, and the NUL after the name.
  @entry_overhead 14

  @eof_bit 0x01
  @flag_directory 0x01
  @flag_hidden 0x02
  @flag_special 0x04

  @doc """
  Smallest `max_response_payload` at which READDIRX can return anything.

  A chunk is the header plus at least one entry, and the shortest possible name
  is one byte. Below this the per-chunk budget leaves no room for an entry and
  every READDIRX on a non-empty directory answers with an empty chunk forever,
  so `Tnfs.Config` refuses the value at boot instead.
  """
  @spec min_response_payload() :: pos_integer()
  def min_response_payload, do: @chunk_header + @entry_overhead + 1

  @doc """
  Builds the snapshot for an OPENDIRX request.

  `path` is already resolved inside the export root.
  """
  @spec open(binary(), map(), Config.t()) :: {:ok, [Entry.t()]} | {:error, atom()}
  def open(path, args, %Config{} = config) do
    queue = :queue.from_list([{path, ""}])

    with :ok <- validate(args),
         {:ok, opts} <- options(path, args, config),
         {:ok, collected} <- walk(queue, opts, collector(args), config.max_dir_scan) do
      {:ok, snapshot(collected)}
    end
  end

  @doc """
  Builds one READDIRX response from the entries a directory handle still owes.

  Returns `:eof` when the handle is exhausted, so that READDIRX answers exactly
  once and never sends a payload after an EOF (handoff section 10, item 11).
  """
  @spec chunk(map(), 0..255, Config.t()) :: :eof | {:ok, binary(), map()} | {:error, atom()}
  def chunk(%{rest: []}, _requested, _config), do: :eof

  def chunk(dir, requested, %Config{} = config) do
    if dir.position > @wire_max do
      # `first_position` is a u16 even though TELLDIR is a u32. Wrapping it
      # would point the client at the wrong entry, so the limitation is
      # reported instead of hidden (handoff section 3.2).
      {:error, :einval}
    else
      budget = config.max_response_payload - @chunk_header
      wanted = if requested == 0, do: 255, else: requested
      {taken, rest} = take(dir.rest, dir.path, wanted, budget, [])
      {:ok, encode(taken, rest, dir.position), advance(dir, length(taken), rest)}
    end
  end

  @doc "Name of a snapshot entry, whether it carries metadata or not."
  @spec name(Entry.t() | binary()) :: binary()
  def name(%Entry{name: name}), do: name
  def name(name) when is_binary(name), do: name

  # --- request options -------------------------------------------------------

  defp validate(args) do
    if (args.diropts &&& bnot(@known_diropts)) != 0 or
         (args.sortopts &&& bnot(@known_sortopts)) != 0 do
      # Unknown bits are refused rather than ignored, exactly as for the OPEN
      # flag word: a client that asks for something this server does not do
      # must find out now, not from a wrong listing.
      {:error, :einval}
    else
      :ok
    end
  end

  defp options(path, args, config) do
    fold = (args.sortopts &&& @sort_case) == 0

    {:ok,
     %{
       root: path,
       pattern: if(args.pattern == "", do: nil, else: Glob.compile(args.pattern, fold)),
       ignore: ignore_patterns(path, config, fold),
       skip_hidden?: (args.diropts &&& @no_skiphidden) == 0,
       skip_special?: (args.diropts &&& @no_skipspecial) == 0,
       dir_pattern?: (args.diropts &&& @dir_pattern) != 0,
       traverse?: (args.diropts &&& @traverse) != 0,
       no_folders?: (args.diropts &&& @no_folders) != 0,
       # A name that could never fit in a READDIRX response would stall the
       # handle forever, so it is not a result at all. Only TRAVERSE can
       # produce one, since a plain entry name is far shorter than this.
       max_name: config.max_response_payload - @chunk_header - @entry_overhead
     }}
  end

  # `.ignore` is a REFERENCE feature rather than part of TNFS, so it sits behind
  # a compatibility switch that is off by default (handoff section 3.2). It is
  # read only from the directory that was opened, never cascaded into
  # subdirectories.
  defp ignore_patterns(_path, %Config{dir_ignore_file: false}, _fold), do: []

  defp ignore_patterns(path, config, fold) do
    path
    |> Path.join(".ignore")
    |> read_ignore(config.max_ignore_bytes)
    |> :binary.split(["\n", "\r\n"], [:global])
    |> Enum.map(&String.trim(&1, " "))
    |> Enum.map(&String.trim(&1, "\t"))
    |> Enum.reject(&(&1 == "" or match?(<<"#", _::binary>>, &1)))
    |> Enum.take(config.max_ignore_patterns)
    |> Enum.map(&Glob.compile(&1, fold))
  end

  # Only a plain, small, regular file counts as an ignore file.
  #
  # `File.read/1` follows symlinks, so a `.ignore` pointing at /etc/passwd used
  # to pull a file from outside the export into the server. The type is decided
  # by an `lstat` that does not follow the final component, and a symlink is
  # refused without its target ever being opened, which is what `symlinks:
  # :deny` means everywhere else (handoff section 14.1, ADR 4). The same check
  # keeps a directory, a device or a FIFO from being opened - a FIFO would
  # block the session process until somebody wrote to it.
  #
  # Anything that is not a usable ignore file contributes no patterns rather
  # than failing the listing. `.ignore` hides entries for cosmetic reasons
  # only, so a missing filter returns a superset the client can still read,
  # whereas failing would let anyone able to drop a symlink into an exported
  # directory make that directory permanently unlistable.
  defp read_ignore(file, limit) do
    case Raw.lstat(file) do
      {:ok, %File.Stat{type: :regular}} -> read_bounded(file, limit)
      {:ok, stat} -> refused(file, stat.type)
      {:error, :enoent} -> <<>>
      {:error, reason} -> refused(file, reason)
    end
  end

  # One byte more than the limit is asked for, so "too large" is decided by what
  # arrived rather than by a size the file could have changed since the lstat.
  # An oversize file is refused instead of truncated: cutting the last line in
  # half would turn `*.bak` into a pattern that hides something else.
  defp read_bounded(file, limit) do
    case :file.open(file, [:read, :raw, :binary]) do
      {:ok, device} ->
        result = :file.read(device, limit + 1)
        :file.close(device)

        case result do
          {:ok, contents} when byte_size(contents) <= limit -> contents
          {:ok, _oversize} -> refused(file, :too_large)
          :eof -> <<>>
          {:error, reason} -> refused(file, reason)
        end

      {:error, reason} ->
        refused(file, reason)
    end
  end

  defp refused(file, reason) do
    :telemetry.execute([:tnfs, :dir, :ignore_refused], %{count: 1}, %{
      path: file,
      reason: reason
    })

    <<>>
  end

  defp cap(args) do
    if args.max_results == 0, do: @wire_max, else: min(args.max_results, @wire_max)
  end

  # --- walking ---------------------------------------------------------------
  #
  # Breadth-first over an explicit queue rather than recursion into the stack,
  # so a deep tree costs memory in the heap where the budget can see it. The
  # queue is `:queue`, not a list: a wide directory used to append with
  # `queue ++ [entry]`, which copies the queue once per subdirectory and turns a
  # single level of n directories into O(n^2) work.

  defp walk(queue, opts, acc, budget) do
    cond do
      complete?(acc) ->
        # Nothing still on the queue could displace an entry already collected,
        # so the rest of the tree is not worth a syscall.
        {:ok, acc}

      budget <= 0 ->
        exhausted()

      true ->
        case :queue.out(queue) do
          {:empty, _queue} -> {:ok, acc}
          {{:value, {dir, prefix}}, queue} -> enter(dir, prefix, queue, opts, acc, budget)
        end
    end
  end

  defp enter(dir, prefix, queue, opts, acc, budget) do
    case Filesystem.names(dir) do
      {:ok, names} ->
        case visit(Enum.sort(names), dir, prefix, opts, acc, queue, budget) do
          {:ok, acc, queue, budget} -> walk(queue, opts, acc, budget)
          {:error, status} -> {:error, status}
        end

      {:error, status} when prefix == "" ->
        {:error, status}

      {:error, _status} ->
        # A subdirectory that became unreadable mid-walk is skipped; failing the
        # whole traversal because of one entry would be worse for the client.
        walk(queue, opts, acc, budget - 1)
    end
  end

  defp visit([], _dir, _prefix, _opts, acc, queue, budget), do: {:ok, acc, queue, budget}

  # The budget is checked here and not only between directories. One directory
  # holding more entries than `max_dir_scan` used to be walked to its end before
  # anything noticed, which is precisely the case the budget exists for.
  defp visit(_names, _dir, _prefix, _opts, _acc, _queue, budget) when budget <= 0 do
    exhausted()
  end

  defp visit([name | names], dir, prefix, opts, acc, queue, budget) do
    if complete?(acc) do
      {:ok, acc, queue, budget}
    else
      {acc, queue} =
        case Filesystem.entry(dir, name, Path.join(prefix, name)) do
          {:ok, entry} -> place(entry, dir, name, opts, acc, queue)
          :error -> {acc, queue}
        end

      visit(names, dir, prefix, opts, acc, queue, budget - 1)
    end
  end

  defp exhausted do
    :telemetry.execute([:tnfs, :dir, :scan_budget_exceeded], %{count: 1}, %{})
    {:error, :e2big}
  end

  defp place(entry, dir, name, opts, acc, queue) do
    cond do
      entry.hidden? and opts.skip_hidden? -> {acc, queue}
      entry.special? and opts.skip_special? -> {acc, queue}
      byte_size(entry.name) > opts.max_name -> {acc, queue}
      ignored?(entry, opts) -> {acc, queue}
      entry.directory? -> descend(entry, dir, name, opts, acc, queue)
      matches?(entry, opts) -> {collect(acc, entry), queue}
      true -> {acc, queue}
    end
  end

  defp descend(entry, dir, name, opts, acc, queue) do
    queue =
      if opts.traverse?,
        do: :queue.in({Path.join(dir, name), entry.name}, queue),
        else: queue

    cond do
      opts.no_folders? -> {acc, queue}
      opts.dir_pattern? and not matches?(entry, opts) -> {acc, queue}
      true -> {collect(acc, entry), queue}
    end
  end

  defp matches?(_entry, %{pattern: nil}), do: true
  defp matches?(entry, opts), do: Glob.match?(opts.pattern, Path.basename(entry.name))

  defp ignored?(entry, opts) do
    base = Path.basename(entry.name)
    Enum.any?(opts.ignore, &Glob.match?(&1, base))
  end

  # --- collecting and ordering -----------------------------------------------
  #
  # The walk never holds every match. The answer is the first `cap` entries of
  # `sort(matches) |> group(matches)`, and that prefix can be built from bounded
  # state:
  #
  #   * grouping is a partition into directories and files, so each group is
  #     collected on its own and the answer is at most `cap` from each;
  #   * without sorting the order inside a group is the order they were found,
  #     so once a group holds `cap` entries nothing found later can enter it -
  #     and once the group that comes first holds `cap`, the answer is settled
  #     and the walk stops there;
  #   * with sorting the whole tree still has to be visited, because the first
  #     entry in sorted order can be the last one found. Only `cap` of them are
  #     kept: the list is trimmed back to the best `cap` whenever it reaches
  #     twice that, which bounds memory without sorting more than once per
  #     `cap` entries.
  #
  # `max_dir_scan` still bounds how much is visited; this bounds what is held.

  defp collector(args) do
    %{
      cap: cap(args),
      sorted?: (args.sortopts &&& @sort_none) == 0,
      sortopts: args.sortopts,
      order: if((args.sortopts &&& @sort_descending) != 0, do: :desc, else: :asc),
      grouped?: grouped?(args),
      # `:all` keeps the found order across both kinds, which is what
      # NO_FOLDERSFIRST asks for.
      groups:
        if(grouped?(args),
          do: %{dirs: {[], 0}, files: {[], 0}},
          else: %{all: {[], 0}}
        )
    }
  end

  # NO_FOLDERS discards every directory, so the directory group would stay empty
  # for the whole walk and `take([] ++ files, cap)` is just `take(files, cap)`.
  # Grouping is then pure overhead, and worse, it removes the only condition
  # that lets the walk stop: the collector would wait for a group that cannot
  # receive an entry.
  defp grouped?(args) do
    (args.diropts &&& @no_foldersfirst) == 0 and (args.diropts &&& @no_folders) == 0
  end

  defp collect(acc, entry) do
    group = group_of(acc, entry)
    {held, count} = Map.fetch!(acc.groups, group)

    cond do
      acc.sorted? and count + 1 >= 2 * acc.cap ->
        put_group(acc, group, {best([entry | held], acc), acc.cap})

      acc.sorted? ->
        put_group(acc, group, {[entry | held], count + 1})

      count < acc.cap ->
        put_group(acc, group, {[entry | held], count + 1})

      true ->
        acc
    end
  end

  defp put_group(acc, group, value), do: %{acc | groups: Map.put(acc.groups, group, value)}

  defp group_of(%{grouped?: false}, _entry), do: :all
  defp group_of(_acc, %Entry{directory?: true}), do: :dirs
  defp group_of(_acc, _entry), do: :files

  # A sorted listing can never stop early: the entry that belongs at position one
  # can be the last one found.
  defp complete?(%{sorted?: true}), do: false

  # Ungrouped, the single group is the answer, so filling it ends the walk.
  defp complete?(%{grouped?: false} = acc) do
    {_held, count} = acc.groups.all
    count >= acc.cap
  end

  # Grouped, the answer is `take(dirs ++ files, cap)`. A full directory group
  # therefore fills the answer on its own and no file can reach it, found or
  # unfound. The reverse does not hold: a full file group says nothing, because
  # a directory found later is placed ahead of every file and pushes the last
  # one out. Requiring both groups was correct but never stopped a listing of
  # directories only, which is the case where stopping is worth the most.
  defp complete?(acc) do
    {_held, count} = acc.groups.dirs
    count >= acc.cap
  end

  defp snapshot(acc) do
    ordered = Map.new(acc.groups, fn {group, {held, _count}} -> {group, ordered(held, acc)} end)

    case acc.grouped? do
      true -> Enum.take(ordered.dirs ++ ordered.files, acc.cap)
      false -> ordered.all
    end
  end

  defp ordered(held, %{sorted?: true} = acc), do: best(held, acc)
  defp ordered(held, _acc), do: Enum.reverse(held)

  defp best(held, acc) do
    held |> Enum.sort_by(&key(&1, acc.sortopts), acc.order) |> Enum.take(acc.cap)
  end

  defp key(entry, sortopts) do
    # The name is always the tie-breaker, so two entries with the same size or
    # timestamp still come back in the same order on every call.
    name = if (sortopts &&& @sort_case) != 0, do: entry.name, else: downcase(entry.name)

    cond do
      (sortopts &&& @sort_size) != 0 -> {entry.size, name}
      (sortopts &&& @sort_modified) != 0 -> {entry.mtime, name}
      true -> {name, 0}
    end
  end

  defp downcase(name), do: for(<<byte <- name>>, into: <<>>, do: <<fold_byte(byte)>>)

  defp fold_byte(byte) when byte in ?A..?Z, do: byte ||| 0x20
  defp fold_byte(byte), do: byte

  # --- response chunking -----------------------------------------------------

  defp take([], _dir, _wanted, _budget, acc), do: {Enum.reverse(acc), []}

  defp take(rest, _dir, 0, _budget, acc), do: {Enum.reverse(acc), rest}

  defp take([head | rest], dir, wanted, budget, acc) do
    entry = detail(head, dir)
    cost = @entry_overhead + byte_size(entry.name)

    if cost > budget do
      {Enum.reverse(acc), [head | rest]}
    else
      take(rest, dir, wanted - 1, budget - cost, [entry | acc])
    end
  end

  # A handle opened with plain OPENDIR holds bare names; READDIRX on it is legal
  # and the metadata is fetched here, for the few entries this response carries,
  # rather than for the whole directory up front.
  defp detail(%Entry{} = entry, _dir), do: entry

  defp detail(name, dir) when is_binary(name) do
    case Filesystem.entry(dir, name) do
      {:ok, entry} -> entry
      :error -> %Entry{name: name}
    end
  end

  defp encode(taken, rest, position) do
    status = if rest == [], do: @eof_bit, else: 0

    body =
      for entry <- taken, into: <<>> do
        <<entry_flags(entry), entry.size::unsigned-little-32, entry.mtime::unsigned-little-32,
          entry.ctime::unsigned-little-32, entry.name::binary, 0>>
      end

    <<length(taken), status, position::unsigned-little-16, body::binary>>
  end

  defp entry_flags(entry) do
    flag(entry.directory?, @flag_directory) ||| flag(entry.hidden?, @flag_hidden) |||
      flag(entry.special?, @flag_special)
  end

  defp flag(true, bit), do: bit
  defp flag(false, _bit), do: 0

  defp advance(dir, count, rest), do: %{dir | position: dir.position + count, rest: rest}
end
