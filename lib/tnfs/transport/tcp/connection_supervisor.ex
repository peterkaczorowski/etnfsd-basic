defmodule Tnfs.Transport.TCP.ConnectionSupervisor do
  @moduledoc """
  Supervises one process per accepted connection.

  Connections are `:temporary`: a dropped TCP connection is the client's
  problem to retry, and restarting one without its socket would be
  meaningless. `max_children` is the real admission limit for this transport,
  enforced by the supervisor itself rather than by a counter that could drift.
  """

  use DynamicSupervisor

  alias Tnfs.Transport.TCP.Connection

  @doc false
  def start_link(config), do: DynamicSupervisor.start_link(__MODULE__, config, name: __MODULE__)

  @doc "Starts the owner process of an accepted socket."
  @spec start_connection(:gen_tcp.socket(), Tnfs.Config.t()) :: DynamicSupervisor.on_start_child()
  def start_connection(socket, config) do
    DynamicSupervisor.start_child(__MODULE__, {Connection, {socket, config}})
  end

  @impl DynamicSupervisor
  def init(config) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: config.max_tcp_connections)
  end
end
