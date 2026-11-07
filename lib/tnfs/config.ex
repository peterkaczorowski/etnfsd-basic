defmodule Tnfs.Config do
  @moduledoc """
  Runtime configuration, frozen into `:persistent_term` at boot.

  The hot path must never ask a GenServer for configuration (handoff section
  7.4), so the whole configuration is one immutable struct read with
  `:persistent_term.get/2`. Updating it is a rare, explicit operation.

  Defaults follow the recommended production profile of handoff section 15:
  loopback only, read-only, symlinks denied, strict decoding.

  The one default that is not the handoff's is `transports`. The handoff
  recommends UDP alone, and this server's default is `:both`, because `:both`
  is what the deployment runs and a default that disagrees with production is a
  second source of truth. Nothing is widened by it: a mode decides which
  listeners exist, not what they permit.
  """

  @type t :: %__MODULE__{}

  defstruct root: nil,
            listen_address: {127, 0, 0, 1},
            port: 16384,
            # `:both`, `:tcp_only` or `:udp_only`. One field rather than two
            # booleans, so that "neither" is not expressible. See
            # `Tnfs.Transports`.
            transports: :both,
            # Wire limits (handoff section 2). A whole datagram, a single I/O
            # transfer, and the response payload after the status byte.
            max_datagram: 532,
            max_io: 512,
            max_response_payload: 527,
            # Session lifecycle and admission control.
            session_timeout_ms: 600_000,
            max_sessions: 256,
            max_sessions_per_ip: 16,
            max_file_handles: 16,
            max_dir_handles: 8,
            # How many entries an OPENDIRX walk may look at before it gives up
            # with E2BIG. Bounds a TRAVERSE over a huge tree that matches
            # almost nothing (handoff section 3.2).
            max_dir_scan: 100_000,
            # `.ignore` is a REFERENCE extension, not part of TNFS, so it is
            # opt-in.
            dir_ignore_file: false,
            max_ignore_patterns: 64,
            # How much of a `.ignore` file is read before it stops counting as
            # one. The file is attacker-controlled in any writable export, so
            # the read is bounded rather than trusted to be small.
            max_ignore_bytes: 65_536,
            # Dispatch and backpressure. `dispatch_partitions: nil` means one
            # partition per scheduler, resolved at load time.
            dispatch_partitions: nil,
            max_inflight_per_partition: 256,
            # Requests a session may have waiting before further ones are
            # answered EAGAIN. Nothing blocks on a session, so this mailbox is
            # where work for a slow client accumulates and has to be bounded.
            max_session_queue: 64,
            # Only the TCP path still waits on a session, so only it needs this.
            session_call_timeout_ms: 30_000,
            # Legacy TCP. The frame timeout bounds a half-sent request, the
            # connection timeout an idle one (handoff sections 2.3 and 5).
            max_tcp_connections: 64,
            tcp_frame_timeout_ms: 10_000,
            tcp_connection_timeout_ms: 600_000,
            # The most input bytes one connection may hold. The listening
            # socket's `buffer` option is set from `max_datagram`, so the driver
            # never hands the connection more than one datagram in one message
            # and this is not reached in practice - which is exactly why it is
            # checked anyway. A bound that rests on a driver option is the
            # driver's bound, not the application's, and the default it replaced
            # was 9216 bytes chosen by `inet_drv`.
            max_tcp_buffer: 1536,
            # Frames one callback may answer before handing the mailbox back.
            # Coalesced or pipelined requests beyond this are not refused: the
            # socket stays passive until the buffer drains, so the bytes wait in
            # the kernel rather than in this process, and `:check`, `:tcp_closed`
            # and every other connection get their turn between batches.
            max_tcp_frames_per_batch: 8,
            # How long one response may take to hand to the kernel. A client
            # that pipelines requests and never reads fills both socket buffers
            # and blocks the send, and a blocked connection process never
            # reaches its own timeout check.
            tcp_send_timeout_ms: 30_000,
            # Token bucket for traffic without an established session: MOUNT
            # and every error reply.
            rate_limit_per_window: 100,
            rate_limit_window_ms: 1_000,
            # How many buckets that token bucket is spread over. A UDP source
            # address is whatever the sender wrote in the packet, so keying the
            # table by address would let a forged flood allocate a row per
            # packet. The table is therefore a fixed array of buckets and an
            # address is hashed into one of them; this number, not the traffic,
            # is the memory bound.
            rate_limit_buckets: 4096,
            # How long a MOUNT reply stays replayable, so that a lost reply
            # does not leak a second session on retry, and how many such replies
            # are kept. The cache is keyed by peer, so a flood from unique
            # source ports is what sizes it - not `max_sessions`, which is why
            # this is configured independently rather than derived.
            mount_dedup_ttl_ms: 5_000,
            max_mount_dedup_entries: 4096,
            eagain_backoff: true,
            # Security policy.
            read_only: true,
            symlinks: :deny,
            max_path_length: 4096,
            # Protocol policy, see handoff section 14.1.
            strict_decode: true,
            sid_ip_mismatch: :ebadsession,
            seq_conflict: :eproto,
            legacy_open: :disabled,
            chmod_enabled: true,
            chmod_mask: 0o777,
            atari_mode: false,
            # MOUNT advertises this protocol version and minimum retry delay.
            server_version: 0x0103,
            retry_ms: 1000

  @key {__MODULE__, :config}

  # Application environment keys that are handled outside this struct.
  #
  # Adding a scope to `config/runtime.exs` and forgetting to add it here stops
  # the node at boot with `unknown etnfsd configuration keys`. That is the right
  # failure, and it is one the test suite cannot see on its own: those scopes
  # are set under `config_env() == :prod`, so under `mix test` the environment
  # never contains them and everything passes. The list is checked against the
  # file instead - see `Tnfs.ConfigScopeTest`.
  @ignored_env_keys [:included_applications]

  @doc """
  The `:etnfsd` application environment keys `load!/1` leaves to someone else.

  Public so that the list can be checked against `config/runtime.exs` without
  setting global application environment inside a test.
  """
  @spec ignored_env_keys() :: [atom()]
  def ignored_env_keys, do: @ignored_env_keys

  @doc """
  Builds the configuration from the application environment plus `overrides`,
  validates it and stores it in `:persistent_term`.
  """
  @spec load!(keyword()) :: t()
  def load!(overrides \\ []) do
    env =
      :etnfsd
      |> Application.get_all_env()
      |> Keyword.drop(@ignored_env_keys)

    config = build!(Keyword.merge(env, overrides))
    put(config)
    config
  end

  @doc "Builds and validates a configuration struct without publishing it."
  @spec build!(keyword()) :: t()
  def build!(opts) do
    known = Map.keys(Map.from_struct(%__MODULE__{}))

    case Keyword.keys(opts) -- known do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown etnfsd configuration keys: #{inspect(unknown)}"
    end

    validate!(struct!(__MODULE__, opts))
  end

  @doc "Returns the published configuration, or defaults if none was published."
  @spec get() :: t()
  def get, do: :persistent_term.get(@key, %__MODULE__{})

  @doc "Publishes a configuration struct. Intended for boot and for tests."
  @spec put(t()) :: :ok
  def put(%__MODULE__{} = config), do: :persistent_term.put(@key, config)

  @doc "Whether this configuration runs a UDP listener."
  @spec udp?(t()) :: boolean()
  def udp?(%__MODULE__{transports: transports}), do: Tnfs.Transports.udp?(transports)

  @doc "Whether this configuration runs a TCP listener."
  @spec tcp?(t()) :: boolean()
  def tcp?(%__MODULE__{transports: transports}), do: Tnfs.Transports.tcp?(transports)

  defp validate!(%__MODULE__{dispatch_partitions: nil} = c) do
    validate!(%{c | dispatch_partitions: System.schedulers_online()})
  end

  defp validate!(%__MODULE__{} = c) do
    # Port 0 is legal: it asks the OS for an ephemeral port, which is how the
    # test suite runs several servers without colliding.
    in_range!(c.port, 0..0xFFFF, :port)
    positive!(c.dispatch_partitions, :dispatch_partitions)
    positive!(c.max_inflight_per_partition, :max_inflight_per_partition)
    positive!(c.max_session_queue, :max_session_queue)
    positive!(c.session_call_timeout_ms, :session_call_timeout_ms)
    positive!(c.max_tcp_connections, :max_tcp_connections)
    positive!(c.tcp_frame_timeout_ms, :tcp_frame_timeout_ms)
    positive!(c.tcp_connection_timeout_ms, :tcp_connection_timeout_ms)
    positive!(c.tcp_send_timeout_ms, :tcp_send_timeout_ms)
    positive!(c.max_tcp_buffer, :max_tcp_buffer)
    positive!(c.max_tcp_frames_per_batch, :max_tcp_frames_per_batch)
    positive!(c.rate_limit_per_window, :rate_limit_per_window)
    positive!(c.rate_limit_window_ms, :rate_limit_window_ms)

    # The lower end keeps the sharing honest - one bucket would meter the whole
    # internet together - and the upper end keeps the table small enough that
    # the per-window sweep stays trivial.
    in_range!(c.rate_limit_buckets, 16..1_048_576, :rate_limit_buckets)

    positive!(c.mount_dedup_ttl_ms, :mount_dedup_ttl_ms)
    in_range!(c.max_mount_dedup_entries, 1..1_000_000, :max_mount_dedup_entries)
    boolean!(c.eagain_backoff, :eagain_backoff)
    positive!(c.max_datagram, :max_datagram)
    positive!(c.max_io, :max_io)
    positive!(c.max_response_payload, :max_response_payload)
    positive!(c.session_timeout_ms, :session_timeout_ms)
    positive!(c.max_sessions, :max_sessions)
    positive!(c.max_sessions_per_ip, :max_sessions_per_ip)
    positive!(c.max_path_length, :max_path_length)
    positive!(c.max_dir_scan, :max_dir_scan)
    positive!(c.max_ignore_patterns, :max_ignore_patterns)
    positive!(c.max_ignore_bytes, :max_ignore_bytes)
    boolean!(c.dir_ignore_file, :dir_ignore_file)

    # Handles travel as u8 on the wire and the compatible policy caps them well
    # below that (handoff section 7.2).
    in_range!(c.max_file_handles, 1..256, :max_file_handles)
    in_range!(c.max_dir_handles, 1..256, :max_dir_handles)
    in_range!(c.server_version, 0..0xFFFF, :server_version)
    in_range!(c.retry_ms, 0..0xFFFF, :retry_ms)
    in_range!(c.chmod_mask, 0..0xFFFF, :chmod_mask)

    one_of!(c.transports, Tnfs.Transports.modes(), :transports)
    boolean!(c.read_only, :read_only)
    boolean!(c.strict_decode, :strict_decode)
    boolean!(c.chmod_enabled, :chmod_enabled)
    boolean!(c.atari_mode, :atari_mode)

    one_of!(c.symlinks, [:deny], :symlinks)
    # Single-valued like `symlinks` and `legacy_open`: the field records the
    # decision and refuses an operator who configures something this server
    # does not do. `:drop` used to be accepted and then ignored, which is worse
    # than not offering it (handoff section 14.1, ADR 3).
    one_of!(c.sid_ip_mismatch, [:ebadsession], :sid_ip_mismatch)
    one_of!(c.seq_conflict, [:eproto, :execute_new], :seq_conflict)
    one_of!(c.legacy_open, [:disabled], :legacy_open)

    if c.atari_mode do
      raise ArgumentError,
            "atari_mode is not implemented: the ATR size and boot sector constants " <>
              "are not defined by the handoff"
    end

    # The wire limits have to agree with each other, and the place to find out
    # is here rather than at the first request that does not fit. All three are
    # independently configurable, so any of them can be set to a value that
    # silently breaks a command.

    # A response is a 4 byte header plus the status byte plus the payload.
    if c.max_response_payload + 5 > c.max_datagram do
      raise ArgumentError, "max_response_payload + 5 must not exceed max_datagram"
    end

    # A READ success payload is a u16 length followed by the data, so a full
    # `max_io` read has to fit. Otherwise the largest read the server offers is
    # one it can never answer.
    if c.max_io + 2 > c.max_response_payload do
      raise ArgumentError, "max_io + 2 must not exceed max_response_payload"
    end

    # Every fixed-size reply the command table describes must fit as well. STAT
    # is the widest at 22 bytes; a READDIRX chunk needs 19 for its header and a
    # one byte name. Below either, the command is dead rather than degraded.
    floor = max(Tnfs.Command.largest_fixed_response(), Tnfs.Directory.min_response_payload())

    if c.max_response_payload < floor do
      raise ArgumentError, "max_response_payload must be at least #{floor}"
    end

    # One datagram of leftover plus one datagram delivered. Below that a legal
    # request that arrived split across two reads could trip the bound it is
    # supposed to be protected by.
    if c.max_tcp_buffer < 2 * c.max_datagram do
      raise ArgumentError, "max_tcp_buffer must be at least twice max_datagram"
    end

    if not is_nil(c.root) and not is_binary(c.root) do
      raise ArgumentError, "root must be a path string or nil, got: #{inspect(c.root)}"
    end

    c
  end

  defp positive!(value, _key) when is_integer(value) and value > 0, do: :ok
  defp positive!(value, key), do: bad!(key, value, "a positive integer")

  defp in_range!(value, range, key) when is_integer(value) do
    if value in range, do: :ok, else: bad!(key, value, "an integer in #{inspect(range)}")
  end

  defp in_range!(value, range, key), do: bad!(key, value, "an integer in #{inspect(range)}")

  defp boolean!(value, _key) when is_boolean(value), do: :ok
  defp boolean!(value, key), do: bad!(key, value, "a boolean")

  defp one_of!(value, allowed, key) do
    if value in allowed, do: :ok, else: bad!(key, value, "one of #{inspect(allowed)}")
  end

  defp bad!(key, value, expected) do
    raise ArgumentError, "#{key} must be #{expected}, got: #{inspect(value)}"
  end
end
