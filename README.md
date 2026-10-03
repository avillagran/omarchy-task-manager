# Omarchy Task Manager

Freeze/resume memory-hogging apps from the Omarchy bar, Windows/macOS style:
when RAM runs out, apps pause, their windows go grey, and a dialog lets you
resume or close them.

## Features

- Bar pill (tasks glyph) with red badge = number of paused apps; three modes
  cycled from the card: icon only (shrinks to natural bar size) / fixed-width
  CPU+RAM percentages (chip + DIMM icons, no layout jitter) / percentages
  with separate CPU and RAM sparklines.
- Click -> draggable AND resizable overlay card (grip at bottom-right,
  geometry persisted) above ALL windows, on EVERY workspace. Pinned mode
  shrinks the input region to the card: clicks pass through to windows
  below.
- Windowed apps sorted by RAM (toggle: CPU, name), each row shows live CPU%
  next to the name, expandable process tree (whole comm family, including
  background scope-mates), and a small RSS sparkline (opt-in).
- Background apps (no window) grouped by comm with pause AND kill.
- Pause (cgroup freezer or SIGSTOP fallback) + automatic RAM squeeze
  (memory.high -> kernel reclaims cold pages to zswap/swap); grey veil over
  each paused window; Resume / Close per row; Resume all / Continue footer;
  resuming focuses the app's window.
- Status strip: free RAM, PSI, paused count and swap usage (when > 50 MB).
- Memory-pressure watchdog (systemd user service): when available RAM drops
  below 6% (or PSI some avg10 > 10), it freezes the biggest non-focused app,
  waits, re-checks (max 3 per episode) and sends a localized desktop
  notification. The dialog auto-opens while pressure is critical;
  "Continuar" dismisses it and it reopens after 60s if nothing was freed.
- Activity section (collapsible): historical CPU + RAM graph from the
  watchdog's ring buffer; detail toggle draws per-core CPU lines in a
  separate mini-graph with its own scale. GPU is shown when the platform
  exposes utilization (not on Asahi).
- Full i18n (en/es/pt/fr/de), follows the system language.
- Keyboard navigation (unpinned card grabs the keyboard; pinned never does):
  ↑/↓ move through windowed apps AND background rows, →/← expand/collapse
  the process tree, Enter focuses the app, Space/P pause-resume, X/Delete
  kill, G graphs, D per-core detail, B cycles the bar pill mode, R refresh,
  Esc close. A legend line at the card bottom lists the keys.
- Optional SUPER+SHIFT+T global toggle (OPT-IN — the keyboard icon in the
  card header writes the hyprland lua bind; install.sh never touches your
  hyprland.lua). It drives `omarchy-shell shell toggle <full-plugin-id>`.
- Paused apps get a grey translucent veil exactly over their window
  (persistent per-screen layer surface, click-through; panels opened later,
  like X-Panel, render above it) with the vector Omarchy mascot on top —
  official brand path + two animated eyes that blink (both eyes, then
  staggered left/right, then a full eye-roll).
- Hyprland's "Application Not Responding" dialog never fires for apps WE
  froze: while anything is paused, misc:anr_missed_pings is raised at runtime
  (hyprctl eval, no config files touched) and restored on the last thaw.
- Subprocess control in the tree: every expanded thread row has pause and
  kill buttons acting on that pid ONLY (signal-based, never the scope), so a
  single hung browser tab/renderer can be stopped or closed (the tab shows
  the browser's crash page) without touching the rest of the family.
- Freeze = `systemctl --user freeze <app-scope>` (cgroup v2 freezer, no root,
  atomic, 0 CPU while frozen). RAM squeeze while frozen: `memory.high`
  lowered so the kernel reclaims cold pages; with zswap enabled they are
  compressed in RAM (~2-3x) instead of hitting disk.
- zswap detection: if compression is off, the dialog shows a banner with the
  exact command to enable it (+ copy button).
- Kill = thaw + SIGTERM (frozen processes can't handle signals).

## Install

    omarchy plugin add https://github.com/avillagran/omarchy-task-manager --enable --yes
    ~/.config/omarchy/plugins/io.github.avillagran.omarchy-task-manager/install.sh

Or the one-liner (does both):

    curl -fsSL https://raw.githubusercontent.com/avillagran/omarchy-task-manager/main/install.sh | bash

Uninstall (stops the watchdog, thaws everything paused, removes the unit;
user data is never touched):

    bash ~/.config/omarchy/plugins/io.github.avillagran.omarchy-task-manager/install.sh --uninstall

## Optional: zswap (compressed RAM)

Without zswap, squeezed memory goes straight to disk. Enable it once:

    sudo sh -c 'echo Y > /sys/module/zswap/parameters/enabled'

Persist across reboots:

    echo "w /sys/module/zswap/parameters/enabled - - - - Y" | sudo tee /etc/tmpfiles.d/zswap.conf

The dialog detects this and shows the commands if missing.

## Layout

    manifest.json
    BarWidget.qml                  bar pill + overlay dialog + veils
    install.sh                     idempotent installer (--local, --uninstall)
    systemd/omarchy-task-manager.service   watchdog unit template
    bin/task-manager-launch.sh     arch launcher
    bin/task-manager-keybind.sh    opt-in SUPER+SHIFT+T bind manager
    bin/task-manager-aarch64       prebuilt (ARM/Asahi)
    bin/task-manager-rs/           Rust crate (cargo build --release)
    spikes/                        feasibility evidence

## Resource cost (measured)

- Helper: ~5 ms per `state` call (Rust, ~500 KB). Watchdog: 2 reads/500 ms.
- Poll: 15 s idle, 2 s while dialog open or any app paused.

## Roadmap

- x86_64 prebuilt binary (build on an x86_64 Omarchy box).
- Marketplace submission.
