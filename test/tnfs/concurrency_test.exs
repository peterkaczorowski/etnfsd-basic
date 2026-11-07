defmodule Tnfs.ConcurrencyTest do
  @moduledoc """
  Sessions must make progress independently of each other.

  This is the property a functional test cannot see and a real deployment
  fails on: one client asking for a huge directory must not stop everybody
  else, not even the clients that happen to share a dispatcher worker with it.
  """

  use Tnfs.ServerCase, async: false

  alias Tnfs.Dispatcher
  alias Tnfs.Protocol
  alias Tnfs.SessionRegistry
  alias Tnfs.Status

  @loopback {127, 0, 0, 1}
  @entries 8_000

  # One partition means two sessions provably share a worker, so these tests
  # cannot pass by an accident of hashing.
  @moduletag config: [dispatch_partitions: 1, read_only: false]

  setup context do
    File.write!(Path.join(context.root, "small.txt"), "x")
    :ok
  end

  test "a slow session does not hold up another one on the same worker", context do
    big = Path.join(context.root, "big")
    File.mkdir_p!(big)
    for index <- 1..@entries, do: File.write!(Path.join(big, "entry-#{index}.txt"), "")

    slow = client_socket()
    quick = client_socket()

    slow_sid = mount!(context, socket: slow, seq: 0)
    quick_sid = mount!(context, socket: quick, seq: 1)

    # Two identical MOUNTs from one address are a retransmission as far as the
    # dedup cache is concerned, and would hand both sockets the same session -
    # which would make this test pass by serialising one session with itself.
    assert slow_sid != quick_sid

    assert Dispatcher.partition(<<slow_sid::unsigned-little-16>>, @loopback, 1) ==
             Dispatcher.partition(<<quick_sid::unsigned-little-16>>, @loopback, 1)

    # Warm up so first-call costs are not what is being measured.
    assert {%{status: :success}, _args} =
             call(context, quick_sid, 1, :stat, %{path: "/small.txt"}, socket: quick)

    {baseline, _reply} =
      :timer.tc(fn ->
        call(context, quick_sid, 2, :stat, %{path: "/small.txt"}, socket: quick)
      end)

    # The listing is started and deliberately not read, so it is still running
    # while the STAT below is served.
    {:ok, listing} =
      Protocol.encode_request(slow_sid, 3, :opendirx, %{
        diropts: 0,
        sortopts: 0,
        max_results: 0,
        pattern: "*",
        path: "/big"
      })

    :ok = :gen_udp.send(slow, @loopback, context.port, listing)

    {busy, reply} =
      :timer.tc(fn ->
        call(context, quick_sid, 4, :stat, %{path: "/small.txt"}, socket: quick)
      end)

    assert {%{status: :success}, _args} = reply

    # Before sessions answered for themselves this took as long as the listing,
    # because the worker was blocked inside the other session's call. The bound
    # is loose on purpose: it separates "a few hundred microseconds" from "as
    # long as the listing takes", it does not measure the scheduler.
    assert busy < max(baseline * 20, 20_000),
           "STAT took #{busy} us beside a busy session and #{baseline} us beside an idle one"

    # And the slow session still got its own answer.
    {:ok, {_address, _port, raw}} = :gen_udp.recv(slow, 0, 30_000)
    {:ok, response, args} = Protocol.decode_response(raw, context.config)
    assert response.status == :success
    assert args.matched == @entries
  end

  @tag config: [dispatch_partitions: 1, read_only: false, max_session_queue: 2]
  test "a session that falls behind is told to back off rather than queued", context do
    sid = mount!(context)
    {:ok, pid, _address} = SessionRegistry.lookup(sid)

    # Nothing waits on a session any more, so its mailbox is where a backlog
    # forms. Freezing the process is the only way to observe a full one
    # deterministically.
    true = :erlang.suspend_process(pid)

    for seq <- 1..5 do
      {:ok, data} = Protocol.encode_request(sid, seq, :stat, %{path: "/small.txt"})
      :ok = :gen_udp.send(context.socket, @loopback, context.port, data)
    end

    # The requests past the bound are refused by the dispatcher, so they are
    # already answered while the session is still frozen.
    refused = drain(context.socket, [])
    assert length(refused) > 0
    assert Enum.all?(refused, &(status(&1) == Status.code(:eagain)))

    true = :erlang.resume_process(pid)

    accepted = drain(context.socket, [])
    assert Enum.all?(accepted, &(status(&1) == Status.code(:success)))

    # Every request got exactly one answer: none was dropped, none was queued
    # without bound.
    assert length(refused) + length(accepted) == 5
    assert length(accepted) <= context.config.max_session_queue + 1
  end

  defp drain(socket, acc) do
    case :gen_udp.recv(socket, 0, 200) do
      {:ok, {_address, _port, reply}} -> drain(socket, [reply | acc])
      {:error, :timeout} -> Enum.reverse(acc)
    end
  end

  defp status(<<_header::binary-size(4), status, _rest::binary>>), do: status
end
