defmodule Tnfs.SessionAddressTest do
  @moduledoc """
  What happens to a valid SID presented from the wrong address.

  The answer is EBADSESSION with SID `0x0000` so that the client re-MOUNTs
  instead of waiting for a timeout, and the addressed session is left exactly as
  it was: no command executed, no `last_contact` refreshed, no retry cache
  overwritten (handoff section 14.1, ADR 2). Otherwise anyone who can guess a
  two byte SID could keep someone else's session alive, or poison the reply that
  session owes to its real owner.

  `127.0.0.2` is not bindable on a stock macOS loopback, so the foreign address
  is injected at `Tnfs.Router.route/4` rather than by opening a second socket.
  Everything below the router - registry, session, rate limit - is the running
  server the case started.
  """

  use Tnfs.ServerCase, async: false

  alias Tnfs.Peer
  alias Tnfs.Router
  alias Tnfs.SessionRegistry

  @foreign Peer.udp({10, 0, 0, 9}, 5000)

  @moduletag config: [read_only: false]

  setup context do
    File.write!(Path.join(context.root, "a.txt"), "hello")
    %{sid: mount!(context)}
  end

  test "is answered EBADSESSION with SID 0x0000", context do
    {:ok, data} = Protocol.encode_request(context.sid, 1, :stat, %{path: "/a.txt"})

    assert {:reply, encoded} = Router.route(data, @foreign, context.config)
    assert {:ok, response, _args} = Protocol.decode_response(encoded, context.config)

    assert response.status == :ebadsession
    # SID 0, not the SID that was presented: the reply must not confirm to a
    # scanner that the SID it guessed exists.
    assert response.sid == 0
    # The sequence number and command are echoed so the client can match the
    # reply to the request it is about to give up on.
    assert response.seq == 1
    assert response.command_id == Tnfs.Command.id(:stat)
  end

  test "leaves the session's contact time and sequence state untouched", context do
    {:ok, pid, _address} = SessionRegistry.lookup(context.sid)
    before = :sys.get_state(pid)

    {:ok, data} = Protocol.encode_request(context.sid, 1, :stat, %{path: "/a.txt"})
    assert {:reply, _encoded} = Router.route(data, @foreign, context.config)

    after_state = :sys.get_state(pid)

    # `last_contact` is what the idle sweeper reads, so refreshing it here would
    # let a stranger keep a session alive indefinitely.
    assert after_state.last_contact == before.last_contact
    assert after_state.last_seq == before.last_seq
    assert after_state.last_response == before.last_response
    assert after_state.last_raw == before.last_raw
  end

  test "does not disturb the retry cache the real client still depends on", context do
    # The real client runs a request, then the stranger sends one with the same
    # sequence number, then the real client retries. The retry has to replay the
    # original answer byte for byte.
    {response, _args} = call(context, context.sid, 7, :stat, %{path: "/a.txt"})
    assert response.status == :success

    {:ok, data} = Protocol.encode_request(context.sid, 7, :stat, %{path: "/nope"})
    assert {:reply, _encoded} = Router.route(data, @foreign, context.config)

    {retry, _args} = call(context, context.sid, 7, :stat, %{path: "/a.txt"})
    assert retry.status == :success
    assert retry.payload == response.payload
  end

  test "does not rebind the session to the stranger's address", context do
    {:ok, data} = Protocol.encode_request(context.sid, 1, :stat, %{path: "/a.txt"})
    assert {:reply, _encoded} = Router.route(data, @foreign, context.config)

    # The registry still points at the loopback, and the real client is still
    # served - a rebinding would have handed the session over.
    assert {:ok, _pid, {127, 0, 0, 1}} = SessionRegistry.lookup(context.sid)

    {response, _args} = call(context, context.sid, 2, :stat, %{path: "/a.txt"})
    assert response.status == :success
  end

  test "costs the stranger a rate limit token", context do
    # A guessed SID is unauthenticated traffic and has to be paid for, or the
    # EBADSESSION replies become a free amplifier.
    before = Tnfs.Limits.tokens(@foreign.address, context.config.rate_limit_per_window)

    {:ok, data} = Protocol.encode_request(context.sid, 1, :stat, %{path: "/a.txt"})
    assert {:reply, _encoded} = Router.route(data, @foreign, context.config)

    assert Tnfs.Limits.tokens(@foreign.address, context.config.rate_limit_per_window) ==
             before - 1
  end
end
