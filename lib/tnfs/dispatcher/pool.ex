defmodule Tnfs.Dispatcher.Pool do
  @moduledoc """
  Supervises the fixed set of dispatcher workers.

  The number of partitions is fixed at boot: admission control counts
  in-flight work per partition, and those counters would be meaningless if
  the pool could grow under load.
  """

  use Supervisor

  alias Tnfs.Dispatcher

  @doc false
  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @impl Supervisor
  def init(config) do
    children =
      for index <- 0..(config.dispatch_partitions - 1) do
        Supervisor.child_spec({Dispatcher, index: index, config: config}, id: {Dispatcher, index})
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
