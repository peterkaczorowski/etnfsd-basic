defmodule Tnfs.Protocol do
  @moduledoc """
  Pure TNFS codec: bytes in, structs out, no I/O and no process state
  (handoff section 7.1).

  Wire layout (handoff section 2):

      request   sid:u16 seq:u8 command:u8 payload...
      response  sid:u16 seq:u8 command:u8 status:u8 payload...

  All multi-byte integers are little-endian. Strings are NUL terminated byte
  strings and are never validated as UTF-8: names are opaque filesystem bytes.

  Hard rules enforced here:

    * no input can raise - `decode_request/2` is total over all binaries;
    * every field read is preceded by a length check, done by binary pattern
      matching rather than manual indexing;
    * a declared WRITE length is never trusted beyond the bytes actually
      received (`:u16_blob`);
    * a header shorter than 4 bytes is dropped, because there is nothing to
      echo back safely;
    * a datagram larger than the configured maximum is dropped without partial
      processing.

  Malformed payloads map to a single consistent status: `:einval`. `:eproto` is
  reserved for the sequence-number conflict rule of handoff section 14.1.
  """

  alias Tnfs.Command
  alias Tnfs.Config
  alias Tnfs.Status

  defmodule Header do
    @moduledoc "The four request header bytes, enough to build an error reply."
    @type t :: %__MODULE__{sid: 0..0xFFFF, seq: 0..255, command_id: 0..255}
    defstruct [:sid, :seq, :command_id]
  end

  defmodule Request do
    @moduledoc """
    A decoded request.

    `raw` keeps the exact received bytes. The retry cache compares them
    byte-for-byte, which is the fingerprint required by handoff section 14.1;
    a hash is avoided so that a collision can never mask a different request.
    """
    @type t :: %__MODULE__{
            sid: 0..0xFFFF,
            seq: 0..255,
            command_id: 0..255,
            command: Command.name(),
            args: map(),
            raw: binary()
          }
    defstruct [:sid, :seq, :command_id, :command, :args, :raw]
  end

  defmodule Response do
    @moduledoc "A response ready to be encoded."
    @type t :: %__MODULE__{
            sid: 0..0xFFFF,
            seq: 0..255,
            command_id: 0..255,
            status: Status.t(),
            payload: binary()
          }
    defstruct [:sid, :seq, :command_id, :status, payload: <<>>]
  end

  @type decode_result ::
          {:ok, Request.t()}
          | {:error, Header.t(), Status.t()}
          | {:drop, :short_header | :oversize}

  @doc """
  Decodes a complete request datagram.

  Returns `{:ok, request}`, `{:error, header, status}` when the request can be
  answered with an error, or `{:drop, reason}` when no safe answer exists.
  """
  @spec decode_request(binary(), Config.t()) :: decode_result()
  def decode_request(data, config \\ Config.get())

  def decode_request(data, _config) when is_binary(data) and byte_size(data) < 4 do
    {:drop, :short_header}
  end

  def decode_request(data, config) when is_binary(data) do
    if byte_size(data) > config.max_datagram do
      {:drop, :oversize}
    else
      <<sid::unsigned-little-16, seq, command_id, payload::binary>> = data
      header = %Header{sid: sid, seq: seq, command_id: command_id}

      case Command.fetch_name(command_id) do
        :error ->
          {:error, header, :enosys}

        {:ok, command} ->
          decode_payload(header, command, payload, data, config)
      end
    end
  end

  defp decode_payload(header, command, payload, raw, config) do
    case Command.request_schema(command) do
      :opaque ->
        {:ok, request(header, command, %{payload: payload}, raw)}

      schema ->
        case take_fields(schema, payload, %{}) do
          {:ok, args, rest} ->
            if rest != <<>> and config.strict_decode do
              {:error, header, :einval}
            else
              {:ok, request(header, command, args, raw)}
            end

          :error ->
            {:error, header, :einval}
        end
    end
  end

  defp request(header, command, args, raw) do
    %Request{
      sid: header.sid,
      seq: header.seq,
      command_id: header.command_id,
      command: command,
      args: args,
      raw: raw
    }
  end

  @doc """
  Encodes a response.

  Fails instead of truncating when the payload exceeds the protocol limit, so
  an oversized listing can never be silently cut in half.
  """
  @spec encode_response(Response.t(), Config.t()) ::
          {:ok, binary()} | {:error, :response_too_large}
  def encode_response(response, config \\ Config.get())

  def encode_response(%Response{} = response, config) do
    if byte_size(response.payload) > config.max_response_payload do
      {:error, :response_too_large}
    else
      {:ok,
       <<response.sid::unsigned-little-16, response.seq, response.command_id,
         Status.code(response.status), response.payload::binary>>}
    end
  end

  @doc """
  Decodes a response. Used by tests and by any client-side tooling; the server
  itself never calls it.
  """
  @spec decode_response(binary(), Config.t()) ::
          {:ok, Response.t(), map()} | {:error, atom()}
  def decode_response(data, config \\ Config.get())

  def decode_response(data, _config) when is_binary(data) and byte_size(data) < 5 do
    {:error, :short_response}
  end

  def decode_response(data, config) when is_binary(data) do
    <<sid::unsigned-little-16, seq, command_id, status_byte, payload::binary>> = data

    with {:ok, status} <- Status.fetch_name(status_byte),
         {:ok, command} <- Command.fetch_name(command_id),
         {:ok, args} <- decode_response_payload(command, status, payload, config) do
      response = %Response{
        sid: sid,
        seq: seq,
        command_id: command_id,
        status: status,
        payload: payload
      }

      {:ok, response, args}
    else
      :error -> {:error, :unknown_code}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_response_payload(_command, status, _payload, _config) when status != :success do
    {:ok, %{}}
  end

  defp decode_response_payload(command, :success, payload, config) do
    case Command.response_schema(command) do
      :custom ->
        {:ok, %{payload: payload}}

      schema ->
        case take_fields(schema, payload, %{}) do
          {:ok, args, <<>>} -> {:ok, args}
          {:ok, args, _rest} when not config.strict_decode -> {:ok, args}
          {:ok, _args, _rest} -> {:error, :trailing_bytes}
          :error -> {:error, :malformed_payload}
        end
    end
  end

  @doc """
  Builds a success payload for a command from a map of field values.

  Returns `{:error, {:out_of_range, field}}` rather than raising or wrapping,
  so that overflow policy stays an explicit decision of the caller
  (handoff section 3.4).
  """
  @spec encode_payload(Command.name(), map()) ::
          {:ok, binary()} | {:error, {:out_of_range, atom()} | :unsupported}
  def encode_payload(command, args) do
    case Command.response_schema(command) do
      :custom -> {:error, :unsupported}
      schema -> put_fields(schema, args, [])
    end
  end

  @doc """
  Encodes a request from field values.

  The server never sends requests; this exists for tests, benchmarks and any
  client-side tooling, and it keeps the golden vectors honest by exercising the
  same schema table in both directions.
  """
  @spec encode_request(0..0xFFFF, 0..255, Command.name(), map()) ::
          {:ok, binary()} | {:error, {:out_of_range, atom()}}
  def encode_request(sid, seq, command, args)
      when sid in 0..0xFFFF and seq in 0..255 do
    header = <<sid::unsigned-little-16, seq, Command.id(command)>>

    case Command.request_schema(command) do
      :opaque ->
        {:ok, header <> Map.get(args, :payload, <<>>)}

      schema ->
        with {:ok, payload} <- put_fields(schema, args, []) do
          {:ok, header <> payload}
        end
    end
  end

  @doc """
  Length of the first complete request in `buffer`, for stream transports.

  A byte stream gives no framing, and most commands do not carry a total
  length, so the command id selects the schema that tells us where the request
  ends (handoff section 2.3).

  Returns `:incomplete` while more bytes are needed, `{:error, status}` when
  the frame can never become valid, and `{:error, :unframeable}` for a command
  whose layout is unknown - such a connection must be closed rather than
  guessed at.
  """
  @spec frame_length(binary(), Config.t()) ::
          {:ok, pos_integer()} | :incomplete | {:error, Status.t() | :unframeable}
  def frame_length(buffer, config \\ Config.get())

  def frame_length(buffer, _config) when is_binary(buffer) and byte_size(buffer) < 4 do
    :incomplete
  end

  def frame_length(buffer, config) when is_binary(buffer) do
    <<_sid::unsigned-little-16, _seq, command_id, payload::binary>> = buffer

    result =
      case Command.fetch_name(command_id) do
        :error ->
          # Unknown id: the payload length is unknowable, so the stream cannot
          # be resynchronised after it.
          {:error, :enosys}

        {:ok, command} ->
          case Command.request_schema(command) do
            :opaque -> {:error, :unframeable}
            schema -> scan_fields(schema, payload, 0)
          end
      end

    case result do
      {:ok, used} when 4 + used > config.max_datagram -> {:error, :e2big}
      {:ok, used} -> {:ok, 4 + used}
      :incomplete when byte_size(buffer) >= config.max_datagram -> {:error, :e2big}
      other -> other
    end
  end

  # --- field codec -----------------------------------------------------------
  #
  # take_fields/3  decode, exact
  # scan_fields/3  measure only, tolerates truncation as :incomplete
  # put_fields/3   encode with range checking

  defp take_fields([], rest, acc), do: {:ok, acc, rest}

  defp take_fields([{name, type} | tail], bin, acc) do
    case take(type, bin) do
      {:ok, value, rest} -> take_fields(tail, rest, Map.put(acc, name, value))
      :error -> :error
    end
  end

  defp take(:u8, <<value, rest::binary>>), do: {:ok, value, rest}
  defp take(:u16, <<value::unsigned-little-16, rest::binary>>), do: {:ok, value, rest}
  defp take(:u32, <<value::unsigned-little-32, rest::binary>>), do: {:ok, value, rest}
  defp take(:u64, <<value::unsigned-little-64, rest::binary>>), do: {:ok, value, rest}
  defp take(:i32, <<value::signed-little-32, rest::binary>>), do: {:ok, value, rest}

  defp take(:u16_blob, <<len::unsigned-little-16, data::binary-size(len), rest::binary>>) do
    {:ok, data, rest}
  end

  defp take(:zstr, bin) when is_binary(bin) do
    case :binary.split(bin, <<0>>) do
      [value, rest] -> {:ok, value, rest}
      [_no_terminator] -> :error
    end
  end

  defp take(_type, _bin), do: :error

  defp scan_fields([], _bin, used), do: {:ok, used}

  defp scan_fields([{_name, type} | tail], bin, used) do
    case scan(type, bin) do
      {:ok, size, rest} -> scan_fields(tail, rest, used + size)
      other -> other
    end
  end

  defp scan(:zstr, bin) do
    case :binary.match(bin, <<0>>) do
      {pos, 1} ->
        size = pos + 1
        <<_taken::binary-size(^size), rest::binary>> = bin
        {:ok, size, rest}

      :nomatch ->
        :incomplete
    end
  end

  defp scan(:u16_blob, <<len::unsigned-little-16, rest::binary>>) do
    if byte_size(rest) >= len do
      <<_data::binary-size(^len), tail::binary>> = rest
      {:ok, 2 + len, tail}
    else
      :incomplete
    end
  end

  defp scan(:u16_blob, _bin), do: :incomplete

  defp scan(type, bin) do
    size = fixed_size(type)

    if byte_size(bin) >= size do
      <<_taken::binary-size(^size), rest::binary>> = bin
      {:ok, size, rest}
    else
      :incomplete
    end
  end

  defp fixed_size(:u8), do: 1
  defp fixed_size(:u16), do: 2
  defp fixed_size(:u32), do: 4
  defp fixed_size(:u64), do: 8
  defp fixed_size(:i32), do: 4

  defp put_fields([], _args, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp put_fields([{name, type} | tail], args, acc) do
    case put(type, Map.fetch!(args, name)) do
      {:ok, bin} -> put_fields(tail, args, [bin | acc])
      :error -> {:error, {:out_of_range, name}}
    end
  end

  defp put(:u8, v) when is_integer(v) and v in 0..0xFF, do: {:ok, <<v>>}
  defp put(:u16, v) when is_integer(v) and v in 0..0xFFFF, do: {:ok, <<v::unsigned-little-16>>}

  defp put(:u32, v) when is_integer(v) and v in 0..0xFFFFFFFF do
    {:ok, <<v::unsigned-little-32>>}
  end

  defp put(:u64, v) when is_integer(v) and v in 0..0xFFFFFFFFFFFFFFFF do
    {:ok, <<v::unsigned-little-64>>}
  end

  defp put(:i32, v) when is_integer(v) and v in -0x80000000..0x7FFFFFFF do
    {:ok, <<v::signed-little-32>>}
  end

  defp put(:u16_blob, v) when is_binary(v) and byte_size(v) <= 0xFFFF do
    {:ok, <<byte_size(v)::unsigned-little-16, v::binary>>}
  end

  defp put(:zstr, v) when is_binary(v) do
    # An embedded NUL would silently truncate the string for the client.
    if :binary.match(v, <<0>>) == :nomatch, do: {:ok, <<v::binary, 0>>}, else: :error
  end

  defp put(_type, _value), do: :error
end
