defmodule Tnfs.Error do
  @moduledoc """
  Total translation from Erlang/POSIX error atoms to TNFS statuses
  (handoff section 4).

  Rules that must not be broken:

    * the function is total - any term maps to something;
    * an unrecognised error maps to `:eio`, never to `:ebadsession` (0xff),
      because that byte means "your session is gone" to the client;
    * `:ebadsession` and `:eof` are produced by protocol logic only.
  """

  # Errors whose TNFS status has the same name. Listed explicitly rather than
  # derived, so that adding a status to Tnfs.Status never silently widens this
  # translation.
  @identity ~w(
    eperm enoent eio enxio e2big ebadf eagain enomem eacces ebusy eexist
    enotdir eisdir einval enfile emfile efbig enospc espipe erofs
    enametoolong enosys enotempty eloop enodata enostr eproto ealready estale
  )a

  # Errors that need an explicit decision. Everything not listed here and not
  # in @identity falls through to :eio.
  @translated %{
    # Quota exhaustion is indistinguishable from a full disk for the client.
    edquot: :enospc,
    # No such device / not a block device: closest protocol status is ENXIO.
    enodev: :enxio,
    enotblk: :enxio,
    # Bad address / bad argument from the driver level: caller sent nonsense.
    efault: :einval,
    badarg: :einval,
    # Cross-device rename cannot be satisfied as an atomic rename.
    exdev: :einval,
    # Interrupted syscall is transient; the client may retry.
    eintr: :eagain,
    # Unsupported operation on this filesystem.
    enotsup: :enosys,
    eopnotsupp: :enosys,
    # Out of system-wide resources.
    system_limit: :enfile,
    # Value too large for the defined data type.
    eoverflow: :efbig,
    # Broken pipe / dead port / closed file: an I/O failure from our side.
    epipe: :eio,
    esrch: :eio,
    terminated: :eio,
    closed: :eio
  }

  @doc """
  Translates a filesystem or runtime error into a TNFS status name.

  Unknown terms map to `:eio` and are reported through telemetry so that a
  missing translation shows up as a metric instead of a silent wrong status.
  """
  @spec to_status(term()) :: Tnfs.Status.t()
  for name <- @identity do
    def to_status(unquote(name)), do: unquote(name)
  end

  for {from, to} <- @translated do
    def to_status(unquote(from)), do: unquote(to)
  end

  def to_status(other) do
    :telemetry.execute([:tnfs, :error, :untranslated], %{count: 1}, %{reason: other})
    :eio
  end

  @doc """
  Normalises the result of a filesystem call into `{:ok, value}` or
  `{:error, status}`.
  """
  @spec normalize(term()) :: {:ok, term()} | {:error, Tnfs.Status.t()}
  def normalize(:ok), do: {:ok, nil}
  def normalize({:ok, value}), do: {:ok, value}
  def normalize({:error, reason}), do: {:error, to_status(reason)}
end
