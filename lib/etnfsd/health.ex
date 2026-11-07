defmodule Etnfsd.Health do
  @moduledoc "Checks whether the configured TNFS transports are serving."

  alias Tnfs.Config
  @udp_processes [Tnfs.Transport.UDP]
  @tcp_processes [
    Tnfs.Transport.TCP,
    Tnfs.Transport.TCP.ConnectionSupervisor,
    Tnfs.Transport.TCP.Listener
  ]

  @spec check(timeout()) :: :ok | {:error, term()}
  def check(timeout \\ 2_000) do
    with :ok <- transport(:udp, Config.udp?(Config.get()), timeout),
         :ok <- transport(:tcp, Config.tcp?(Config.get()), timeout),
         do: :ok
  end

  @spec check!(timeout()) :: :ok
  def check!(timeout \\ 2_000) do
    case check(timeout) do
      :ok -> :ok
      {:error, reason} -> raise "etnfsd is unhealthy: #{inspect(reason)}"
    end
  end

  def transports, do: Config.get().transports

  defp transport(:udp, true, timeout), do: serving(@udp_processes, Tnfs.Transport.UDP, timeout)
  defp transport(:udp, false, _timeout), do: absent(@udp_processes)
  defp transport(:tcp, true, timeout), do: serving(@tcp_processes, Tnfs.Transport.TCP.Listener, timeout)
  defp transport(:tcp, false, _timeout), do: absent(@tcp_processes)

  defp serving(names, listener, timeout) do
    with :ok <- alive(names), do: bound(listener, timeout)
  end

  defp alive(names) do
    case Enum.find(names, &is_nil(Process.whereis(&1))) do
      nil -> :ok
      missing -> {:error, {:listener_missing, missing}}
    end
  end

  defp absent(names) do
    case Enum.find(names, &(not is_nil(Process.whereis(&1)))) do
      nil -> :ok
      present -> {:error, {:disabled_listener_running, present}}
    end
  end

  defp bound(listener, timeout) do
    case GenServer.call(listener, :port, timeout) do
      port when is_integer(port) and port > 0 -> :ok
      other -> {:error, {:not_bound, listener, other}}
    end
  catch
    :exit, reason -> {:error, {:unresponsive, listener, reason}}
  end
end
