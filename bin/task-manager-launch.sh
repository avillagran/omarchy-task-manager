#!/bin/sh
# Runs the Task Manager engine built from this checkout's Rust source
# (bin/task-manager-rs). No prebuilt binary ships with the plugin: build it
# with bin/task-manager-build.sh. Exits 127 when it has not been built yet,
# so the card can say so instead of failing silently.
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENGINE="$DIR/task-manager-rs/target/release/task-manager"
if [ ! -x "$ENGINE" ]; then
  echo "task-manager: engine not built; run $DIR/task-manager-build.sh" >&2
  exit 127
fi
exec "$ENGINE" "$@"
