defmodule Tnfs.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for session processes.

  Sessions are `:temporary` children: a session that dies is gone for good and
  the client remounts (handoff section 7.3). `:one_for_one` keeps a crash from
  touching any other session.
  """

  use DynamicSupervisor

  @doc false
  def start_link(_opts \\ []), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Starts a session process."
  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts), do: DynamicSupervisor.start_child(__MODULE__, {Tnfs.Session, opts})

  @impl DynamicSupervisor
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
end
