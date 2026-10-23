#!/bin/sh
# Runs the Task Manager light engine (bin/task_manager_light.py) on the
# stock Python runtime: nothing to build or download. -I -S: isolated mode,
# no user site-packages, no environment-driven imports; the module is
# imported from this directory only, and its bytecode cached under the
# user's cache dir (not in the plugin) so each call skips recompiling it.
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-task-manager/pycache"
# The module path stays on the command line so `ps` (and the shell reset's
# own process scan) can tell this engine apart.
exec /usr/bin/python3 -I -S -X pycache_prefix="$CACHE" -c '
import os, sys
sys.path[:0] = [os.path.dirname(sys.argv.pop(1))]
import task_manager_light
task_manager_light.run()
' "$DIR/task_manager_light.py" "$@"
