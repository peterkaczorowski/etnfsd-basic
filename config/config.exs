import Config

# Defaults live in Tnfs.Config; only deliberate deviations belong here.
# The safe profile of handoff section 15 (loopback, read-only, symlinks denied,
# strict decoding, TCP off) is what you get when this file says nothing.

config :logger, level: :info

# Only `:disksup` is wanted from `:os_mon`, and only as a way to call the
# platform's filesystem size API. The CPU and memory supervisors would spawn
# port programs we have no use for, and the disk alarm would raise system
# alarms about a disk this server does not own.
config :os_mon,
  start_cpu_sup: false,
  start_memsup: false,
  start_os_sup: false,
  disk_almost_full_threshold: 1.0

if config_env() == :test do
  config :logger, level: :warning
end
