defmodule Tnfs.Path do
  @moduledoc """
  Translates a client path into an absolute path inside the export root.

  This is the security boundary of the server (handoff section 6). It does not
  use prefix or substring tests on the joined string, because those are both
  too strict for legal names like `file..bak` and too weak against symlinks.
  Instead the path is taken apart into segments, every `..` is refused
  outright, and every component that already exists is checked with `lstat`.

  ## Symlinks

  Version 1 implements the `deny` profile only (handoff section 14.1, ADR 3).
  A symlink anywhere in the path - including as the final object - is refused
  with ELOOP. Nothing is followed, so nothing can lead out of the root.

  ## TOCTOU

  The checks and the subsequent `:file` call are separate syscalls, so a local
  attacker who can create files inside the export root can in principle swap a
  component between the check and the use. Closing that window needs
  `openat`/`O_NOFOLLOW` against a root directory descriptor, which the Erlang
  `:file` module does not expose, and v1 deliberately ships no NIF. The
  mitigation is operational: the export root must not be writable by untrusted
  local users, and the server should be isolated at the OS level.
  """

  alias Tnfs.Config
  alias Tnfs.Filesystem.Raw

  @type reason :: :eacces | :eloop | :einval | :enametoolong | :enotdir | :enoent | :eio

  @doc """
  Canonicalises the configured export root.

  The root is administrator-supplied and therefore trusted: symlinks in it are
  resolved here, once, so that every later comparison works on a stable
  absolute path. Client paths never get this treatment.
  """
  @spec canonical_root(binary()) :: {:ok, binary()} | {:error, reason()}
  def canonical_root(path) when is_binary(path) do
    ["/" | segments] = path |> Path.expand() |> Path.split()

    with {:ok, resolved} <- realpath(segments, "/", 0) do
      case Raw.stat(resolved) do
        {:ok, %File.Stat{type: :directory}} -> {:ok, resolved}
        {:ok, _stat} -> {:error, :enotdir}
        {:error, reason} -> {:error, Tnfs.Error.to_status(reason)}
      end
    end
  end

  @doc """
  Resolves `path` as sent by the client, relative to `root`.

  `root` must already be canonical. A leading `/` does not escape: the path is
  always interpreted inside the root, which is what a client means by an
  absolute path within its mount.
  """
  @spec resolve(binary(), binary(), Config.t()) :: {:ok, binary()} | {:error, reason()}
  def resolve(root, path, %Config{} = config) do
    with {:ok, absolute, _stat} <- resolve_stat(root, path, config), do: {:ok, absolute}
  end

  @doc """
  Resolves `path` and also hands back what the last component turned out to be.

  Proving that the final component is not a symlink means `lstat`ing it, and for
  a command whose whole answer is that `lstat` - STAT - taking it again is the
  same syscall twice on the same file. `bench/syscalls.exs` counted exactly that:
  two calls for a one-segment path, five for four segments.

  The stat is `nil` when there was nothing to look at: the root itself has no
  final component, and a path whose last component does not exist yet is legal
  for the commands that create one.
  """
  @spec resolve_stat(binary(), binary(), Config.t()) ::
          {:ok, binary(), File.Stat.t() | nil} | {:error, reason()}
  def resolve_stat(root, path, %Config{} = config) when is_binary(root) and is_binary(path) do
    with {:ok, segments} <- segments(path),
         {:ok, absolute} <- join(root, segments, config),
         {:ok, stat} <- check_components(root, segments) do
      {:ok, absolute, stat}
    end
  end

  @doc """
  Resolves a path used to create or replace an object.

  Identical to `resolve/3` here, because the final segment is never followed
  in the `deny` profile: an existing symlink at that position is already an
  error rather than something to dereference.
  """
  @spec resolve_for_create(binary(), binary(), Config.t()) ::
          {:ok, binary()} | {:error, reason()}
  def resolve_for_create(root, path, config), do: resolve(root, path, config)

  defp segments(path) do
    path
    |> :binary.split("/", [:global])
    |> Enum.reject(&(&1 in ["", "."]))
    |> validate_segments([])
  end

  defp validate_segments([], acc), do: {:ok, Enum.reverse(acc)}

  defp validate_segments([".." | _rest], _acc), do: {:error, :eacces}

  defp validate_segments([segment | rest], acc) do
    # A NUL inside a segment can only come from a field that was decoded as
    # opaque bytes; letting it through would truncate the name at the libc
    # boundary and address a different file than the one that was checked.
    if String.contains?(segment, <<0>>) do
      {:error, :einval}
    else
      validate_segments(rest, [segment | acc])
    end
  end

  defp join(root, [], _config), do: {:ok, root}

  defp join(root, segments, config) do
    absolute = Path.join([root | segments])

    if byte_size(absolute) > config.max_path_length do
      {:error, :enametoolong}
    else
      {:ok, absolute}
    end
  end

  # Walks from the root downwards. The first component that does not exist
  # ends the walk: nothing below it can exist either, so nothing below it can
  # be a symlink.
  #
  # Returns the `File.Stat` of the last component so that a caller which needs
  # it does not have to ask the kernel the same question a second time, and
  # `nil` when the walk ended without one.
  defp check_components(_root, []), do: {:ok, nil}

  defp check_components(root, [segment | rest]) do
    path = Path.join(root, segment)

    case Raw.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        :telemetry.execute([:tnfs, :path, :symlink_denied], %{count: 1}, %{path: path})
        {:error, :eloop}

      {:ok, %File.Stat{type: :directory} = stat} when rest == [] ->
        {:ok, stat}

      {:ok, %File.Stat{type: :directory}} ->
        check_components(path, rest)

      {:ok, stat} when rest == [] ->
        {:ok, stat}

      {:ok, _stat} ->
        # A non-directory in the middle of a path.
        {:error, :enotdir}

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, Tnfs.Error.to_status(reason)}
    end
  end

  # Component-wise realpath for the trusted root. The depth counter is the
  # usual guard against a symlink cycle.
  defp realpath(_segments, _acc, depth) when depth > 32, do: {:error, :eloop}

  defp realpath([], acc, _depth), do: {:ok, acc}

  defp realpath([segment | rest], acc, depth) do
    candidate = Path.join(acc, segment)

    case Raw.read_link(candidate) do
      {:ok, target} ->
        # An absolute target discards everything resolved so far, exactly as
        # the kernel would do.
        ["/" | resolved] = target |> Path.expand(acc) |> Path.split()
        realpath(resolved ++ rest, "/", depth + 1)

      {:error, _not_a_symlink} ->
        realpath(rest, candidate, depth)
    end
  end
end
