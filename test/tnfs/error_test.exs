defmodule Tnfs.ErrorTest do
  use ExUnit.Case, async: false

  alias Tnfs.Error
  alias Tnfs.Status

  test "identity mappings keep the POSIX name" do
    for name <- [:enoent, :eacces, :eio, :einval, :erofs, :enotempty, :eloop] do
      assert Error.to_status(name) == name
    end
  end

  test "explicit translations" do
    assert Error.to_status(:edquot) == :enospc
    assert Error.to_status(:enotsup) == :enosys
    assert Error.to_status(:eintr) == :eagain
    assert Error.to_status(:exdev) == :einval
    assert Error.to_status(:system_limit) == :enfile
    assert Error.to_status(:eoverflow) == :efbig
  end

  test "unknown errors become EIO and are never EBADSESSION" do
    for term <- [:totally_unknown, :enodev_typo, {:weird, 1}, "string", 42] do
      assert Error.to_status(term) == :eio
    end
  end

  test "the translation is total over every atom it can plausibly see" do
    # Everything Erlang's :file and :gen_tcp can return, plus junk.
    candidates =
      ~w(eacces eagain ebadf ebusy edquot eexist efault efbig eintr einval eio eisdir
         eloop emfile emlink enametoolong enfile enodev enomem enospc enotblk enotdir
         enotsup enxio eperm epipe erofs espipe esrch estale exdev badarg terminated
         closed system_limit eoverflow eopnotsupp enodata enostr ealready e2big)a

    for reason <- candidates do
      status = Error.to_status(reason)
      assert Status.known?(status)
      refute status == :ebadsession
    end
  end

  test "untranslated errors emit telemetry" do
    handler = {__MODULE__, :untranslated}
    parent = self()

    :telemetry.attach(
      handler,
      [:tnfs, :error, :untranslated],
      fn _event, measurements, metadata, _cfg ->
        send(parent, {:untranslated, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert Error.to_status(:no_such_posix_error) == :eio
    assert_receive {:untranslated, %{count: 1}, %{reason: :no_such_posix_error}}
  end

  test "normalize/1 wraps filesystem results" do
    assert Error.normalize(:ok) == {:ok, nil}
    assert Error.normalize({:ok, 7}) == {:ok, 7}
    assert Error.normalize({:error, :enoent}) == {:error, :enoent}
    assert Error.normalize({:error, :edquot}) == {:error, :enospc}
  end
end
