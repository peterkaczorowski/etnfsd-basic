defmodule Tnfs.ExportRootTest do
  @moduledoc """
  The export root is the boundary of the export, not an object inside it.

  `RMDIR /` resolved to the root directory and removed it, which succeeded on an
  empty export and left the server with nothing to serve: every later MOUNT
  answered ENOENT, including for clients that had done nothing. `RENAME` had the
  same reach. Found by the command coverage test, which walks the whole table
  against one export.
  """

  use Tnfs.ServerCase, async: false

  @moduletag config: [read_only: false]

  setup context do
    %{sid: mount!(context)}
  end

  test "cannot be removed", context do
    {response, _args} = call(context, context.sid, 1, :rmdir, %{path: "/"})

    assert response.status == :eperm
    assert File.dir?(context.root)
  end

  test "cannot be removed under a path that resolves back to it", context do
    File.mkdir_p!(Path.join(context.root, "sub"))

    {response, _args} = call(context, context.sid, 1, :rmdir, %{path: "/sub/.."})

    # Either refusal is correct; what matters is that a second spelling of the
    # root is not a way around the first.
    assert response.status in [:eperm, :eacces]
    assert File.dir?(context.root)
  end

  test "cannot be renamed away", context do
    {response, _args} = call(context, context.sid, 1, :rename, %{source: "/", destination: "/x"})

    assert response.status == :eperm
    assert File.dir?(context.root)
  end

  test "cannot be renamed over", context do
    File.mkdir_p!(Path.join(context.root, "d"))

    {response, _args} = call(context, context.sid, 1, :rename, %{source: "/d", destination: "/"})

    assert response.status == :eperm
    assert File.dir?(context.root)
  end

  test "still allows an ordinary directory inside it to be removed", context do
    File.mkdir_p!(Path.join(context.root, "d"))

    {response, _args} = call(context, context.sid, 1, :rmdir, %{path: "/d"})

    assert response.status == :success
    refute File.exists?(Path.join(context.root, "d"))
  end

  test "is still mountable after the attempt", context do
    call(context, context.sid, 1, :rmdir, %{path: "/"})

    assert mount!(context, socket: client_socket()) != 0
  end
end
