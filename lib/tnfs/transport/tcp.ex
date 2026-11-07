defmodule Tnfs.Transport.TCP do
  @moduledoc """
  Legacy TCP transport, off by default.

  TNFS defines its unit of data as a datagram and never defines a TCP frame,
  so this transport is a compatibility mode rather than a peer of UDP
  (handoff section 2.2). Frames are reassembled incrementally from the
  command schema, because most commands do not carry their own length.

  The known limitation is on the client side: the FujiNet firmware reads
  whatever bytes happen to be available and validates little more than the
  sequence number, so a response split by the kernel can be treated as
  complete. The server does what it can - it encodes each response into one
  binary, sends it with a single call and enables `TCP_NODELAY` - but only a
  client-side fix or a length-prefixed profile closes that hole (handoff
  section 2.3).
  """

  use Supervisor

  @doc false
  def start_link(config), do: Supervisor.start_link(__MODULE__, config, name: __MODULE__)

  @impl Supervisor
  def init(config) do
    children = [
      {Tnfs.Transport.TCP.ConnectionSupervisor, config},
      {Tnfs.Transport.TCP.Listener, config}
    ]

    # The listener is started last so that it is stopped first: no new
    # connection can be accepted while the supervisor below it is going away.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
