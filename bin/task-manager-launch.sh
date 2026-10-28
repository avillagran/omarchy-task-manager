#!/bin/sh
# Launch the engine built from this installation in the private user cache.
# No fallback to in-tree artifacts: they can be stale and recreate reload loops.
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec /usr/bin/python3 -I -S "$DIR/task-manager-runtime.py" launch "$@"
