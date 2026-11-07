defmodule Tnfs.Reply do
  @moduledoc """
  Where a session should send its answer.

  A session must be able to answer without the process that accepted the
  request waiting for it, otherwise one slow command blocks every other session
  sharing that worker. The worker therefore hands the session a sink describing
  how to deliver the response, and moves on.

  `:sync` means the caller is blocking on a `GenServer.call` and will send the
  bytes itself; that is the TCP path, where the connection process owns the
  socket and is dedicated to one client anyway.
  """

  @type t :: :sync | {:udp, :gen_udp.socket(), :inet.ip_address(), :inet.port_number()}

  @doc "Delivers one encoded response. Never raises: a dead socket is not our problem."
  @spec send(t(), binary()) :: :ok
  def send({:udp, socket, address, port}, data) do
    _ = :gen_udp.send(socket, address, port, data)
    :ok
  end
end
