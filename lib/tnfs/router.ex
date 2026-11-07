defmodule Tnfs.Router do
  @moduledoc """
  Turns received bytes into response bytes.

  Transport independent on purpose: the UDP dispatcher and every TCP connection
  process run the same routing rules, so the two transports cannot drift apart.
  This module performs no I/O; it only decides what should be sent back.

  It runs in a worker or connection process, never in a listener, because
  routing a session command blocks on that session.

  This is also the single place that decides what counts as *sessionless*
  traffic and charges it against the per-address rate limit: MOUNT, unknown
  SIDs, SIDs presented from another address and undecodable requests. A request
  belonging to a live session of the calling peer is never charged, so an
  established client is limited by its own transport and by the session
  backlog, not by a token bucket sized for handshakes. No transport may add a
  second bucket of its own; doing so once capped every TCP session at the
  handshake rate.
  """

  alias Tnfs.Config
  alias Tnfs.Limits
  alias Tnfs.Peer
  alias Tnfs.Protocol
  alias Tnfs.Protocol.Request
  alias Tnfs.Protocol.Response
  alias Tnfs.Reply
  alias Tnfs.Session
  alias Tnfs.SessionRegistry

  @type outcome :: {:reply, binary()} | :async | :drop

  @doc """
  Routes one complete request.

  `:drop` means nothing may be sent: either the datagram was too damaged to
  answer safely, or the source exceeded its budget for unauthenticated traffic.
  `:async` means a session took the request and will answer through `sink`
  itself, so the caller must not wait and must not send anything.
  """
  @spec route(binary(), Peer.t(), Config.t(), Reply.t()) :: outcome()
  def route(data, %Peer{} = peer, config, sink \\ :sync) do
    case Protocol.decode_request(data, config) do
      {:ok, request} ->
        dispatch(request, peer, config, sink)

      {:error, header, status} ->
        :telemetry.execute([:tnfs, :request, :rejected], %{count: 1}, %{
          address: peer.address,
          status: status,
          command_id: header.command_id
        })

        sessionless(peer, config, fn ->
          encode(header.sid, header.seq, header.command_id, status, <<>>, config)
        end)

      {:drop, reason} ->
        :telemetry.execute([:tnfs, :request, :dropped], %{count: 1}, %{
          address: peer.address,
          reason: reason
        })

        :drop
    end
  end

  @doc """
  Response sent when a partition is saturated.

  EAGAIN carries the retry delay as a u16 after the status byte, so a client
  can back off instead of hammering a loaded server (handoff section 2.1).

  A saturated partition still owes an established session an answer, so the
  rate limit applies here only to datagrams that do not belong to one.
  """
  @spec overloaded(binary(), Peer.t(), Config.t()) :: outcome()
  def overloaded(<<sid::unsigned-little-16, seq, command_id, _rest::binary>>, peer, config) do
    payload =
      if config.eagain_backoff, do: <<config.retry_ms::unsigned-little-16>>, else: <<>>

    build = fn -> encode(sid, seq, command_id, :eagain, payload, config) end

    if established?(sid, peer) do
      {:reply, build.()}
    else
      sessionless(peer, config, build)
    end
  end

  def overloaded(_data, _peer, _config), do: :drop

  defp dispatch(%Request{command: :mount} = request, peer, config, _sink) do
    sessionless(peer, config, fn -> SessionRegistry.mount(request, peer) end)
  end

  defp dispatch(%Request{} = request, %Peer{address: address} = peer, config, sink) do
    case SessionRegistry.lookup(request.sid) do
      {:ok, pid, ^address} ->
        to_session(pid, request, peer, config, sink)

      {:ok, _pid, _other_address} ->
        # A valid SID from a different address is answered with EBADSESSION and
        # SID 0, and the session is left completely untouched: no command, no
        # last_contact update, no transport rebinding (handoff section 14.1,
        # ADR 2). Silence would only cost the client a timeout.
        :telemetry.execute([:tnfs, :session, :address_mismatch], %{count: 1}, %{
          sid: request.sid,
          address: address
        })

        bad_session(request, peer, config)

      :error ->
        bad_session(request, peer, config)
    end
  end

  defp to_session(pid, request, peer, config, :sync) do
    case Session.request(pid, request, config.session_call_timeout_ms) do
      {:ok, encoded} ->
        {:reply, encoded}

      {:error, :busy} ->
        busy(request, config)

      {:error, :gone} ->
        # The session died between the lookup and the call. Its state is gone,
        # so the honest answer is EBADSESSION rather than a fabricated success.
        bad_session(request, peer, config)
    end
  end

  defp to_session(pid, request, _peer, config, sink) do
    case Limits.enqueue(request.sid, config.max_session_queue) do
      :ok ->
        Session.deliver(pid, request, sink)
        :async

      {:error, :overload} ->
        # The session is behind. Nothing waits on it any more, so its queue
        # length is the only thing that can say so, and EAGAIN is better than
        # letting one client's mailbox grow without bound.
        busy(request, config)
    end
  end

  defp busy(request, config) do
    :telemetry.execute([:tnfs, :session, :busy], %{count: 1}, %{sid: request.sid})

    payload = if config.eagain_backoff, do: <<config.retry_ms::unsigned-little-16>>, else: <<>>

    {:reply, encode(request.sid, request.seq, request.command_id, :eagain, payload, config)}
  end

  # A SID this server does not know, or knows at a different address, gets
  # EBADSESSION with SID 0x0000 so the client re-MOUNTs instead of waiting for
  # a timeout (handoff section 14.1, ADR 2). The addressed session, if any, is
  # left completely alone.
  defp bad_session(request, peer, config) do
    sessionless(peer, config, fn ->
      encode(0, request.seq, request.command_id, :ebadsession, <<>>, config)
    end)
  end

  defp established?(sid, %Peer{address: address}) do
    match?({:ok, _pid, ^address}, SessionRegistry.lookup(sid))
  end

  # Exactly one token per sessionless request, charged once, here.
  defp sessionless(%Peer{address: address}, config, build) do
    if Limits.allow?(address, config.rate_limit_per_window) do
      {:reply, build.()}
    else
      # No address in the metadata. This event fires once per refused packet,
      # and a refused packet is an attacker's packet with an address he chose;
      # a handler that grouped by it would rebuild, in the aggregator, exactly
      # the unbounded per-address table the rate limiter refuses to keep.
      :telemetry.execute([:tnfs, :request, :rate_limited], %{count: 1}, %{})
      :drop
    end
  end

  defp encode(sid, seq, command_id, status, payload, config) do
    response = %Response{
      sid: sid,
      seq: seq,
      command_id: command_id,
      status: status,
      payload: payload
    }

    {:ok, encoded} = Protocol.encode_response(response, config)
    encoded
  end
end
