defmodule Tnfs.Status do
  @moduledoc """
  TNFS status codes (handoff section 4).

  A status is carried as a single byte at offset 4 of every response. This
  module is the only place where the numeric values live; everything else in
  the server works with atoms.

  Note that `:eof` (0x21) and `:ebadsession` (0xff) are protocol level statuses,
  not POSIX errors. `0xff` in particular must never be produced by translating
  an unknown filesystem error, because it tells the client that its session is
  gone. See `Tnfs.Error`.
  """

  # Kept as a literal list so that both directions of the mapping and the
  # `t:t/0` type are generated from a single source of truth.
  @statuses [
    {0x00, :success},
    {0x01, :eperm},
    {0x02, :enoent},
    {0x03, :eio},
    {0x04, :enxio},
    {0x05, :e2big},
    {0x06, :ebadf},
    {0x07, :eagain},
    {0x08, :enomem},
    {0x09, :eacces},
    {0x0A, :ebusy},
    {0x0B, :eexist},
    {0x0C, :enotdir},
    {0x0D, :eisdir},
    {0x0E, :einval},
    {0x0F, :enfile},
    {0x10, :emfile},
    {0x11, :efbig},
    {0x12, :enospc},
    {0x13, :espipe},
    {0x14, :erofs},
    {0x15, :enametoolong},
    {0x16, :enosys},
    {0x17, :enotempty},
    {0x18, :eloop},
    {0x19, :enodata},
    {0x1A, :enostr},
    {0x1B, :eproto},
    {0x1C, :ebadfd},
    {0x1D, :eusers},
    {0x1E, :enobufs},
    {0x1F, :ealready},
    {0x20, :estale},
    {0x21, :eof},
    {0xFF, :ebadsession}
  ]

  @type t :: unquote(Enum.reduce(Enum.map(@statuses, &elem(&1, 1)), &{:|, [], [&1, &2]}))

  @doc "All known statuses as `{code, name}` pairs, ordered by code."
  @spec all() :: [{0..255, t()}]
  def all, do: @statuses

  @doc "Wire byte for a status name."
  @spec code(t()) :: 0..255
  for {code, name} <- @statuses do
    def code(unquote(name)), do: unquote(code)
  end

  @doc "Status name for a wire byte, or `:error` for an unassigned code."
  @spec fetch_name(0..255) :: {:ok, t()} | :error
  for {code, name} <- @statuses do
    def fetch_name(unquote(code)), do: {:ok, unquote(name)}
  end

  def fetch_name(byte) when is_integer(byte) and byte in 0..255, do: :error

  @doc "True when the status name is known to this implementation."
  @spec known?(atom()) :: boolean()
  for {_code, name} <- @statuses do
    def known?(unquote(name)), do: true
  end

  def known?(name) when is_atom(name), do: false
end
