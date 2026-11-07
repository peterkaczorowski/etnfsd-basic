# etnfsd-basic

Standalone TNFS server for FujiNet and other TNFS clients.

## Requirements

- Erlang/OTP 26 or newer
- Elixir 1.17 or newer
- `mix`

## Running

Fetch dependencies and compile the project:

```sh
mix deps.get
mix compile
```

Start the server by passing the directory to export:

```sh
./start.sh /srv/tnfs
```

The script sets `TNFS_ROOT` and starts the server in production mode. The
export path is not hard-coded in the source code.

The directory can also be supplied through the environment:

```sh
TNFS_ROOT=/srv/tnfs ./start.sh
```

By default the server listens on all addresses on port `16384`, using both UDP
and TCP. Common settings can be overridden without changing the source:

```sh
TNFS_LISTEN_ADDRESS=192.168.1.10
TNFS_PORT=16384
ETNFSD_TNFS_TRANSPORTS=udp-only   # or tcp-only, both
TNFS_READ_ONLY=true
```

The remaining limits are available as `TNFS_*` environment variables in
`config/runtime.exs`. The export path is always configured outside the source
code.

## Stopping

The server runs in the foreground. Stop it with `Ctrl-C` or send `SIGTERM` to
the process started by `start.sh`.
