#!/bin/sh
# Builds the Task Manager engine from the Rust source in this checkout.
#
# The engine has no third-party crates, so the build is fully offline
# (--offline --locked): nothing is downloaded, and the binary always comes
# from the reviewed source next to it. Cargo rebuilds only when that source
# changed, so the card runs this on every shell start to keep the binary in
# step with plugin updates; an up-to-date tree costs a fraction of a second.
#
# Needs the Rust toolchain (cargo). On Omarchy: Install > Development > Rust.
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# rustup's default location: the shell's session PATH may not include it.
PATH="$PATH:$HOME/.cargo/bin"
if ! command -v cargo >/dev/null 2>&1; then
  echo "task-manager: cargo not found; install Rust (Omarchy menu: Install > Development > Rust)"
  exit 127
fi
# Diagnostics go to stdout: the card collects one bounded stream.
exec cargo build --release --locked --offline --quiet \
  --manifest-path "$DIR/task-manager-rs/Cargo.toml" 2>&1
