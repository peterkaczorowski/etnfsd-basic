defmodule Tnfs.ServerCase do
  @moduledoc """
  Starts a complete server per test and talks to it over a real UDP socket.

  Tests that use this are `async: false` on purpose: `Tnfs.Runtime` registers
  named processes and named ETS tables, so only one tree can exist at a time.
  The gain is that everything below is exercised end to end - listener,
  admission control, dispatcher, registry, session - instead of a mock.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Tnfs.Config
  alias Tnfs.Protocol

  @loopback {127, 0, 0, 1}

  using do
    quote do
      import Tnfs.ServerCase

      alias Tnfs.Config
      alias Tnfs.Protocol
    end
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "etnfsd-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    overrides = Map.get(context, :config, [])

    # `transports: :udp_only` rather than the struct's `:both`, and stated here
    # rather than inherited, because this harness reads `Tnfs.Transport.UDP.port()`
    # below and most of the suite is about the datagram path. A case that wants
    # the stream listener asks for `transports: :both`, which is also what makes
    # those cases findable: every test that involves TCP says so in its own tags.
    defaults = [root: root, port: 0, listen_address: @loopback, transports: :udp_only]
    config = Config.build!(Keyword.merge(defaults, overrides))

    start_supervised!({Tnfs.Runtime, config})
    port = Tnfs.Transport.UDP.port()

    %{root: root, config: config, port: port, socket: client_socket()}
  end

  @doc """
  Opens an extra client socket.

  Each socket has its own source port, which is what lets a test act as
  several independent clients of the same server.
  """
  @spec client_socket() :: :gen_udp.socket()
  def client_socket do
    {:ok, socket} = :gen_udp.open(0, [:binary, {:ip, @loopback}, {:active, false}])
    ExUnit.Callbacks.on_exit(fn -> :gen_udp.close(socket) end)
    socket
  end

  @doc "Sends raw bytes from `socket` and returns the raw reply, or `:timeout`."
  @spec roundtrip(map(), binary(), keyword()) :: binary() | :timeout
  def roundtrip(context, data, opts \\ []) do
    socket = Keyword.get(opts, :socket, context.socket)
    timeout = Keyword.get(opts, :timeout, 1_000)

    :ok = :gen_udp.send(socket, @loopback, context.port, data)

    case :gen_udp.recv(socket, 0, timeout) do
      {:ok, {_address, _port, reply}} -> reply
      {:error, :timeout} -> :timeout
    end
  end

  @doc """
  Encodes a request, sends it and decodes the reply.

  Returns `{response, args}`, or `:timeout` when the server stayed silent.
  """
  @spec call(map(), 0..0xFFFF, 0..255, atom(), map(), keyword()) ::
          {Protocol.Response.t(), map()} | :timeout
  def call(context, sid, seq, command, args, opts \\ []) do
    {:ok, data} = Protocol.encode_request(sid, seq, command, args)

    case roundtrip(context, data, opts) do
      :timeout ->
        :timeout

      reply ->
        {:ok, response, decoded} = Protocol.decode_response(reply, context.config)
        {response, decoded}
    end
  end

  @doc "Performs a MOUNT and returns the allocated SID."
  @spec mount!(map(), keyword()) :: 0..0xFFFF
  def mount!(context, opts \\ []) do
    args = %{
      version: Keyword.get(opts, :version, 0x0102),
      mount: Keyword.get(opts, :mount, "/"),
      user: "",
      password: ""
    }

    {response, _args} = call(context, 0, Keyword.get(opts, :seq, 0), :mount, args, opts)

    assert response.status == :success
    assert response.sid != 0

    response.sid
  end
end
