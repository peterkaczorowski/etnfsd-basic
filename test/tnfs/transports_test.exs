defmodule Tnfs.TransportsTest do
  @moduledoc """
  The mode, its spellings and its precedence.

  `async: true` is possible only because `resolve!/1` takes the environment as
  an argument instead of reading it. That is the whole reason it does.
  """

  use ExUnit.Case, async: true

  alias Tnfs.Transports

  @canonical Transports.canonical_env()
  @legacy_udp Enum.at(Transports.legacy_env(), 0)
  @legacy_tcp Enum.at(Transports.legacy_env(), 1)

  describe "the domain" do
    test "is exactly three modes" do
      assert Enum.sort(Transports.modes()) == [:both, :tcp_only, :udp_only]
    end

    test "has no way to say neither" do
      # The point of the enum. A server that listens on nothing is not a state
      # this type can hold, so no validation has to reject it and no
      # half-configured deployment can reach it.
      for mode <- Transports.modes() do
        assert Transports.udp?(mode) or Transports.tcp?(mode)
      end
    end

    test "names round-trip" do
      for mode <- Transports.modes() do
        assert mode |> Transports.name() |> Transports.parse!() == mode
      end
    end

    test "spells the modes the way the flags do" do
      # `--tcp-only` and `ETNFSD_TNFS_TRANSPORTS=tcp-only` have to be the same
      # word, because the documentation shows them as the same word and the
      # launcher turns one into the other by copying it.
      assert Transports.name(:both) == "both"
      assert Transports.name(:tcp_only) == "tcp-only"
      assert Transports.name(:udp_only) == "udp-only"
    end
  end

  describe "which listeners a mode runs" do
    test "both runs both" do
      assert Transports.udp?(:both)
      assert Transports.tcp?(:both)
    end

    test "tcp-only runs only TCP" do
      refute Transports.udp?(:tcp_only)
      assert Transports.tcp?(:tcp_only)
    end

    test "udp-only runs only UDP" do
      assert Transports.udp?(:udp_only)
      refute Transports.tcp?(:udp_only)
    end
  end

  describe "parsing" do
    test "accepts the three documented spellings" do
      assert Transports.parse!("both") == :both
      assert Transports.parse!("tcp-only") == :tcp_only
      assert Transports.parse!("udp-only") == :udp_only
    end

    test "refuses anything else, and says what it would have taken" do
      # Including the internal spelling: `tcp_only` is what this module calls
      # the mode to itself, not what it accepts from outside, and quietly
      # taking both spellings is how a second interface appears.
      for value <- ["tcp", "udp", "tcp_only", "TCP-ONLY", "none", "", " both"] do
        message = assert_raise(ArgumentError, fn -> Transports.parse!(value) end).message

        assert message =~ @canonical
        assert message =~ "both | tcp-only | udp-only"
      end
    end

    test "refuses a value that is not even a string" do
      assert_raise ArgumentError, fn -> Transports.parse!(:both) end
    end
  end

  describe "resolving from the environment" do
    test "an empty environment is both" do
      # Requirement and regression test at once: the default is what production
      # serves, and a change to it is a change to production made by omission.
      assert Transports.resolve!(%{}) == :both
      assert Transports.default() == :both
    end

    test "the canonical variable selects the mode" do
      for mode <- Transports.modes() do
        assert Transports.resolve!(%{@canonical => Transports.name(mode)}) == mode
      end
    end

    test "an unreadable canonical value stops the node" do
      assert_raise ArgumentError, fn -> Transports.resolve!(%{@canonical => "tcp"}) end
    end

    test "a variable set to nothing is a variable that is not set" do
      # A configuration with `ETNFSD_TNFS_TRANSPORTS:` and no value is declaring
      # that it does not set it. Reading that as the empty string would fail the
      # boot with a complaint about a mode named "".
      assert Transports.resolve!(%{@canonical => ""}) == :both
      assert Transports.resolve!(%{@legacy_udp => "", @legacy_tcp => ""}) == :both
    end
  end

  describe "the superseded variables" do
    test "map to the mode they described" do
      assert Transports.resolve!(%{@legacy_udp => "true", @legacy_tcp => "true"}) == :both
      assert Transports.resolve!(%{@legacy_udp => "true", @legacy_tcp => "false"}) == :udp_only
      assert Transports.resolve!(%{@legacy_udp => "false", @legacy_tcp => "true"}) == :tcp_only
    end

    test "keep the defaults they had when only one of them is set" do
      # `TNFS_UDP` defaulted to true and `TNFS_TCP` to false. A deployment that
      # set one and left the other alone had a meaning, and the migration has to
      # be the same server, not a better-reasoned one.
      assert Transports.resolve!(%{@legacy_tcp => "true"}) == :both
      assert Transports.resolve!(%{@legacy_udp => "true"}) == :udp_only
      assert Transports.resolve!(%{@legacy_tcp => "false"}) == :udp_only
    end

    test "TNFS_UDP=false alone is the one migration that stops" do
      # It has to. `TNFS_TCP` defaulted to false, so this pair said "no UDP and
      # no TCP" under the old rules as well - the old code simply started a
      # server that listened on nothing and reported itself fine. Carrying that
      # behaviour forward faithfully would mean carrying the bug forward, so
      # this is the one legacy reading that is refused rather than translated.
      assert_raise ArgumentError, ~r/listen for nothing/, fn ->
        Transports.resolve!(%{@legacy_udp => "false"})
      end
    end

    test "accept the boolean spellings they always accepted" do
      assert Transports.resolve!(%{@legacy_udp => "1", @legacy_tcp => "yes"}) == :both
      assert Transports.resolve!(%{@legacy_udp => "no", @legacy_tcp => "1"}) == :tcp_only
    end

    test "refuse a value that is not a boolean" do
      assert_raise ArgumentError, ~r/#{@legacy_udp} must be true or false/, fn ->
        Transports.resolve!(%{@legacy_udp => "maybe"})
      end
    end

    test "both false is refused rather than resolved" do
      # The state the two booleans could reach and the enum cannot. It has to
      # fail at the boundary where the old spelling is read, because that is the
      # last place it is still expressible.
      message =
        assert_raise(ArgumentError, fn ->
          Transports.resolve!(%{@legacy_udp => "false", @legacy_tcp => "false"})
        end).message

      assert message =~ "listen for nothing"
      assert message =~ @canonical
    end

    test "contradicting the canonical variable stops the node" do
      # Not "the new one wins". Two settings disagree, the operator wrote both,
      # and guessing which they meant is how a maintenance experiment survives
      # into production. The message quotes both spellings.
      message =
        assert_raise(ArgumentError, fn ->
          Transports.resolve!(%{
            @canonical => "tcp-only",
            @legacy_udp => "true",
            @legacy_tcp => "true"
          })
        end).message

      assert message =~ "tcp-only"
      assert message =~ @legacy_udp
      assert message =~ @legacy_tcp
    end

    test "agreeing with the canonical variable is allowed" do
      # The state a half-finished migration is in: the new variable set, the old
      # pair not yet removed, both saying the same thing. That is not an error.
      assert Transports.resolve!(%{
               @canonical => "both",
               @legacy_udp => "true",
               @legacy_tcp => "true"
             }) == :both
    end
  end
end
