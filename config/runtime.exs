import Config

if config_env() == :prod do
  bool = fn name, default ->
    case System.get_env(name) do
      nil -> default
      value when value in ["1", "true", "yes"] -> true
      value when value in ["0", "false", "no"] -> false
      value -> raise "#{name} must be true or false, got #{inspect(value)}"
    end
  end

  integer = fn name, default ->
    case System.get_env(name) do
      nil -> default
      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> raise "#{name} must be an integer, got #{inspect(value)}"
        end
    end
  end

  address = fn name, default ->
    case System.get_env(name) do
      nil -> default
      value ->
        case :inet.parse_address(to_charlist(value)) do
          {:ok, parsed} -> parsed
          {:error, _} -> raise "#{name} must be an IP address, got #{inspect(value)}"
        end
    end
  end

  config :etnfsd,
    root: System.get_env("TNFS_ROOT"),
    listen_address: address.("TNFS_LISTEN_ADDRESS", {0, 0, 0, 0}),
    port: integer.("TNFS_PORT", 16384),
    transports: Tnfs.Transports.resolve!(System.get_env()),
    read_only: bool.("TNFS_READ_ONLY", true),
    session_timeout_ms: integer.("TNFS_SESSION_TIMEOUT_MS", 600_000),
    max_sessions: integer.("TNFS_MAX_SESSIONS", 256),
    max_sessions_per_ip: integer.("TNFS_MAX_SESSIONS_PER_IP", 16),
    max_session_queue: integer.("TNFS_MAX_SESSION_QUEUE", 64),
    max_dir_scan: integer.("TNFS_MAX_DIR_SCAN", 100_000),
    max_tcp_connections: integer.("TNFS_MAX_TCP_CONNECTIONS", 64),
    tcp_frame_timeout_ms: integer.("TNFS_TCP_FRAME_TIMEOUT_MS", 10_000),
    tcp_connection_timeout_ms: integer.("TNFS_TCP_CONNECTION_TIMEOUT_MS", 600_000),
    max_tcp_buffer: integer.("TNFS_MAX_TCP_BUFFER", 1536),
    max_tcp_frames_per_batch: integer.("TNFS_MAX_TCP_FRAMES_PER_BATCH", 8),
    rate_limit_per_window: integer.("TNFS_RATE_LIMIT_PER_WINDOW", 100),
    rate_limit_window_ms: integer.("TNFS_RATE_LIMIT_WINDOW_MS", 1_000),
    rate_limit_buckets: integer.("TNFS_RATE_LIMIT_BUCKETS", 4096),
    mount_dedup_ttl_ms: integer.("TNFS_MOUNT_DEDUP_TTL_MS", 5_000),
    max_mount_dedup_entries: integer.("TNFS_MAX_MOUNT_DEDUP_ENTRIES", 4096)
end
