defmodule Tnfs.Dispatcher do
  @moduledoc """
  Bounded worker pool between the UDP listener and the sessions.

  The listener must never block on a session or on a disk, and the server must
  never spawn one unbounded task per datagram (handoff section 7.4). Work is
  therefore handed to a fixed number of workers, partitioned by SID so that all
  requests of one session keep their order even before they reach the session
  process.

  A worker never waits for a session. It looks the session up, hands the
  request over and takes the next datagram; the session answers the client
  directly. That is what makes two sessions sharing a worker independent -
  without it, one 20 000 entry directory listing would stall every other
  session hashed to the same partition.

  Admission is checked twice: by the listener, against the partition's
  in-flight count, before the message is sent; and here, against the target
  session's backlog. Both answer EAGAIN rather than growing a mailbox.
  """

  use GenServer

  alias Tnfs.Limits
  alias Tnfs.Peer
  alias Tnfs.Reply
  alias Tnfs.Router

  @doc false
  def start_link(opts) do
    index = Keyword.fetch!(opts, :index)
    GenServer.start_link(__MODULE__, opts, name: name(index))
  end

  @doc "Registered name of the worker owning a partition."
  @spec name(non_neg_integer()) :: atom()
  def name(index), do: Module.concat(__MODULE__, "P#{index}")

  @doc """
  Picks the partition for a datagram.

  Requests of one session must land on the same worker; MOUNT has no session
  yet, so it is spread by peer address instead.
  """
  @spec partition(binary(), :inet.ip_address(), pos_integer()) :: non_neg_integer()
  def partition(<<sid::unsigned-little-16, _rest::binary>>, address, partitions) do
    key = if sid == 0, do: address, else: sid
    :erlang.phash2(key, partitions)
  end

  def partition(_data, address, partitions), do: :erlang.phash2(address, partitions)

  @impl GenServer
  def init(opts) do
    {:ok, %{index: Keyword.fetch!(opts, :index), config: Keyword.fetch!(opts, :config)}}
  end

  @impl GenServer
  def handle_info({:udp_request, socket, address, port, data}, state) do
    sink = {:udp, socket, address, port}

    try do
      case Router.route(data, Peer.udp(address, port), state.config, sink) do
        {:reply, response} -> Reply.send(sink, response)
        # A session owns the answer now; this worker is free.
        :async -> :ok
        :drop -> :ok
      end
    after
      Limits.release(state.index)
    end

    {:noreply, state}
  end
end
