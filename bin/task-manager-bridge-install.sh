#!/usr/bin/env bash
# Register/unregister the user-scoped Native Messaging host for the
# "Omarchy Task Manager Tabs" extension. Rootless: only touches
# ~/.config/<browser>/NativeMessagingHosts/. Idempotent; safe to re-run.
#
# Hardening (same pattern as omarchy-mailbox): lstat guards reject
# symlink/hardlink/foreign-owner targets, writes go to a pid-suffixed
# temp file and are atomically renamed.
set -euo pipefail

HOST_NAME="io.github.avillagran.taskmanager"
EXT_ID="ebpgfpelbpepibjaffnpjgljkohpifoj"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SELF_DIR/task-manager-launch.sh"

check_owned() { # reject symlinks, hardlinks, foreign owners
  local p="$1"
  if [ -e "$p" ] || [ -L "$p" ]; then
    [ -L "$p" ] && { echo "refusing symlink: $p" >&2; exit 1; }
    [ "$(stat -c %h "$p")" -gt 1 ] && { echo "refusing hardlink: $p" >&2; exit 1; }
    [ "$(stat -c %u "$p")" != "$(id -u)" ] && { echo "refusing foreign owner: $p" >&2; exit 1; }
  fi
}

write_atomic() { # write_atomic <dest> — reads content from stdin
  local dest="$1" tmp
  check_owned "$dest"
  tmp="$dest.tmp.$$"
  cat > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$dest"
}

host_manifest() {
  cat <<EOF
{
  "name": "$HOST_NAME",
  "description": "Omarchy Task Manager tab bridge (local, read-only tab titles)",
  "path": "$BIN",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
EOF
}

browser_dirs() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
  for b in google-chrome chromium BraveSoftware/Brave-Browser microsoft-edge; do
    [ -d "$cfg/$b" ] && echo "$cfg/$b/NativeMessagingHosts"
  done
}

case "${1:-install}" in
  install)
    if [ ! -x "$BIN" ]; then
      echo "helper launcher missing or not executable: $BIN" >&2
      exit 1
    fi
    found=0
    for d in $(browser_dirs); do
      mkdir -p "$d"
      write_atomic "$d/$HOST_NAME.json" < <(host_manifest)
      echo "registered: $d/$HOST_NAME.json"
      found=1
    done
    [ "$found" = 0 ] && { echo "no supported browser config dir found" >&2; exit 1; }
    echo "native host registered (user scope). Load the extension once:"
    echo "  chrome://extensions → Developer mode → Load unpacked → $SELF_DIR/../bridge-extension/source"
    ;;
  uninstall)
    for d in $(browser_dirs); do
      if [ -f "$d/$HOST_NAME.json" ]; then
        check_owned "$d/$HOST_NAME.json"
        rm -f "$d/$HOST_NAME.json"
        echo "removed: $d/$HOST_NAME.json"
      fi
    done
    ;;
  status)
    for d in $(browser_dirs); do
      [ -f "$d/$HOST_NAME.json" ] && echo "registered: $d/$HOST_NAME.json"
    done
    ;;
  *) echo "usage: $0 [install|uninstall|status]" >&2; exit 1 ;;
esac
