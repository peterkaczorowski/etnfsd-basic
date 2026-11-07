defmodule Tnfs.Transport.UDP do
  @moduledoc """
  UDP listener.

  This process does one thing only: take a datagram off the socket and hand
  it to a dispatcher worker. It performs no filesystem I/O and never calls a
  session (handoff section 7.4), because a single slow operation here would
  stall every other client sharing the socket.

  The socket is opened in `{:active, N}` mode. The kernel delivers at most N
  datagrams before the socket goes passive, which bounds this process'
  mailbox even when the network floods it; `:udp_passive` re-arms it.
  """

  use GenServer

  alias Tnfs.Dispatcher
  alias Tnfs.Limits
  alias Tnfs.Peer
  alias Tnfs.Router

  # Datagrams delivered before the socket must be re-armed.
  @active 64

  @doc false
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @doc "Port the listener actually bound to. Needed when tests bind port 0."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl GenServer
  def init(config) do
    opts = [
      :binary,
      {:ip, config.listen_address},
      {:active, @active},
      {:reuseaddr, true}
    ]

    case :gen_udp.open(config.port, opts) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)

        {:ok, %{socket: socket, port: port, config: config}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl GenServer
  def handle_info({:udp, socket, address, port, data}, state) do
    config = state.config
    index = Dispatcher.partition(data, address, config.dispatch_partitions)

    case Limits.acquire(index, config.max_inflight_per_partition) do
      :ok ->
        send(Dispatcher.name(index), {:udp_request, socket, address, port, data})

      {:error, :overload} ->
        # The partition is saturated. Answering EAGAIN from the listener is
        # cheap and honest; queueing the datagram would only move the
        # overload into a mailbox nobody bounds.
        :telemetry.execute([:tnfs, :dispatch, :overloaded], %{count: 1}, %{
          partition: index,
          address: address
        })

        reject(socket, address, port, data, config)
    end

    {:noreply, state}
  end

  def handle_info({:udp_passive, socket}, state) do
    :ok = :inet.setopts(socket, active: @active)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state), do: :gen_udp.close(state.socket)

  # Whether an EAGAIN is owed or the source has spent its budget for
  # sessionless traffic is the router's decision, not the listener's: this is
  # the only way both transports stay on one policy.
  defp reject(socket, address, port, data, config) do
    case Router.overloaded(data, Peer.udp(address, port), config) do
      {:reply, response} -> :gen_udp.send(socket, address, port, response)
      :drop -> :ok
    end
  end
end
