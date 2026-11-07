defmodule Tnfs.Session.HandlerCoverageTest do
  @moduledoc """
  Every command in the table is answered by something.

  `Tnfs.Session.Handler.dispatch/3` deliberately has no catch-all clause, so a
  command added to `Tnfs.Command` without a clause raises `FunctionClauseError`
  inside the session. Nothing in the compiler catches that - the argument is a
  plain atom - and the symptom in production is a client waiting for a datagram
  that is never sent, which is the one failure mode the protocol has no way to
  report (handoff section 10, item 5).

  So the check lives here: drive every name from `Tnfs.Command.names/0` through
  a real server and require a decodable response with a known status.
  """

  use Tnfs.ServerCase, async: false

  alias Tnfs.Command
  alias Tnfs.Status

  @moduletag config: [read_only: false]

  test "the table has the 25 ids the handoff defines" do
    # 24 real commands plus legacy OPEN 0x20, which is present so that it can be
    # answered ENOSYS instead of looking like an unknown id.
    assert length(Command.all()) == 25
    assert length(Command.names()) == length(Enum.uniq(Command.names()))
    assert :open_legacy in Command.names()
  end

  test "every command answers with a known status", context do
    for command <- Command.names() do
      # A fresh session per command: UMOUNT ends one, and a command that broke
      # a session must not be able to hide the next one's failure. Each is
      # released again straight away, or the per-IP session cap would run out
      # part way through the table and report that instead.
      sid = mount!(context)

      result = call(context, sid, 1, command, default_args(command))

      assert {response, _decoded} = result,
             "#{command} produced no response at all"

      assert Status.known?(response.status),
             "#{command} answered with an unknown status #{inspect(response.status)}"

      assert response.command_id == Command.id(command)

      call(context, sid, 2, :umount, %{})
    end
  end

  test "legacy OPEN is answered ENOSYS rather than ignored", context do
    sid = mount!(context)

    # 0x20 has no known payload layout (handoff section 14.1, ADR 5), so it is
    # sent as raw bytes. The point is that an id the server does not implement
    # is still an id the server replies to.
    assert {response, _decoded} = call(context, sid, 1, :open_legacy, %{payload: <<>>})
    assert response.status == :enosys
  end

  test "an unassigned command id is refused, not dropped", context do
    sid = mount!(context)

    assert :error = Command.fetch_name(0x7F)

    reply = roundtrip(context, <<sid::unsigned-little-16, 1, 0x7F>>)

    # Decoded by hand: `decode_response/2` needs a known command id to find the
    # payload schema, which is precisely what this reply does not have.
    assert <<^sid::unsigned-little-16, 1, 0x7F, status>> = reply
    assert Status.fetch_name(status) == {:ok, :enosys}
  end

  # Zero for every fixed-width field and `/` for every string: the point is to
  # reach the handler clause, not to succeed. A command with no clause raises
  # before it can decide what its arguments mean.
  defp default_args(command) do
    case Command.request_schema(command) do
      :opaque -> %{payload: <<>>}
      schema -> Map.new(schema, fn {field, type} -> {field, default(type)} end)
    end
  end

  defp default(:zstr), do: "/"
  defp default(:u16_blob), do: <<>>
  defp default(_fixed), do: 0
end
