#!/bin/sh
set -eu

base_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export MIX_ENV=${MIX_ENV:-prod}

if [ "$#" -gt 1 ]; then
  echo "usage: $0 [export-directory]" >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  export TNFS_ROOT=$1
elif [ -z "${TNFS_ROOT:-}" ]; then
  echo "usage: $0 <export-directory>" >&2
  echo "or set TNFS_ROOT in the environment" >&2
  exit 2
fi

if [ ! -d "$TNFS_ROOT" ]; then
  echo "export directory does not exist or is not a directory: $TNFS_ROOT" >&2
  exit 2
fi

cd "$base_dir"
exec mix run --no-halt
