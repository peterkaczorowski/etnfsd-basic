defmodule Tnfs.Application do
  @moduledoc """
  Root of the supervision tree.

  Without a configured export root there is nothing to serve, so the server
  is not started at all. This is what lets the test suite boot the
  application and then start its own isolated `Tnfs.Runtime` per test. The
  web endpoint is absent by the same rule, from its own switch.

  The strategy is `:one_for_one` and the children are siblings, which is the
  whole of the isolation between them: TNFS, the public web page and the live
  transfer panel share a node and nothing else, so no restart can reach the
  others. What they do share is boot. If any child cannot start, this function
  fails and the node goes down, rather than coming up half-configured and
  reporting itself healthy.

  The panel is last, which matters. It publishes the address sessions emit to,
  so starting it after `Tnfs.Runtime` means events begin flowing to a process
  that already exists; and being last, a failure to configure it is discovered
  after the parts that do the actual work are known to be startable.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    config = Tnfs.Config.load!()
    children = if(config.root, do: [{Tnfs.Runtime, config}], else: [])

    Supervisor.start_link(children, strategy: :one_for_one, name: Tnfs.Supervisor)
  end
end
