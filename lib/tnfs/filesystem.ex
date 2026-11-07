defmodule Tnfs.Filesystem do
  @moduledoc """
  Adapter between TNFS semantics and the Erlang `:file` module.

  Everything that is neither protocol framing nor path security lives here:
  the POSIX open flags, the 22 byte STAT structure, the saturation policy for
  fields that are narrower than the value they carry, and the translation of
  every `:file` error into a TNFS status.

  Files are opened in `:raw` mode, so the calling session process performs the
  I/O itself instead of handing it to an intermediate file process. One
  session then owns its descriptors outright: when the session dies the
  descriptors die with it.
  """

  import Bitwise

  alias Tnfs.Error
  alias Tnfs.Filesystem.Raw

  # OPEN flags (handoff section 3.3).
  @access_mask 0x0003
  @rdonly 0x0001
  @wronly 0x0002
  @rdwr 0x0003
  @append 0x0008
  @creat 0x0100
  @trunc 0x0200
  @excl 0x0400
  @known_flags @access_mask ||| @append ||| @creat ||| @trunc ||| @excl

  @u16_max 0xFFFF
  @u32_max 0xFFFFFFFF
  @u64_max 0xFFFFFFFFFFFFFFFF

  defmodule Handle do
    @moduledoc """
    An open file: the raw descriptor plus what the client may do with it.

    `size` is the size the file had when it was opened, carried out of the
    `lstat` that opening performs anyway. It is `nil` for a file this call
    created, which is empty, and for a file whose size could not be read. It
    is not refreshed: it describes the open, not the file, and the only reader
    is the live transfer panel, which needs a denominator rather than a fact
    about the disk.
    """
    @type t :: %__MODULE__{}
    defstruct [:device, :path, :readable, :writable, :append, :size]
  end

  defmodule Entry do
    @moduledoc """
    One materialised directory entry: the name the client sees plus exactly the
    metadata READDIRX puts on the wire (handoff section 3.2).
    """
    @type t :: %__MODULE__{}
    defstruct name: "",
              directory?: false,
              hidden?: false,
              special?: false,
              size: 0,
              mtime: 0,
              ctime: 0
  end

  @doc """
  Opens a file according to the TNFS flag word.

  The TNFS flags are POSIX `open(2)` flags, and Erlang's mode list is not: it
  offers a handful of fixed combinations in which CREAT, TRUNC and EXCL are
  welded to an access mode. The mapping is therefore explicit here.

      TNFS                        Erlang                       exact?
      RDONLY                      [:read]                      yes
      RDONLY|CREAT                [:read, :exclusive] or
                                  [:read]                      yes
      WRONLY|TRUNC                [:write]                     yes
      WRONLY|APPEND               [:append]                    yes
      WRONLY (no TRUNC, no
        APPEND) on an
        existing file             [:read, :write]              no - see below
      RDWR                        [:read, :write]              yes
      RDWR|TRUNC                  [:read, :write] + truncate   yes
      RDWR|APPEND                 [:read, :append]             yes

  The single inexact case is plain `O_WRONLY` on a file that already exists.
  `[:write]` is the only write-without-read mode Erlang offers and it carries
  `O_TRUNC`, which would destroy the file the client asked to write into;
  `[:append]` cannot seek. So `[:read, :write]` is used: the data and the
  positioning are right, and the only visible difference is that a file the
  caller may write but not read is refused with EACCES. Losing a file is worse
  than refusing to open an unreadable one.

  `mode` is applied only to a file this call actually created - opening an
  existing file with `O_CREAT` must not re-permission it - and a failure to
  apply it is an error, not a shrug: the descriptor is closed and the file this
  call created is removed, so no half-configured file and no leaked handle
  survive.

  Creation goes through `:exclusive`, which is `O_CREAT|O_EXCL` and atomic, so
  `CREAT|EXCL` cannot be won by two sessions and "did I create this?" is
  answered by the kernel rather than by an earlier `lstat`.
  """
  @spec open(binary(), 0..0xFFFF, 0..0xFFFF, keyword()) ::
          {:ok, Handle.t()} | {:error, atom()}
  def open(path, flags, mode, opts) do
    read_only = Keyword.fetch!(opts, :read_only)
    mode_mask = Keyword.fetch!(opts, :mode_mask)
    access = flags &&& @access_mask

    with :ok <- validate_flags(flags),
         :ok <- validate_mode(flags, mode, mode_mask),
         :ok <- check_write_intent(access, flags, read_only),
         {:ok, size} <- refuse_special(path),
         {:ok, device, created?} <- acquire(path, flags, access),
         :ok <- finish(path, device, flags, mode, created?) do
      {:ok,
       %Handle{
         device: device,
         path: path,
         readable: access in [@rdonly, @rdwr],
         writable: access in [@wronly, @rdwr],
         append: (flags &&& @append) != 0,
         # A file that TRUNC emptied is not the size it was found at, and a
         # file that did not exist has no size to report.
         size: if((flags &&& @trunc) != 0, do: 0, else: size)
       }}
    end
  end

  @doc "Closes a file handle."
  @spec close(Handle.t()) :: :ok
  def close(%Handle{device: device}) do
    _ = :file.close(device)
    :ok
  end

  @doc """
  Reads at most `count` bytes from the current position.

  A short read is still a success; only a read that starts at the end of the
  file is EOF (handoff section 3.3).
  """
  @spec read(Handle.t(), pos_integer()) :: {:ok, binary()} | {:error, atom()}
  def read(%Handle{readable: false}, _count), do: {:error, :eacces}

  def read(%Handle{device: device}, count) do
    case :file.read(device, count) do
      {:ok, data} -> {:ok, data}
      :eof -> {:error, :eof}
      {:error, reason} -> {:error, Error.to_status(reason)}
    end
  end

  @doc "Writes `data` and returns the number of bytes accepted."
  @spec write(Handle.t(), binary()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def write(%Handle{writable: false}, _data), do: {:error, :eacces}

  def write(%Handle{device: device}, data) do
    case :file.write(device, data) do
      :ok -> {:ok, byte_size(data)}
      {:error, reason} -> {:error, Error.to_status(reason)}
    end
  end

  @doc """
  Moves the file position.

  The result travels as u32, so a position past 4 GiB cannot be reported
  honestly and is refused with EFBIG rather than wrapped.
  """
  @spec seek(Handle.t(), 0..0xFF, integer()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def seek(%Handle{device: device}, whence, offset) do
    with {:ok, location} <- seek_location(whence, offset),
         {:ok, position} <- do_seek(device, location) do
      if position > @u32_max, do: {:error, :efbig}, else: {:ok, position}
    end
  end

  @doc """
  Returns the 22 byte STAT payload for `path`.

  `lstat` is used, never `stat`: in the `deny` profile a symlink must be
  reported as what it is, not as whatever it points at.

  Path resolution already `lstat`s the final component, to prove it is not a
  symlink, so `known` lets the caller hand that result over rather than ask the
  kernel the same question twice.
  """
  @spec stat(binary(), File.Stat.t() | nil) :: {:ok, binary()} | {:error, atom()}
  def stat(path, known \\ nil)

  def stat(_path, %File.Stat{} = stat), do: encode_stat(stat)

  def stat(path, nil) do
    case Raw.lstat(path) do
      {:ok, stat} -> encode_stat(stat)
      {:error, reason} -> {:error, Error.to_status(reason)}
    end
  end

  defp encode_stat(stat) do
    if stat.size > @u32_max do
      # Wrapping would make a large file look small and a client would then
      # silently truncate it.
      {:error, :efbig}
    else
      {:ok,
       <<mode_bits(stat)::unsigned-little-16, low16(stat.uid)::unsigned-little-16,
         low16(stat.gid)::unsigned-little-16, stat.size::unsigned-little-32,
         epoch(stat.atime)::unsigned-little-32, epoch(stat.mtime)::unsigned-little-32,
         epoch(stat.ctime)::unsigned-little-32>>}
    end
  end

  @doc "Raw directory listing, without `.` and `..`."
  @spec names(binary()) :: {:ok, [binary()]} | {:error, atom()}
  def names(path) do
    case Raw.list_dir(path) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, Error.to_status(reason)}
    end
  end

  @doc "Directory listing for OPENDIR, materialised as a sorted snapshot."
  @spec list_dir(binary()) :: {:ok, [binary()]} | {:error, atom()}
  def list_dir(path) do
    with {:ok, entries} <- names(path) do
      # `.` and `..` are part of a POSIX directory and clients written against
      # a readdir-based server expect to see them. OPENDIRX leaves them out:
      # they are not results, and under TRAVERSE they would be a cycle.
      {:ok, [".", ".." | Enum.sort(entries)]}
    end
  end

  @doc """
  Describes one directory entry.

  `name` is the name inside `dir`, `display` the name the client will see -
  under TRAVERSE that is a path relative to the directory that was opened.
  `lstat` again: a symlink is reported as a special entry and never followed,
  so a traversal can neither leave the exported tree nor loop.
  """
  @spec entry(binary(), binary(), binary()) :: {:ok, Entry.t()} | :error
  def entry(dir, name, display \\ nil) do
    case Raw.lstat(Path.join(dir, name)) do
      {:ok, stat} ->
        {:ok,
         %Entry{
           name: display || name,
           directory?: stat.type == :directory,
           hidden?: match?(<<".", _::binary>>, name),
           special?: stat.type not in [:directory, :regular],
           size: min(stat.size, @u32_max),
           mtime: epoch(stat.mtime),
           ctime: epoch(stat.ctime)
         }}

      {:error, _reason} ->
        # The entry was listed a moment ago and is gone now, or it is
        # unreadable. Either way it is not a result; the caller decides whether
        # to drop it or to fall back to a bare name.
        :error
    end
  end

  @doc "Creates a directory."
  @spec mkdir(binary()) :: :ok | {:error, atom()}
  def mkdir(path), do: simple(Raw.make_dir(path))

  @doc """
  Removes an empty directory.

  `:file.del_dir/1` reports a non-empty directory as `:eexist`, but TNFS has a
  dedicated ENOTEMPTY and a client can act on it, so the distinction is
  restored here.
  """
  @spec rmdir(binary()) :: :ok | {:error, atom()}
  def rmdir(path) do
    case Raw.del_dir(path) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :enotempty}
      {:error, reason} -> {:error, Error.to_status(reason)}
    end
  end

  @doc "Removes a file."
  @spec unlink(binary()) :: :ok | {:error, atom()}
  def unlink(path), do: simple(Raw.delete(path))

  @doc "Renames a file or directory."
  @spec rename(binary(), binary()) :: :ok | {:error, atom()}
  def rename(source, destination), do: simple(Raw.rename(source, destination))

  @doc """
  Changes the permission bits of `path`.

  Only the bits allowed by `mask` are passed through; anything else is EINVAL
  rather than silently dropped (handoff section 14.1, ADR 5).
  """
  @spec chmod(binary(), 0..0xFFFF, 0..0xFFFF) :: :ok | {:error, atom()}
  def chmod(path, mode, mask) do
    if (mode &&& bnot(mask)) != 0 do
      {:error, :einval}
    else
      simple(:file.change_mode(path, mode))
    end
  end

  @doc """
  Total and available space of the filesystem holding `path`, in bytes.

  `available` is what an unprivileged user may actually use, not the total
  free blocks (handoff section 3.4).
  """
  @spec device_info(binary()) :: {:ok, non_neg_integer(), non_neg_integer()} | {:error, atom()}
  def device_info(path) do
    case :disksup.get_disk_info(String.to_charlist(path)) do
      [{_mount, total_kib, available_kib, _capacity} | _rest] when total_kib > 0 ->
        {:ok, total_kib * 1024, available_kib * 1024}

      _other ->
        {:error, :eio}
    end
  end

  @doc "Saturates a byte count to u32 KiB. Wrapping would report a tiny disk."
  @spec kib(non_neg_integer()) :: 0..0xFFFFFFFF
  def kib(bytes), do: min(div(bytes, 1024), @u32_max)

  @doc "Saturates a byte count to u64."
  @spec bytes(non_neg_integer()) :: 0..0xFFFFFFFFFFFFFFFF
  def bytes(value), do: min(value, @u64_max)

  defp validate_flags(flags) do
    cond do
      (flags &&& bnot(@known_flags)) != 0 -> {:error, :einval}
      (flags &&& @access_mask) == 0 -> {:error, :einval}
      (flags &&& @excl) != 0 and (flags &&& @creat) == 0 -> {:error, :einval}
      true -> :ok
    end
  end

  # Read-only is enforced here as well as in the session, because this is the
  # last point before the filesystem is touched (handoff section 8).
  defp check_write_intent(access, flags, read_only) do
    writes? = access != @rdonly or (flags &&& (@creat ||| @trunc ||| @append)) != 0

    if read_only and writes?, do: {:error, :eperm}, else: :ok
  end

  # The creation mode only reaches the filesystem on CREAT, and only the bits
  # of the supported POSIX profile may reach it at all; anything else is EINVAL
  # rather than silently dropped (handoff section 14.1, ADR 5). Checked before
  # anything is opened or created, so a rejected mode leaves no trace.
  defp validate_mode(flags, mode, mask) do
    if (flags &&& @creat) != 0 and (mode &&& bnot(mask)) != 0 do
      {:error, :einval}
    else
      :ok
    end
  end

  # Every Erlang write mode implies O_CREAT, so a missing file would be created
  # even without CREAT, and every one of them would happily open a symlink or a
  # device. `lstat` first: a directory is EISDIR, a symlink is refused by the
  # deny profile (handoff section 14.1, ADR 4), and anything that is not a
  # regular file is not a file this server serves.
  #
  # The size comes back with the verdict. This `lstat` has already been paid
  # for, so passing its result on costs nothing, whereas asking again after
  # the file is open would add a syscall to every OPEN -
  # `bench/syscalls.exs` exists because that is how syscall counts grow.
  defp refuse_special(path) do
    case Raw.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      {:ok, %File.Stat{type: :directory}} -> {:error, :eisdir}
      {:ok, %File.Stat{type: :symlink}} -> {:error, :eloop}
      {:ok, _stat} -> {:error, :eacces}
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, Error.to_status(reason)}
    end
  end

  # Returns the open descriptor and whether this call is the one that created
  # the file. The exclusive attempt comes first precisely so that answer comes
  # from the kernel: between an `lstat` and an `open` another session can
  # create the file, and CREAT|EXCL must never have two winners.
  defp acquire(path, flags, access) do
    modes = erlang_modes(flags, access)

    if (flags &&& @creat) != 0 do
      create(path, flags, modes)
    else
      open_existing(path, modes)
    end
  end

  defp create(path, flags, modes) do
    case :file.open(path, [:exclusive | modes]) do
      {:ok, device} ->
        {:ok, device, true}

      {:error, :eexist} ->
        if (flags &&& @excl) != 0 do
          # Exactly one caller can reach the clause above, so EXCL has exactly
          # one winner however many sessions race for it.
          {:error, :eexist}
        else
          # The file was already there, or another session created it first.
          # Either way it is opened as found and its mode is left alone.
          open_existing(path, modes)
        end

      {:error, reason} ->
        {:error, Error.to_status(reason)}
    end
  end

  defp open_existing(path, modes) do
    # Without CREAT a missing file is ENOENT, but every Erlang write mode
    # carries O_CREAT and would make one instead. There is no public API that
    # can express the difference, so it is checked first and the residual race
    # is a file created by a concurrent session being opened by this one -
    # which is what the client asked for anyway.
    case Raw.lstat(path) do
      {:error, :enoent} ->
        {:error, :enoent}

      _present ->
        case :file.open(path, modes) do
          {:ok, device} -> {:ok, device, false}
          {:error, reason} -> {:error, Error.to_status(reason)}
        end
    end
  end

  defp erlang_modes(flags, access) do
    base = [:raw, :binary]
    append? = (flags &&& @append) != 0

    cond do
      # O_APPEND: writes go to the end whatever the position says.
      append? and access == @rdwr -> [:read, :append | base]
      append? -> [:append | base]
      access == @rdonly -> [:read | base]
      # `:write` alone is the only write mode that does not need read
      # permission, and the only one that truncates. That pairing is exactly
      # WRONLY|TRUNC and nothing else.
      access == @wronly and (flags &&& @trunc) != 0 -> [:write | base]
      true -> [:read, :write | base]
    end
  end

  # Anything that must happen after the file is open: the truncation Erlang's
  # mode list could not express, and the creation mode. Both can fail, and a
  # failure must not leave the caller with a handle to a file in a state it did
  # not ask for.
  defp finish(path, device, flags, mode, created?) do
    with :ok <- apply_truncation(device, flags, created?),
         :ok <- apply_creation_mode(path, mode, created?) do
      :ok
    else
      {:error, reason} ->
        _ = :file.close(device)
        # Only a file this call brought into existence is removed; an existing
        # file is never destroyed because a later step failed.
        if created?, do: _ = Raw.delete(path)
        {:error, Error.to_status(reason)}
    end
  end

  # Of all the mode lists only a bare `:write` truncates, and a freshly created
  # file is empty already. Every other combination carrying TRUNC has to be
  # emptied here, at position zero, before the client sees the handle.
  defp apply_truncation(device, flags, created?) do
    self_truncating? =
      (flags &&& @append) == 0 and (flags &&& @access_mask) == @wronly

    if (flags &&& @trunc) != 0 and not created? and not self_truncating? do
      :file.truncate(device)
    else
      :ok
    end
  end

  defp apply_creation_mode(_path, _mode, false), do: :ok
  defp apply_creation_mode(path, mode, true), do: :file.change_mode(path, mode)

  defp seek_location(0, offset), do: {:ok, {:bof, offset}}
  defp seek_location(1, offset), do: {:ok, {:cur, offset}}
  defp seek_location(2, offset), do: {:ok, {:eof, offset}}
  # REFERENCE treats anything else as SET; guessing is worse than refusing.
  defp seek_location(_whence, _offset), do: {:error, :einval}

  defp do_seek(device, location) do
    case :file.position(device, location) do
      {:ok, position} -> {:ok, position}
      {:error, :einval} -> {:error, :einval}
      {:error, reason} -> {:error, Error.to_status(reason)}
    end
  end

  defp simple(:ok), do: :ok
  defp simple({:error, reason}), do: {:error, Error.to_status(reason)}

  # `File.Stat` splits the POSIX mode into `mode` (which already holds the
  # permission bits and the type bits) - it is passed through unchanged so a
  # client can tell a directory from a file.
  defp mode_bits(%File.Stat{mode: mode}), do: low16(mode)

  defp low16(value) when is_integer(value) and value >= 0, do: value &&& @u16_max
  defp low16(_value), do: 0

  defp epoch(seconds) when is_integer(seconds) and seconds > 0, do: min(seconds, @u32_max)
  defp epoch(_other), do: 0
end
