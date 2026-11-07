defmodule Tnfs.Session.Handler do
  @moduledoc """
  Executes one decoded command inside its session process.

  Runs in the session, so it may keep state, but it must never be called from a
  listener or an acceptor. Every clause returns exactly one
  `{status, payload, state}` triple - a command that produces no answer, or two
  answers, is a protocol bug (handoff section 10, items 5 and 11).

  Handles are small integers allocated from a fixed range per session, not
  wrapped descriptors: they travel as a u8 and the session owns the real
  resource. Zero is an ordinary handle value here, unlike in REFERENCE where it
  doubles as "no descriptor" (handoff section 3.3).
  """

  alias Tnfs.Command
  alias Tnfs.Directory
  alias Tnfs.Filesystem
  alias Tnfs.Path, as: SafePath
  alias Tnfs.Protocol
  alias Tnfs.Protocol.Request
  alias Tnfs.Session.Live

  @type result :: {Tnfs.Status.t(), binary(), term()}

  @doc "Executes a request against the session state."
  @spec execute(Request.t(), term()) :: result()
  def execute(%Request{command: command, args: args}, state) do
    if Command.mutating?(command) and state.config.read_only do
      # Read-only is enforced here, before any path resolution, and again in
      # the filesystem adapter (handoff section 8).
      {:eperm, <<>>, state}
    else
      dispatch(command, args, state)
    end
  end

  @doc "True when the command ends the session after this response."
  @spec final?(Command.name(), Tnfs.Status.t()) :: boolean()
  def final?(:umount, :success), do: true
  def final?(_command, _status), do: false

  @doc "Releases every resource owned by the session."
  @spec close_all(term()) :: :ok
  def close_all(state) do
    Enum.each(state.files, fn {_handle, file} -> Filesystem.close(file) end)
    Live.closed_all(state.live, state.last_contact)
    :ok
  end

  # -- session -------------------------------------------------------------

  # UMOUNT answers first; the session process stops afterwards and its
  # terminate/2 closes the handles (handoff section 3.1).
  defp dispatch(:umount, _args, state), do: {:success, <<>>, state}

  # A MOUNT carrying an established SID is not a session command: mounting is
  # handled by the registry before any session is involved.
  defp dispatch(:mount, _args, state), do: {:einval, <<>>, state}

  # Legacy OPEN stays unimplemented until golden vectors exist for its flag
  # encoding (handoff section 14.1, ADR 5). It is answered, never ignored.
  defp dispatch(:open_legacy, _args, state), do: {:enosys, <<>>, state}

  # -- files ---------------------------------------------------------------

  defp dispatch(:open, args, state) do
    with_path(state, args.path, fn path, state ->
      opts = [read_only: state.config.read_only, mode_mask: state.config.chmod_mask]

      with {:ok, handle} <- next_handle(state.files, state.config.max_file_handles),
           {:ok, file} <- Filesystem.open(path, args.flags, args.mode, opts) do
        # The *logical* path, the one the client asked for, and never `path`,
        # which is the resolved location on this host's disk.
        #
        # The peer address is passed for one purpose - a country code for the
        # flag - and `Tnfs.Session.Live` sends it straight out to the resolver
        # without storing it. It does not enter the record, the event or
        # anything the panel holds.
        state = %{
          state
          | files: Map.put(state.files, handle, file),
            live: Live.opened(state.live, handle, args.path, file.size, state.peer_ip)
        }

        reply(:open, %{handle: handle}, state)
      end
    end)
  end

  defp dispatch(:read, args, state) do
    with_file(state, args.handle, fn file, state ->
      # The client may ask for more than one datagram can carry; the wire limit
      # wins and the client simply reads again.
      count = min(args.requested, state.config.max_io)

      if count == 0 do
        {:einval, <<>>, state}
      else
        case Filesystem.read(file, count) do
          {:ok, data} ->
            # `last_contact` was set to the monotonic clock at the top of
            # `Tnfs.Session.run/2`, so this needs no clock read of its own.
            live =
              Live.read(
                state.live,
                args.handle,
                byte_size(data),
                state.transport,
                state.last_contact
              )

            reply(:read, %{data: data}, %{state | live: live})

          {:error, status} ->
            {status, <<>>, state}
        end
      end
    end)
  end

  defp dispatch(:write, args, state) do
    with_file(state, args.handle, fn file, state ->
      cond do
        state.config.read_only ->
          {:eperm, <<>>, state}

        byte_size(args.data) > state.config.max_io ->
          {:e2big, <<>>, state}

        true ->
          case Filesystem.write(file, args.data) do
            {:ok, written} -> reply(:write, %{actual: written}, state)
            {:error, status} -> {status, <<>>, state}
          end
      end
    end)
  end

  defp dispatch(:close, args, state) do
    with_file(state, args.handle, fn file, state ->
      Filesystem.close(file)

      state = %{
        state
        | files: Map.delete(state.files, args.handle),
          live: Live.closed(state.live, args.handle, state.last_contact)
      }

      {:success, <<>>, state}
    end)
  end

  defp dispatch(:lseek, args, state) do
    with_file(state, args.handle, fn file, state ->
      case Filesystem.seek(file, args.whence, args.offset) do
        {:ok, position} ->
          reply(:lseek, %{position: position}, %{
            state
            | live: Live.sought(state.live, args.handle, position)
          })

        {:error, status} ->
          {status, <<>>, state}
      end
    end)
  end

  defp dispatch(:stat, args, state) do
    with_stat(state, args.path, fn path, stat, state ->
      case Filesystem.stat(path, stat) do
        {:ok, payload} -> {:success, payload, state}
        {:error, status} -> {status, <<>>, state}
      end
    end)
  end

  defp dispatch(:unlink, args, state) do
    with_path(state, args.path, fn path, state -> result(Filesystem.unlink(path), state) end)
  end

  defp dispatch(:mkdir, args, state) do
    with_path(state, args.path, fn path, state -> result(Filesystem.mkdir(path), state) end)
  end

  defp dispatch(:rmdir, args, state) do
    with_path(state, args.path, fn path, state ->
      # `/` resolves to the export root, and the root is the boundary of the
      # export rather than an object inside it. Removing it succeeded and left
      # the server with nothing to serve: every later MOUNT answered ENOENT.
      if root?(path, state),
        do: {:eperm, <<>>, state},
        else: result(Filesystem.rmdir(path), state)
    end)
  end

  defp dispatch(:chmod, args, state) do
    with_path(state, args.path, fn path, state ->
      if state.config.chmod_enabled do
        result(Filesystem.chmod(path, args.mode, state.config.chmod_mask), state)
      else
        {:enosys, <<>>, state}
      end
    end)
  end

  defp dispatch(:rename, args, state) do
    with_path(state, args.source, fn source, state ->
      with_path(state, args.destination, fn destination, state ->
        cond do
          # Same reason as RMDIR: moving the root away empties the export.
          root?(source, state) -> {:eperm, <<>>, state}
          root?(destination, state) -> {:eperm, <<>>, state}
          true -> result(Filesystem.rename(source, destination), state)
        end
      end)
    end)
  end

  # -- directories ---------------------------------------------------------

  defp dispatch(:opendir, args, state) do
    with_path(state, args.path, fn path, state ->
      with {:ok, handle} <- next_handle(state.dirs, state.config.max_dir_handles),
           {:ok, entries} <- Filesystem.list_dir(path) do
        state = put_dir(state, handle, entries, path)
        reply(:opendir, %{handle: handle}, state)
      end
    end)
  end

  defp dispatch(:opendirx, args, state) do
    with_path(state, args.path, fn path, state ->
      with {:ok, handle} <- next_handle(state.dirs, state.config.max_dir_handles),
           {:ok, entries} <- Directory.open(path, args, state.config) do
        state = put_dir(state, handle, entries, path)
        reply(:opendirx, %{handle: handle, matched: length(entries)}, state)
      end
    end)
  end

  defp dispatch(:readdir, args, state) do
    with_dir(state, args.handle, fn dir, state ->
      case dir.rest do
        [] ->
          {:eof, <<>>, state}

        [entry | rest] ->
          dir = %{dir | rest: rest, position: dir.position + 1}
          state = %{state | dirs: Map.put(state.dirs, args.handle, dir)}
          reply(:readdir, %{name: Directory.name(entry)}, state)
      end
    end)
  end

  defp dispatch(:readdirx, args, state) do
    with_dir(state, args.handle, fn dir, state ->
      case Directory.chunk(dir, args.requested, state.config) do
        # Exactly one response, and never a payload after EOF (handoff section
        # 10, item 11).
        :eof ->
          {:eof, <<>>, state}

        {:ok, payload, dir} ->
          {:success, payload, %{state | dirs: Map.put(state.dirs, args.handle, dir)}}

        {:error, status} ->
          {status, <<>>, state}
      end
    end)
  end

  defp dispatch(:closedir, args, state) do
    with_dir(state, args.handle, fn _dir, state ->
      {:success, <<>>, %{state | dirs: Map.delete(state.dirs, args.handle)}}
    end)
  end

  defp dispatch(:telldir, args, state) do
    with_dir(state, args.handle, fn dir, state ->
      reply(:telldir, %{position: dir.position}, state)
    end)
  end

  defp dispatch(:seekdir, args, state) do
    with_dir(state, args.handle, fn dir, state ->
      # Seeking to the end is legal and simply means "no more entries"; the
      # snapshot makes the position a plain index, so it is always meaningful.
      if args.position > length(dir.entries) do
        {:einval, <<>>, state}
      else
        dir = %{dir | position: args.position, rest: Enum.drop(dir.entries, args.position)}
        {:success, <<>>, %{state | dirs: Map.put(state.dirs, args.handle, dir)}}
      end
    end)
  end

  # -- device --------------------------------------------------------------

  defp dispatch(command, _args, state) when command in [:size, :free, :sizebytes, :freebytes] do
    case Filesystem.device_info(state.root) do
      {:ok, total, available} -> reply(command, device_args(command, total, available), state)
      {:error, status} -> {status, <<>>, state}
    end
  end

  # No catch-all clause, on purpose: a command added to `Tnfs.Command` without a
  # clause here must fail loudly instead of falling into a default that answers
  # something plausible. The compiler cannot check that - `dispatch/3` takes an
  # atom, not a type whose members it knows - so the check is
  # `Tnfs.Session.HandlerCoverageTest`, which drives every name from
  # `Tnfs.Command.names/0` through `execute/2` and fails on the missing clause.

  defp device_args(:size, total, _available), do: %{kib: Filesystem.kib(total)}
  defp device_args(:free, _total, available), do: %{kib: Filesystem.kib(available)}
  defp device_args(:sizebytes, total, _available), do: %{bytes: Filesystem.bytes(total)}
  defp device_args(:freebytes, _total, available), do: %{bytes: Filesystem.bytes(available)}

  # -- plumbing ------------------------------------------------------------

  defp root?(path, state), do: path == state.root

  defp with_path(state, path, fun) do
    case SafePath.resolve(state.root, path, state.config) do
      {:ok, resolved} -> normalize(fun.(resolved, state), state)
      {:error, status} -> {status, <<>>, state}
    end
  end

  # STAT is the one command whose entire answer is the `lstat` that path
  # resolution has already made. `bench/syscalls.exs` counted two calls on the
  # same file for a one-segment STAT; this passes the first one through so the
  # second is not needed. `stat` is `nil` for the root and for a path whose last
  # component does not exist, and `Tnfs.Filesystem.stat/2` then looks it up.
  defp with_stat(state, path, fun) do
    case SafePath.resolve_stat(state.root, path, state.config) do
      {:ok, resolved, stat} -> normalize(fun.(resolved, stat, state), state)
      {:error, status} -> {status, <<>>, state}
    end
  end

  defp with_file(state, handle, fun) do
    case Map.fetch(state.files, handle) do
      {:ok, file} -> normalize(fun.(file, state), state)
      :error -> {:ebadf, <<>>, state}
    end
  end

  defp with_dir(state, handle, fun) do
    case Map.fetch(state.dirs, handle) do
      {:ok, dir} -> normalize(fun.(dir, state), state)
      :error -> {:ebadf, <<>>, state}
    end
  end

  # A nested `with/1` can fall through with a bare `{:error, status}`; turning
  # it into a full triple in one place keeps every clause above readable.
  defp normalize({status, payload, state}, _state)
       when is_atom(status) and is_binary(payload) do
    {status, payload, state}
  end

  defp normalize({:error, status}, state), do: {status, <<>>, state}

  defp result(:ok, state), do: {:success, <<>>, state}
  defp result({:error, status}, state), do: {status, <<>>, state}

  # Success payloads are built from the same declarative schema that decodes
  # them, so a response can never drift away from the contract in `Tnfs.Command`.
  defp reply(command, args, state) do
    case Protocol.encode_payload(command, args) do
      {:ok, payload} -> {:success, payload, state}
      {:error, {:out_of_range, _field}} -> {:einval, <<>>, state}
    end
  end

  # `rest` is the cursor the two readers walk down; `entries` stays whole so
  # that SEEKDIR can rebuild the cursor from an index.
  defp put_dir(state, handle, entries, path) do
    dir = %{entries: entries, rest: entries, position: 0, path: path}
    %{state | dirs: Map.put(state.dirs, handle, dir)}
  end

  # Handles are reused as soon as they are freed, and the lowest free one is
  # picked so that a client that closes and reopens stays in the low range.
  defp next_handle(taken, max) do
    case Enum.find(0..(max - 1), &(not Map.has_key?(taken, &1))) do
      nil -> {:error, :emfile}
      handle -> {:ok, handle}
    end
  end
end
