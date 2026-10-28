#!/bin/sh
# Build reviewed local Rust source offline. All Cargo output goes to the private
# user cache, never into this plugin: Omarchy watches the plugin for live reload.
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec /usr/bin/python3 -I -S "$DIR/task-manager-runtime.py" build 2>&1
