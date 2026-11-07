defmodule Tnfs.ConfigTest do
  @moduledoc """
  What the configuration refuses to build.

  Every check here is one a running server cannot make for itself: the wire
  limits are three independent numbers that have to agree, and a combination
  that does not agree produces a command which is dead rather than degraded. The
  place to find out is `load!/1`, which `Tnfs.Application` calls before any
  listener exists.
  """

  use ExUnit.Case, async: true

  alias Tnfs.Command
  alias Tnfs.Config
  alias Tnfs.Directory

  describe "the wire limits" do
    test "must leave room for a full read" do
      # A READ success payload is a u16 length followed by the data. With
      # `max_response_payload` one byte short, the largest read the server
      # advertises is one it can never answer.
      assert_raise ArgumentError, ~r/max_io \+ 2 must not exceed max_response_payload/, fn ->
        Config.build!(max_io: 512, max_response_payload: 513, max_datagram: 532)
      end

      assert %Config{} = Config.build!(max_io: 512, max_response_payload: 514, max_datagram: 532)
    end

    test "must leave room for the response header" do
      assert_raise ArgumentError,
                   ~r/max_response_payload \+ 5 must not exceed max_datagram/,
                   fn ->
                     Config.build!(max_io: 64, max_response_payload: 528, max_datagram: 532)
                   end
    end

    test "must fit the widest fixed reply the command table describes" do
      # STAT at 22 bytes. Computed rather than written down, so a command added
      # with a wider fixed response raises the floor with it.
      floor = Command.largest_fixed_response()
      assert floor == 22

      assert_raise ArgumentError, ~r/max_response_payload must be at least #{floor}/, fn ->
        Config.build!(max_io: 8, max_response_payload: floor - 1, max_datagram: 532)
      end

      assert %Config{} =
               Config.build!(max_io: 8, max_response_payload: floor, max_datagram: 532)
    end

    test "must fit a READDIRX chunk header and one entry" do
      # 19 bytes: the four byte chunk header, fourteen bytes of per entry
      # metadata and a one byte name. Below it every READDIRX on a non-empty
      # directory would answer with an empty chunk forever.
      assert Directory.min_response_payload() == 19
      assert Command.largest_fixed_response() >= Directory.min_response_payload()
    end

    test "are accepted at their documented defaults" do
      config = Config.build!([])

      assert config.max_io + 2 <= config.max_response_payload
      assert config.max_response_payload + 5 <= config.max_datagram
      assert config.max_response_payload >= Command.largest_fixed_response()
      assert config.max_response_payload >= Directory.min_response_payload()
    end
  end

  describe "boot" do
    test "refuses an inconsistent combination before anything is published" do
      # `load!/1` is what `Tnfs.Application` calls, and it raises before the
      # supervisor that owns the listener is ever built.
      assert_raise ArgumentError, fn -> Config.load!(max_io: 512, max_response_payload: 64) end
    end
  end

  describe "policy fields" do
    test "reject a profile this server does not implement" do
      # `:drop` was accepted by validation and then ignored by the router, which
      # told an operator they had configured something they had not.
      assert_raise ArgumentError, ~r/sid_ip_mismatch must be one of \[:ebadsession\]/, fn ->
        Config.build!(sid_ip_mismatch: :drop)
      end

      assert %Config{sid_ip_mismatch: :ebadsession} = Config.build!(sid_ip_mismatch: :ebadsession)
    end

    test "reject an unknown key rather than ignoring it" do
      assert_raise ArgumentError, ~r/unknown etnfsd configuration keys/, fn ->
        Config.build!(sid_ip_mismatsh: :ebadsession)
      end
    end
  end
end
