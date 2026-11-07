defmodule Tnfs.Filesystem.Raw do
  @moduledoc """
  Metadata syscalls that do not go through the global file server.

  `:file.read_link_info/2`, `:file.list_dir/1` and friends are implemented as
  calls into `:file_server_2`, a single GenServer for the whole VM. Every
  session in the server would queue behind every other session's `lstat`, which
  measurably serialises the whole system: one listing of 20 000 entries adds
  over a second of latency to an unrelated STAT, and total throughput stops
  responding to the number of dispatcher partitions.

  `:prim_file` is the same syscall without the detour - it runs on a dirty I/O
  scheduler in the calling process. Measured on this machine, 5 000 `lstat`
  calls per worker: `:file` gives 19 000/s at one worker and 23 000/s at eight,
  `:prim_file` gives 22 000/s and 103 000/s.

  Reads and writes of open files need no wrapper: they already bypass the file
  server because every descriptor is opened `:raw`.

  Names are read with the `_all` variants, which return the bytes the kernel
  gave us instead of silently skipping entries that are not valid in the
  system encoding. TNFS names are opaque bytes (handoff section 2.2), so an
  entry we cannot decode is still an entry the client must see.

  ## Compatibility risk

  `:prim_file` is an OTP internal module. It carries no compatibility promise,
  its functions are undocumented, and a release may change or remove them
  without a deprecation cycle. That risk is accepted for the throughput above
  and contained by this module: every call to `:prim_file` in the server is
  here, so an OTP release that breaks one breaks exactly one file.

  `Tnfs.Filesystem.RawTest` is the contract. It reads the list of imported
  `:prim_file` functions out of this module's own BEAM file, so a call added
  here is covered by the test without anyone remembering to list it, and it
  asserts both that each one is exported and that it still behaves as the
  callers assume.

  When moving to a new OTP release:

    1. run `mix test test/tnfs/filesystem/raw_test.exs` on the new release
       before anything else - it fails loudly rather than at the first client
       request,
    2. run the full suite, which exercises the adapter through real requests,
    3. if a function is gone, replace this module's body with the `:file`
       equivalent and re-measure; do not shim it, because a shim that goes back
       through `:file_server_2` reintroduces the serialisation this module
       exists to avoid, silently.
  """

  # The oldest release this server claims to run on. Only availability is
  # checked against it, and only on the release actually running: an older OTP
  # cannot be tested from a newer one.
  @minimum_otp 26

  @posix [{:time, :posix}]

  @doc "Oldest OTP release this server is declared to support."
  @spec minimum_otp() :: pos_integer()
  def minimum_otp, do: @minimum_otp

  @doc "Like `File.lstat/1` with POSIX timestamps. Does not follow a final symlink."
  @spec lstat(binary()) :: {:ok, File.Stat.t()} | {:error, :file.posix()}
  def lstat(path) do
    case :prim_file.read_link_info(path, @posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Like `File.stat/1` with POSIX timestamps. Follows symlinks."
  @spec stat(binary()) :: {:ok, File.Stat.t()} | {:error, :file.posix()}
  def stat(path) do
    case :prim_file.read_file_info(path, @posix) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Entry names of a directory, as raw bytes, unsorted and without `.` or `..`."
  @spec list_dir(binary()) :: {:ok, [binary()]} | {:error, :file.posix()}
  def list_dir(path) do
    case :prim_file.list_dir_all(path) do
      {:ok, names} -> {:ok, Enum.map(names, &IO.iodata_to_binary/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Target of a symlink, as raw bytes."
  @spec read_link(binary()) :: {:ok, binary()} | {:error, :file.posix()}
  def read_link(path) do
    case :prim_file.read_link_all(path) do
      {:ok, target} -> {:ok, IO.iodata_to_binary(target)}
      {:error, reason} -> {:error, reason}
    end
  end

  defdelegate make_dir(path), to: :prim_file
  defdelegate del_dir(path), to: :prim_file
  defdelegate delete(path), to: :prim_file
  defdelegate rename(source, destination), to: :prim_file
end
