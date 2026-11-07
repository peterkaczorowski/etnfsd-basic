defmodule Tnfs.Transports do
  @moduledoc """
  Which TNFS transports a server runs, as one value.

  This used to be two independent booleans, `udp` and `tcp`. Two booleans can
  say four things and only three of them are a server: the fourth, both false,
  is a process that holds an export open and answers nothing, and nothing in
  the old validation forbade it. A deployment could reach it by setting one
  variable and forgetting the other, and the only symptom would be silence.

  So the mode is one enum. `:both`, `:tcp_only` and `:udp_only` are the whole
  domain; "neither" is not a value that can be constructed, rather than a value
  that is rejected. Everything downstream - the supervision tree, the health
  check, the published ports - is derived from this single field, so there is
  one place to look and one place to change.

  The default is `:both`, because that is what production runs. A default that
  differs from the deployment it serves is a second source of truth waiting to
  drift.

  ## The names

  The external spelling is `both`, `tcp-only`, `udp-only`: the same words as
  the command line flags `--tcp-only` and `--udp-only`, so an operator who has
  read one has read the other. The internal spelling is an atom, because a
  hyphen is not one.
  """

  @type t :: :both | :tcp_only | :udp_only

  @modes %{"both" => :both, "tcp-only" => :tcp_only, "udp-only" => :udp_only}
  @names Map.new(@modes, fn {name, mode} -> {mode, name} end)

  @canonical_env "ETNFSD_TNFS_TRANSPORTS"
  @legacy_udp_env "TNFS_UDP"
  @legacy_tcp_env "TNFS_TCP"

  # What `TNFS_UDP` and `TNFS_TCP` meant when they were unset, before this
  # module existed. Preserved exactly, so that a deployment that sets one of
  # them keeps the behaviour it had rather than acquiring a new one.
  @legacy_udp_default true
  @legacy_tcp_default false

  @doc "Every mode, in no particular order."
  @spec modes() :: [t()]
  def modes, do: Map.values(@modes)

  @doc "The mode a server runs when nothing says otherwise."
  @spec default() :: t()
  def default, do: :both

  @doc "The environment variable that names the mode."
  @spec canonical_env() :: String.t()
  def canonical_env, do: @canonical_env

  @doc "The two superseded environment variables, in their documented order."
  @spec legacy_env() :: [String.t()]
  def legacy_env, do: [@legacy_udp_env, @legacy_tcp_env]

  @doc "Whether `mode` is one this server knows."
  @spec valid?(term()) :: boolean()
  def valid?(mode), do: mode in Map.values(@modes)

  @doc "The external spelling of `mode`, as written on a command line."
  @spec name(t()) :: String.t()
  def name(mode) when is_map_key(@names, mode), do: Map.fetch!(@names, mode)

  @doc """
  The mode named by `value`, or an `ArgumentError` naming the alternatives.

  Every rejection message lists what would have been accepted. A configuration
  error at boot is read by somebody who has just been paged, and "invalid" on
  its own makes them go and find this file.
  """
  @spec parse!(term()) :: t()
  def parse!(value) when is_binary(value) do
    case Map.fetch(@modes, value) do
      {:ok, mode} ->
        mode

      :error ->
        raise ArgumentError, "#{@canonical_env} must be #{alternatives()}, got #{inspect(value)}"
    end
  end

  def parse!(value) do
    raise ArgumentError, "#{@canonical_env} must be #{alternatives()}, got #{inspect(value)}"
  end

  @doc "Whether `mode` runs a UDP listener."
  @spec udp?(t()) :: boolean()
  def udp?(:tcp_only), do: false
  def udp?(mode) when mode in [:both, :udp_only], do: true

  @doc "Whether `mode` runs a TCP listener."
  @spec tcp?(t()) :: boolean()
  def tcp?(:udp_only), do: false
  def tcp?(mode) when mode in [:both, :tcp_only], do: true

  @doc """
  Resolves the mode from a map of environment variables.

  A pure function of its argument rather than a reader of `System.get_env/1`,
  because the precedence rules below are the part worth testing and a test that
  has to mutate the OS environment to reach them is a test that cannot run
  concurrently with anything.

  The precedence, in order:

    1. `ETNFSD_TNFS_TRANSPORTS`, which is what the `--tcp-only` and `--udp-only`
       flags set. The flags are not a second code path: the launcher turns a
       flag into this variable and nothing else, so the command line and the
       environment are resolved by the same lines.

    2. The superseded `TNFS_UDP` and `TNFS_TCP` pair, mapped to the mode they
       describe. Setting one leaves the other at the default it had before,
       which is how they behaved when they were the interface.

    3. `:both`.

  Two things are refused rather than resolved. A legacy pair that says neither
  transport is not a mode and never was a working server. And a legacy pair
  that contradicts the canonical variable is not silently overruled: the
  operator has said two different things and only they know which they meant,
  so the node stops with both spellings quoted.
  """
  @spec resolve!(%{optional(String.t()) => String.t() | nil}) :: t()
  def resolve!(env) when is_map(env) do
    case {present(env, @canonical_env), legacy(env)} do
      {nil, nil} -> default()
      {nil, mode} -> mode
      {value, nil} -> parse!(value)
      {value, mode} -> agree!(parse!(value), mode)
    end
  end

  defp agree!(mode, mode), do: mode

  defp agree!(canonical, legacy) do
    raise ArgumentError,
          "#{@canonical_env}=#{name(canonical)} contradicts " <>
            "#{@legacy_udp_env}/#{@legacy_tcp_env}, which say #{name(legacy)}. " <>
            "Set one of them, not both."
  end

  defp legacy(env) do
    udp = present(env, @legacy_udp_env)
    tcp = present(env, @legacy_tcp_env)

    if is_nil(udp) and is_nil(tcp) do
      nil
    else
      from_booleans(
        boolean!(udp, @legacy_udp_env, @legacy_udp_default),
        boolean!(tcp, @legacy_tcp_env, @legacy_tcp_default)
      )
    end
  end

  defp from_booleans(true, true), do: :both
  defp from_booleans(true, false), do: :udp_only
  defp from_booleans(false, true), do: :tcp_only

  defp from_booleans(false, false) do
    raise ArgumentError,
          "#{@legacy_udp_env} and #{@legacy_tcp_env} are both false, which is not a " <>
            "server: it would listen for nothing. Use #{@canonical_env}=#{alternatives()}."
  end

  # An unset variable and one set to nothing mean the same thing. A
  # configuration that declares a key and leaves the value blank is saying "I am not
  # setting this", and reading it as the empty string turns that into an error
  # about a mode called "".
  defp present(env, key) do
    case Map.get(env, key) do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> value
      value -> raise ArgumentError, "#{key} must be a string, got #{inspect(value)}"
    end
  end

  defp boolean!(nil, _key, default), do: default
  defp boolean!(value, _key, _default) when value in ["1", "true", "yes"], do: true
  defp boolean!(value, _key, _default) when value in ["0", "false", "no"], do: false

  defp boolean!(value, key, _default),
    do: raise(ArgumentError, "#{key} must be true or false, got #{inspect(value)}")

  defp alternatives, do: Enum.map_join(Enum.sort(Map.keys(@modes)), " | ", & &1)
end
