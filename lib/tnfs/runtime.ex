defmodule Tnfs.Runtime do
  @moduledoc """
  Supervision tree of one running server.

  Kept separate from `Tnfs.Application` so that a test can start a complete,
  self-contained server with its own configuration.

  The strategy is `:rest_for_one` because the children are layered: the
  tables owned by `Tnfs.Limits` and `Tnfs.SessionRegistry` die with their
  owner, so everything downstream of a restarted owner must restart too. The
  listener is started last and therefore stopped first, which means no new
  datagram can arrive while the layer below it is being rebuilt.

  Which listeners exist is `config.transports` and nothing else. A transport
  the mode excludes is not started, not registered and not supervised - it is
  absent, not present and refusing. The distinction matters to the health
  check, which asks whether the process is there rather than whether it would
  answer, and it matters to anyone reading `:observer`: a listener that
  rejects every packet looks exactly like one that is broken.
  """

  use Supervisor

  alias Tnfs.Config

  @doc false
  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @impl Supervisor
  def init(%Config{} = config) do
    Config.put(config)

    children =
      [
        {Tnfs.Limits, config},
        {Tnfs.SessionRegistry, config},
        Tnfs.SessionSupervisor,
        {Tnfs.Dispatcher.Pool, config}
      ] ++
        if(Config.udp?(config), do: [{Tnfs.Transport.UDP, config}], else: []) ++
        if Config.tcp?(config), do: [{Tnfs.Transport.TCP, config}], else: []

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
