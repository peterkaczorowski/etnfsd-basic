defmodule Tnfs.Command do
  @moduledoc """
  Command table for TNFS (handoff section 3).

  Every command is described declaratively by a field schema. The same schema
  drives three things, which is why it is a data table and not hand written
  binary matching scattered over handlers:

    1. request decoding (`Tnfs.Protocol.decode_request/2`),
    2. response encoding/decoding (`Tnfs.Protocol.encode_payload/3`),
    3. incremental frame assembly for legacy TCP, where the command id is the
       only way to know how long a request is (handoff section 2.3).

  Field types:

    * `:u8`, `:u16`, `:u32`, `:u64` - unsigned little-endian
    * `:i32` - signed little-endian, two's complement
    * `:zstr` - NUL terminated byte string, never interpreted as UTF-8
    * `:u16_blob` - `u16` length followed by exactly that many bytes

  `:opaque` marks a command whose payload layout is not specified by the
  handoff. Such a payload is carried through undecoded and cannot be framed on
  a byte stream.
  """

  @type name ::
          :mount
          | :umount
          | :opendir
          | :readdir
          | :closedir
          | :mkdir
          | :rmdir
          | :telldir
          | :seekdir
          | :opendirx
          | :readdirx
          | :open_legacy
          | :read
          | :write
          | :close
          | :stat
          | :lseek
          | :unlink
          | :chmod
          | :rename
          | :open
          | :size
          | :free
          | :sizebytes
          | :freebytes

  @type field_type :: :u8 | :u16 | :u32 | :u64 | :i32 | :zstr | :u16_blob
  @type schema :: [{atom(), field_type()}] | :opaque | :custom

  # {id, name, request schema, success response schema}
  #
  # A response schema of `:custom` means the payload is built by the handler
  # (READDIRX) or is never a success payload (OPEN legacy).
  @commands [
    {0x00, :mount, [version: :u16, mount: :zstr, user: :zstr, password: :zstr],
     [version: :u16, retry_ms: :u16]},
    {0x01, :umount, [], []},
    {0x10, :opendir, [path: :zstr], [handle: :u8]},
    {0x11, :readdir, [handle: :u8], [name: :zstr]},
    {0x12, :closedir, [handle: :u8], []},
    {0x13, :mkdir, [path: :zstr], []},
    {0x14, :rmdir, [path: :zstr], []},
    {0x15, :telldir, [handle: :u8], [position: :u32]},
    {0x16, :seekdir, [handle: :u8, position: :u32], []},
    {0x17, :opendirx,
     [diropts: :u8, sortopts: :u8, max_results: :u16, pattern: :zstr, path: :zstr],
     [handle: :u8, matched: :u16]},
    {0x18, :readdirx, [handle: :u8, requested: :u8], :custom},
    {0x20, :open_legacy, :opaque, :custom},
    {0x21, :read, [handle: :u8, requested: :u16], [data: :u16_blob]},
    {0x22, :write, [handle: :u8, data: :u16_blob], [actual: :u16]},
    {0x23, :close, [handle: :u8], []},
    {0x24, :stat, [path: :zstr],
     [mode: :u16, uid: :u16, gid: :u16, size: :u32, atime: :u32, mtime: :u32, ctime: :u32]},
    {0x25, :lseek, [handle: :u8, whence: :u8, offset: :i32], [position: :u32]},
    {0x26, :unlink, [path: :zstr], []},
    {0x27, :chmod, [mode: :u16, path: :zstr], []},
    {0x28, :rename, [source: :zstr, destination: :zstr], []},
    {0x29, :open, [flags: :u16, mode: :u16, path: :zstr], [handle: :u8]},
    {0x30, :size, [], [kib: :u32]},
    {0x31, :free, [], [kib: :u32]},
    {0x32, :sizebytes, [], [bytes: :u64]},
    {0x33, :freebytes, [], [bytes: :u64]}
  ]

  # Commands that change the exported tree. OPEN is not here: it is rejected by
  # flag inspection, because a read-only OPEN is legitimate (handoff section 8).
  @mutating ~w(mkdir rmdir write unlink chmod rename)a

  @fixed_widths %{u8: 1, u16: 2, u32: 4, u64: 8, i32: 4}

  # The widest success payload whose size is fixed by the schema alone, computed
  # from the table so that adding a command cannot leave the configuration
  # invariant behind. Variable payloads (`:zstr`, `:u16_blob`) and the two
  # hand-built ones (`:custom`, `:opaque`) are excluded: their size is bounded by
  # `max_io` and `max_response_payload`, not by the schema. STAT is the widest at
  # 22 bytes.
  @largest_fixed_response @commands
                          |> Enum.map(fn {_id, _name, _req, resp} -> resp end)
                          |> Enum.filter(&is_list/1)
                          |> Enum.map(fn resp ->
                            Enum.reduce_while(resp, 0, fn {_field, type}, total ->
                              case @fixed_widths do
                                %{^type => width} -> {:cont, total + width}
                                _ -> {:halt, 0}
                              end
                            end)
                          end)
                          |> Enum.max()

  @doc "All commands as `{id, name, request_schema, response_schema}`."
  @spec all() :: [{0..255, name(), schema(), schema()}]
  def all, do: @commands

  @doc "All command names."
  @spec names() :: [name()]
  def names, do: Enum.map(@commands, fn {_id, name, _req, _resp} -> name end)

  @doc "Command name for a wire id, or `:error` for an unassigned id."
  @spec fetch_name(0..255) :: {:ok, name()} | :error
  for {id, name, _req, _resp} <- @commands do
    def fetch_name(unquote(id)), do: {:ok, unquote(name)}
  end

  def fetch_name(id) when is_integer(id) and id in 0..255, do: :error

  @doc "Wire id for a command name."
  @spec id(name()) :: 0..255
  for {id, name, _req, _resp} <- @commands do
    def id(unquote(name)), do: unquote(id)
  end

  @doc "Request field schema for a command."
  @spec request_schema(name()) :: schema()
  for {_id, name, req, _resp} <- @commands do
    def request_schema(unquote(name)), do: unquote(Macro.escape(req))
  end

  @doc "Success response field schema for a command."
  @spec response_schema(name()) :: schema()
  for {_id, name, _req, resp} <- @commands do
    def response_schema(unquote(name)), do: unquote(Macro.escape(resp))
  end

  @doc """
  True for commands that modify the exported filesystem and must be refused
  with EPERM in read-only mode before any path resolution happens.
  """
  @spec mutating?(name()) :: boolean()
  for {_id, name, _req, _resp} <- @commands do
    def mutating?(unquote(name)), do: unquote(name in @mutating)
  end

  @doc """
  Size in bytes of the widest success payload that the schema alone fixes.

  Used by `Tnfs.Config` to refuse a `max_response_payload` too small to carry a
  reply this server is going to produce anyway.
  """
  @spec largest_fixed_response() :: pos_integer()
  def largest_fixed_response, do: @largest_fixed_response

  @doc """
  True when a request for this command can be delimited on a byte stream.

  False only for `:open_legacy`, whose payload layout is unknown; on TCP such a
  frame must be rejected instead of guessed, otherwise the stream desynchronises
  (handoff section 14.1, ADR 5).
  """
  @spec frameable?(name()) :: boolean()
  for {_id, name, req, _resp} <- @commands do
    def frameable?(unquote(name)), do: unquote(req != :opaque)
  end
end
