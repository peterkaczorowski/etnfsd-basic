defmodule Tnfs.Transport.TCP.Connection do
  @moduledoc """
  Owns one accepted socket and reassembles requests from the byte stream.

  A TCP segment boundary has nothing to do with a request boundary, so bytes
  are buffered and a frame is cut only when `Tnfs.Protocol.frame_length/2`
  says the whole request has arrived. That function derives the length from
  the command schema, which is the only reliable way to frame a protocol whose
  requests do not carry their own length (handoff section 2.3).

  Four rules keep a misbehaving peer from costing anything: the buffer may never
  hold more than `max_tcp_buffer` bytes, one callback may answer at most
  `max_tcp_frames_per_batch` requests, a frame that stays unfinished for longer
  than the frame timeout ends the connection, and a response that cannot be
  handed to the kernel within the send timeout ends it too. The last one is not
  about slow networks. A client that pipelines requests and never reads them
  fills both socket buffers, and a process blocked in `:gen_tcp.send/2` never
  reaches the `:check` message that the other two timeouts are made of - so
  without a send timeout it would hold a connection slot for as long as the peer
  chose to.

  ## Why the byte bound and the frame bound are two different rules

  A TCP read is not a request. `Tnfs.Protocol.frame_length/2` already refuses a
  *partial* frame longer than one datagram, which is the byte bound for a client
  that dribbles. It says nothing about a read that is entirely made of complete
  frames: at the driver's default read size of 9216 bytes that is up to two
  thousand four-byte requests, and answering all of them is one callback during
  which this process looks at nothing else - not its own frame timeout, not its
  idle timeout, not the shutdown of the node. Bounding the bytes therefore does
  not bound the work, and both have to be said.

  Pipelining beyond the batch is throttled rather than refused. The socket is
  left passive until the buffer drains and the continuation is sent to this
  process as a message, so it arrives *behind* whatever else is waiting: every
  request is still answered, in order and exactly once, but between batches the
  timeouts run and the scheduler is free. The bytes that are not being looked at
  yet stay in the kernel's receive buffer, which is the operating system's
  memory and already bounded by `recbuf` - the point of the exercise is that
  they are not in this process.

  The byte check is deliberately made before the concatenation that would copy
  the buffer, and it does not trust the socket to have honoured the `buffer`
  option the listener sets. An invariant that holds only because a driver option
  was accepted is the driver's invariant.

  When a frame cannot be delimited at all - an unknown command, or the legacy
  OPEN whose payload has no schema - the connection is answered once and then
  closed. Continuing would mean guessing where the next request starts, and a
  desynchronised stream is worse than a reconnect.

  There is deliberately no rate limit here. Requests arriving on an established
  connection are the traffic of a session that already mounted, and metering
  them capped every TCP client at the handshake rate; `Tnfs.Router` charges the
  sessionless requests, once, for both transports.
  """

  use GenServer, restart: :temporary

  alias Tnfs.Peer
  alias Tnfs.Protocol
  alias Tnfs.Router
  alias Tnfs.Status

  @doc false
  def start_link({socket, config}), do: GenServer.start_link(__MODULE__, {socket, config})

  @impl GenServer
  def init({socket, config}) do
    state = %{
      socket: socket,
      config: config,
      address: nil,
      # Identifies this connection for MOUNT deduplication. A reference, not
      # the source port, because ports are reused and the next connection from
      # the same port must not be handed the previous one's session.
      connection: make_ref(),
      buffer: <<>>,
      # Monotonic time of the last byte received, and of the first byte of the
      # frame currently being assembled.
      last_contact: now(),
      frame_started: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:owned, state) do
    case :inet.peername(state.socket) do
      {:ok, {address, _port}} ->
        schedule_check(state.config)
        :ok = :inet.setopts(state.socket, active: :once)
        {:noreply, %{state | address: address}}

      {:error, _reason} ->
        {:stop, :normal, state}
    end
  end

  def handle_info({:tcp, _socket, data}, state) do
    held = byte_size(state.buffer) + byte_size(data)

    # Before the concatenation, not after: `state.buffer <> data` is a copy, and
    # a check that happens once the copy exists has already paid for it.
    if held > state.config.max_tcp_buffer do
      :telemetry.execute([:tnfs, :tcp, :oversize], %{bytes: held}, %{})
      {:stop, :normal, state}
    else
      batch(%{
        state
        | buffer: state.buffer <> data,
          last_contact: now(),
          frame_started: state.frame_started || now()
      })
    end
  end

  # The continuation of a batch that hit its budget. It is an ordinary message
  # rather than a `handle_continue/2` on purpose: a continuation runs before the
  # mailbox, which is precisely the monopoly this is here to break.
  def handle_info(:consume, state), do: batch(state)

  def handle_info({:tcp_closed, _socket}, state), do: {:stop, :normal, state}

  def handle_info({:tcp_error, _socket, reason}, state) do
    :telemetry.execute([:tnfs, :tcp, :error], %{count: 1}, %{reason: reason})
    {:stop, :normal, state}
  end

  def handle_info(:check, state) do
    config = state.config
    idle = now() - state.last_contact
    assembling = state.frame_started && now() - state.frame_started

    cond do
      idle >= config.tcp_connection_timeout_ms ->
        :telemetry.execute([:tnfs, :tcp, :timeout], %{idle_ms: idle}, %{reason: :idle})
        {:stop, :normal, state}

      assembling && assembling >= config.tcp_frame_timeout_ms ->
        :telemetry.execute([:tnfs, :tcp, :timeout], %{idle_ms: assembling}, %{reason: :frame})
        {:stop, :normal, state}

      true ->
        schedule_check(config)
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state), do: :gen_tcp.close(state.socket)

  # One batch: at most `max_tcp_frames_per_batch` frames, then either the socket
  # is re-armed because there is nothing left to cut, or the rest of the buffer
  # is handed to the back of the mailbox.
  defp batch(state) do
    budget = state.config.max_tcp_frames_per_batch

    case consume(state, budget) do
      {:ok, state, left} ->
        answered(budget - left)
        :ok = :inet.setopts(state.socket, active: :once)
        {:noreply, state}

      # Deliberately not re-armed. Nothing more is taken from the socket until
      # what is already here has been answered, so the amount this process holds
      # cannot grow while it is behind.
      {:yield, state, left} ->
        answered(budget - left)
        send(self(), :consume)
        {:noreply, state}

      {:close, state, left} ->
        answered(budget - left)
        {:stop, :normal, state}
    end
  end

  # One event per batch rather than one per request, because it is the batch
  # that is bounded and so the batch that is worth being able to watch. At the
  # default budget that is one `:telemetry.execute/3` per eight requests, each
  # of which has already touched the filesystem.
  defp answered(0), do: :ok
  defp answered(frames), do: :telemetry.execute([:tnfs, :tcp, :batch], %{frames: frames}, %{})

  # Cuts complete frames out of the buffer, answering each before looking at the
  # next, until the buffer holds no whole frame or the budget runs out. Carries
  # what is left of the budget back out, so the caller can say how much it did.
  defp consume(state, 0) do
    if state.buffer == <<>>, do: {:ok, state, 0}, else: {:yield, state, 0}
  end

  defp consume(state, budget) do
    case Protocol.frame_length(state.buffer, state.config) do
      {:ok, length} ->
        <<frame::binary-size(^length), rest::binary>> = state.buffer

        case route(frame, state) do
          :ok ->
            consume(
              %{state | buffer: rest, frame_started: if(rest == <<>>, do: nil, else: now())},
              budget - 1
            )

          :closed ->
            {:close, state, budget - 1}
        end

      # A partial frame, and one that is already too long to become a legal
      # request is not `:incomplete` but `:e2big` - `frame_length/2` refuses it
      # at `max_datagram`. So there is nothing left to check here.
      :incomplete ->
        {:ok, state, budget}

      {:error, reason} ->
        undelimitable(reason, state, budget)
    end
  end

  defp route(frame, state) do
    peer = Peer.tcp(state.address, state.connection)

    case Router.route(frame, peer, state.config) do
      {:reply, response} ->
        send_response(response, state)

      # The router has already decided this request earns no answer. Unlike UDP
      # there is a connection to punish, so a peer that spends its budget for
      # sessionless traffic loses it instead of being ignored forever.
      :drop ->
        :closed
    end
  end

  # The whole response goes out in one call, never split by the server, because
  # the legacy client may treat the first fragment it sees as the whole answer.
  defp send_response(response, state) do
    case :gen_tcp.send(state.socket, response) do
      :ok ->
        :ok

      # `send_timeout` on the listening socket is what bounds this call. A peer
      # that keeps sending while never reading fills both socket buffers, and
      # without the option this process would wait here for as long as the peer
      # cared to, holding a connection slot and never reaching the `:check`
      # message that is supposed to time it out.
      {:error, :timeout} ->
        :telemetry.execute([:tnfs, :tcp, :timeout], %{idle_ms: 0}, %{reason: :send})
        :closed

      {:error, _reason} ->
        :closed
    end
  end

  defp undelimitable(reason, state, budget) do
    <<sid::unsigned-little-16, seq, command_id, _rest::binary>> = state.buffer

    status =
      case reason do
        :enosys -> :enosys
        :unframeable -> :enosys
        :e2big -> :e2big
      end

    :telemetry.execute([:tnfs, :tcp, :undelimitable], %{count: 1}, %{
      reason: reason,
      command_id: command_id
    })

    _ =
      :gen_tcp.send(
        state.socket,
        <<sid::unsigned-little-16, seq, command_id, Status.code(status)>>
      )

    {:close, state, budget}
  end

  defp schedule_check(config) do
    interval = min(config.tcp_frame_timeout_ms, config.tcp_connection_timeout_ms)
    Process.send_after(self(), :check, max(div(interval, 4), 50))
  end

  defp now, do: System.monotonic_time(:millisecond)
end
