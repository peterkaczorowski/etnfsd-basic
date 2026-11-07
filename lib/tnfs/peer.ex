defmodule Tnfs.Peer do
  @moduledoc """
  Who sent a request, at two different levels of precision.

  TNFS binds a session to an IP address (handoff section 14.1, ADR 2), and that
  is deliberately coarse: a client may change source port between datagrams and
  must still reach its session. MOUNT deduplication needs the opposite - the
  finest identity the transport can offer - because two independent clients
  behind one NAT share an address, and treating their MOUNTs as retransmissions
  of each other would hand them the same session.

  So a peer carries both: `address` for session binding, and
  `{transport, origin}` for everything that must distinguish one client from
  another. `origin` is the UDP source port or a reference minted per TCP
  connection; neither is an authenticator, and neither is used for access
  control.
  """

  @type origin :: :inet.port_number() | reference()

  @type t :: %__MODULE__{
          address: :inet.ip_address(),
          transport: :udp | :tcp,
          origin: origin()
        }

  @enforce_keys [:address, :transport, :origin]
  defstruct [:address, :transport, :origin]

  @doc "A UDP peer, identified down to the source port."
  @spec udp(:inet.ip_address(), :inet.port_number()) :: t()
  def udp(address, port) when is_integer(port) do
    %__MODULE__{address: address, transport: :udp, origin: port}
  end

  @doc """
  A TCP peer, identified by the connection itself.

  A reference rather than the source port: ports are reused once a connection
  closes, and a new connection must never inherit the previous one's session.
  """
  @spec tcp(:inet.ip_address(), reference()) :: t()
  def tcp(address, connection) when is_reference(connection) do
    %__MODULE__{address: address, transport: :tcp, origin: connection}
  end
end
