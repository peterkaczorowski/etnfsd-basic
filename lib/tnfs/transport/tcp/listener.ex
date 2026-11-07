defmodule Tnfs.Transport.TCP.Listener do
  @moduledoc """
  Owns the listening socket and hands every accepted socket to its own process.

  The accept loop is driven by a message to itself rather than by a chained
  `handle_continue/2`, because a continuation always wins over the mailbox and
  the process would never answer anything again. Each `accept` uses a short
  timeout, which also bounds how long a shutdown has to wait. The listener
  never touches a session or the filesystem.
  """

  use GenServer

  alias Tnfs.Transport.TCP.ConnectionSupervisor

  @accept_timeout 100

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
      {:active, false},
      {:reuseaddr, true},
      {:packet, :raw},
      # How much the driver reads in one go, and so the largest `{:tcp, _, data}`
      # message a connection can be handed. Inherited by every accepted socket.
      #
      # Set because the default is not ours: `inet_drv` picks 9216 bytes, and at
      # 9216 bytes one message can carry two thousand four-byte requests, all of
      # which the connection process would answer in a single callback. One
      # datagram is the size of the largest request this server accepts, so it is
      # the size at which a read can never contain more than it has to.
      {:buffer, config.max_datagram},
      # One response must reach the client as one segment whenever the network
      # allows it, so Nagle must not hold it back (handoff section 2.3).
      {:nodelay, true},
      {:keepalive, true},
      {:backlog, config.max_tcp_connections},
      # Without this a client that pipelines requests and never reads them
      # blocks the connection process inside `:gen_tcp.send/2`. A blocked
      # process never handles its own `:check` message, so neither the frame
      # timeout nor the idle timeout can fire and the connection keeps one of
      # `max_tcp_connections` slots for as long as the peer leaves the socket
      # open. `send_timeout_close` is what makes the timeout terminal: after it
      # fires the stream is desynchronised, because an unknown prefix of the
      # response was already written.
      {:send_timeout, config.tcp_send_timeout_ms},
      {:send_timeout_close, true}
    ]

    case :gen_tcp.listen(config.port, opts) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        send(self(), :accept)
        {:ok, %{socket: socket, port: port, config: config}}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl GenServer
  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.socket, @accept_timeout) do
      {:ok, socket} ->
        hand_over(socket, state.config)

      {:error, :timeout} ->
        :ok

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        :telemetry.execute([:tnfs, :tcp, :accept_failed], %{count: 1}, %{reason: reason})
    end

    send(self(), :accept)
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state), do: :gen_tcp.close(state.socket)

  defp hand_over(socket, config) do
    case ConnectionSupervisor.start_connection(socket, config) do
      {:ok, pid} ->
        # Until the new owner is set the listener would receive the data; the
        # connection process re-arms the socket once it owns it.
        :ok = :gen_tcp.controlling_process(socket, pid)
        send(pid, :owned)

      {:error, :max_children} ->
        # Closing immediately is the honest answer: an accepted socket that
        # nobody owns would just time out on the client.
        :telemetry.execute([:tnfs, :tcp, :rejected], %{count: 1}, %{reason: :max_connections})
        :gen_tcp.close(socket)

      {:error, reason} ->
        :telemetry.execute([:tnfs, :tcp, :rejected], %{count: 1}, %{reason: reason})
        :gen_tcp.close(socket)
    end
  end
end
