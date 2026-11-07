defmodule Tnfs.BackpressureTest do
  @moduledoc """
  Admission control as seen from the wire: a saturated partition must answer
  EAGAIN with a retry delay, and unauthenticated traffic must run out of
  tokens instead of being served at line rate.
  """

  use Tnfs.ServerCase, async: false

  alias Tnfs.Limits
  alias Tnfs.Status

  @single_partition [dispatch_partitions: 1, max_inflight_per_partition: 1]

  @tag config: @single_partition
  test "a saturated partition answers EAGAIN with the retry delay", context do
    sid = mount!(context)

    # Occupy the only slot of the only partition from the test process, so the
    # listener sees exactly the state it would see under real load.
    assert Limits.acquire(0, 1) == :ok

    {:ok, data} = Protocol.encode_request(sid, 1, :umount, %{})
    reply = roundtrip(context, data)

    assert <<^sid::unsigned-little-16, 1, command_id, status, retry::unsigned-little-16>> = reply
    assert command_id == Tnfs.Command.id(:umount)
    assert status == Status.code(:eagain)
    assert retry == context.config.retry_ms

    # The session was not touched: releasing the slot makes the very same
    # request succeed.
    Limits.release(0)

    {response, _args} = call(context, sid, 1, :umount, %{})
    assert response.status == :success
  end

  @tag config: @single_partition ++ [eagain_backoff: false]
  test "the retry delay can be turned off for clients that mishandle it", context do
    sid = mount!(context)
    assert Limits.acquire(0, 1) == :ok

    {:ok, data} = Protocol.encode_request(sid, 1, :umount, %{})
    reply = roundtrip(context, data)

    assert byte_size(reply) == 5
    assert <<_header::binary-size(4), status>> = reply
    assert status == Status.code(:eagain)
  end

  @tag config: [rate_limit_per_window: 2, rate_limit_window_ms: 60_000]
  test "error replies run out of tokens instead of amplifying traffic", context do
    # Every one of these is an unauthenticated request answered with an error,
    # which is exactly the traffic the bucket exists to bound.
    {first, _args} = call(context, 0xBEEF, 0, :umount, %{})
    assert first.status == :ebadsession

    {second, _args} = call(context, 0xBEEF, 1, :umount, %{})
    assert second.status == :ebadsession

    {:ok, data} = Protocol.encode_request(0xBEEF, 2, :umount, %{})
    assert roundtrip(context, data, timeout: 200) == :timeout
  end

  @tag config: [rate_limit_per_window: 1, rate_limit_window_ms: 60_000]
  test "an established session is not charged for the bucket", context do
    # The single token is spent by the MOUNT itself.
    sid = mount!(context)

    {response, _args} = call(context, sid, 1, :stat, %{path: "/x"})
    refute response.status == :ebadsession
  end

  test "requests of one session keep their partition", context do
    partitions = context.config.dispatch_partitions

    assert Tnfs.Dispatcher.partition(<<7, 0, 0, 0>>, {127, 0, 0, 1}, partitions) ==
             Tnfs.Dispatcher.partition(<<7, 0, 9, 9>>, {198, 51, 100, 1}, partitions)
  end

  test "mount has no session yet, so it is spread by address", context do
    partitions = context.config.dispatch_partitions

    keys =
      for octet <- 1..64 do
        Tnfs.Dispatcher.partition(<<0, 0, 0, 0>>, {198, 51, 100, octet}, partitions)
      end

    assert length(Enum.uniq(keys)) > 1 or partitions == 1
  end
end
