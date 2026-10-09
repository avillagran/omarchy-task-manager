#!/bin/sh
# Arch launcher: selects the prebuilt task-manager binary for this machine.
# When Chrome invokes us as a Native Messaging host, argv[1] is the
# extension origin (chrome-extension://...) — map that to `tabs-host`.
case "${1:-}" in
  chrome-extension://*) set -- tabs-host ;;
esac
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  exec "$DIR/task-manager-x86_64"  "$@" ;;
  aarch64|arm64) exec "$DIR/task-manager-aarch64" "$@" ;;
  *) echo "task-manager: unsupported arch: $ARCH" >&2; exit 1 ;;
esac
