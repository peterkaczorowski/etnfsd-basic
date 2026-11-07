defmodule Tnfs.ProtocolFuzzTest do
  @moduledoc """
  Randomised tests for the decoder (handoff section 13.1).

  No external property-testing dependency: the generators are driven by a
  seeded `:rand` state, so a failure is reproducible from the printed seed.
  """

  use ExUnit.Case, async: true

  alias Tnfs.Command
  alias Tnfs.Config
  alias Tnfs.Protocol
  alias Tnfs.Protocol.Header
  alias Tnfs.Protocol.Request
  alias Tnfs.Protocol.Response

  @strict %Config{}
  @lax %Config{strict_decode: false}
  @seeds [{:exsss, {1, 2, 3}}, {:exsss, {17, 42, 4711}}, {:exsss, {2026, 9, 12}}]
  @iterations 3_000

  describe "no input can raise" do
    test "uniformly random binaries of 0..1024 bytes" do
      each_seed(fn ->
        for _ <- 1..@iterations do
          data = :rand.bytes(:rand.uniform(1025) - 1)
          assert_decodes_safely(data, @strict)
          assert_decodes_safely(data, @lax)
        end
      end)
    end

    test "random binaries that start with a valid header" do
      # Uniform noise almost never hits a real command id, so bias the id.
      ids = Enum.map(Command.all(), &elem(&1, 0)) ++ [0x99, 0xFF]

      each_seed(fn ->
        for _ <- 1..@iterations do
          id = Enum.random(ids)
          payload = :rand.bytes(:rand.uniform(64) - 1)
          data = <<:rand.uniform(0x10000) - 1::unsigned-little-16, :rand.uniform(256) - 1, id>>

          assert_decodes_safely(data <> payload, @strict)
        end
      end)
    end

    test "valid requests mutated by one byte" do
      each_seed(fn ->
        for _ <- 1..@iterations do
          {_command, valid} = random_request()
          assert_decodes_safely(mutate(valid), @strict)
        end
      end)
    end

    test "frame_length never raises and never reports a length beyond the buffer" do
      each_seed(fn ->
        for _ <- 1..@iterations do
          data = :rand.bytes(:rand.uniform(600) - 1)

          case Protocol.frame_length(data, @strict) do
            {:ok, length} ->
              assert length <= byte_size(data)
              assert length <= @strict.max_datagram

            :incomplete ->
              assert byte_size(data) < @strict.max_datagram

            {:error, reason} ->
              assert reason in [:enosys, :e2big, :unframeable]
          end
        end
      end)
    end
  end

  describe "round-trip properties" do
    test "decode(encode(request)) == request for random legal field values" do
      each_seed(fn ->
        for _ <- 1..@iterations do
          command = Enum.random(Command.names() -- [:open_legacy])
          args = random_args(Command.request_schema(command))
          sid = :rand.uniform(0x10000) - 1
          seq = :rand.uniform(256) - 1

          assert {:ok, encoded} = Protocol.encode_request(sid, seq, command, args)

          config = %Config{max_datagram: max(byte_size(encoded), @strict.max_datagram)}
          assert {:ok, %Request{} = request} = Protocol.decode_request(encoded, config)

          assert request.sid == sid
          assert request.seq == seq
          assert request.command == command
          assert request.args == args
        end
      end)
    end

    test "decode(encode(response)) == response for random legal field values" do
      commands =
        Enum.reject(Command.names(), &(Command.response_schema(&1) == :custom))

      each_seed(fn ->
        for _ <- 1..@iterations do
          command = Enum.random(commands)
          args = random_args(Command.response_schema(command), 400)

          assert {:ok, payload} = Protocol.encode_payload(command, args)

          response = %Response{
            sid: :rand.uniform(0x10000) - 1,
            seq: :rand.uniform(256) - 1,
            command_id: Command.id(command),
            status: :success,
            payload: payload
          }

          assert {:ok, encoded} = Protocol.encode_response(response, @strict)
          assert byte_size(encoded) <= @strict.max_datagram
          assert {:ok, ^response, ^args} = Protocol.decode_response(encoded, @strict)
        end
      end)
    end

    test "an accepted request always yields a response within the protocol limit" do
      each_seed(fn ->
        for _ <- 1..@iterations do
          data = :rand.bytes(:rand.uniform(600) - 1)

          header =
            case Protocol.decode_request(data, @strict) do
              {:ok, request} ->
                %Header{sid: request.sid, seq: request.seq, command_id: request.command_id}

              {:error, header, _status} ->
                header

              {:drop, _reason} ->
                nil
            end

          if header do
            response = %Response{
              sid: header.sid,
              seq: header.seq,
              command_id: header.command_id,
              status: :einval
            }

            assert {:ok, encoded} = Protocol.encode_response(response, @strict)
            assert byte_size(encoded) <= @strict.max_datagram
          end
        end
      end)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp each_seed(fun) do
    for seed <- @seeds do
      :rand.seed(elem(seed, 0), elem(seed, 1))
      fun.()
    end
  end

  defp assert_decodes_safely(data, config) do
    case Protocol.decode_request(data, config) do
      {:ok, %Request{} = request} ->
        assert request.raw == data
        assert {:ok, _name} = Command.fetch_name(request.command_id)
        assert is_map(request.args)

      {:error, %Header{} = header, status} ->
        assert header.sid in 0..0xFFFF
        assert header.seq in 0..255
        assert status in [:einval, :enosys]

      {:drop, reason} ->
        assert reason in [:short_header, :oversize]
    end
  end

  defp random_request do
    command = Enum.random(Command.names() -- [:open_legacy])
    args = random_args(Command.request_schema(command))
    {:ok, encoded} = Protocol.encode_request(0x1234, 0x2A, command, args)
    {command, encoded}
  end

  defp random_args(schema, blob_limit \\ 64)

  defp random_args(schema, blob_limit) when is_list(schema) do
    Map.new(schema, fn {name, type} -> {name, random_value(type, blob_limit)} end)
  end

  defp random_value(:u8, _limit), do: :rand.uniform(256) - 1
  defp random_value(:u16, _limit), do: :rand.uniform(0x10000) - 1
  defp random_value(:u32, _limit), do: :rand.uniform(0x100000000) - 1
  defp random_value(:u64, _limit), do: :rand.uniform(0x10000000000000000) - 1
  defp random_value(:i32, _limit), do: :rand.uniform(0x100000000) - 1 - 0x80000000
  defp random_value(:u16_blob, limit), do: :rand.bytes(:rand.uniform(limit + 1) - 1)

  defp random_value(:zstr, limit) do
    # Opaque bytes, never UTF-8 validated, but a NUL would terminate the field.
    limit
    |> :rand.uniform()
    |> then(&:rand.bytes(&1 - 1))
    |> :binary.replace(<<0>>, <<0xFF>>, [:global])
  end

  defp mutate(binary) when byte_size(binary) > 0 do
    position = :rand.uniform(byte_size(binary)) - 1
    <<prefix::binary-size(^position), _byte, suffix::binary>> = binary
    <<prefix::binary, :rand.uniform(256) - 1, suffix::binary>>
  end

  defp mutate(binary), do: binary
end
