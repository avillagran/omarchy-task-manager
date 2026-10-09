# Browser extension integration — research notes

Goal: show real per-tab information (Chrome tab titles) in the plugin, and
fix the omarchy-mailbox marketplace submission, which is stuck on the same
extension-installation problem.

## Why the OS alone cannot provide tab titles

- Chrome renders each tab in a renderer subprocess, but `/proc/<pid>/cmdline`
  for every child only carries `--type=renderer|gpu-process|utility|...`.
  All children share the parent's `comm` ("chrome"). Nothing in `/proc` maps
  a renderer pid to a tab title.
- Chrome DevTools Protocol (`--remote-debugging-port`) would enumerate tabs,
  but Chrome ≥136 refuses CDP on the default profile directory, and enabling
  it exposes the whole browser (cookies, sessions) to any local process.
  Not acceptable as a silent default.
- Conclusion: tab data must come from INSIDE the browser → an extension.

## The proven pattern (omarchy-mailbox, live on this machine)

MV3 extension + Native Messaging host, all user-scoped:

- `bridge-extension/source/manifest.json`: permissions
  `["nativeMessaging", "tabs", "scripting", "alarms"]`, plus a stable
  `key` (fixes the extension ID `kjmlhpck…` across installs).
- `bin/mailbox-bridge-host.js`: Node native host (stdio, 4-byte LE length
  prefix + JSON). Receives data from the extension and writes an atomic,
  mode-0600 cache under `~/.cache/omarchy/mailbox/`.
- `bin/mailbox-bridge-install.js`: registers
  `~/.config/{google-chrome,chromium,BraveSoftware/*}/NativeMessagingHosts/io.github.avillagran.mailbox.json`
  with an absolute executable `path` and exact `allowed_origins`.
  Hardened: `lstat` symlink/hardlink/owner checks on every touched path,
  exclusive `O_NOFOLLOW` temp file + atomic rename, idempotent, narrowly
  scoped uninstall. **This file is the reference implementation for any
  user-scoped host registration.**
- Live proof: `~/.config/google-chrome/NativeMessagingHosts/io.github.avillagran.mailbox.json`
  exists and Gmail unread works today with zero root involvement.

## What an extension can give the task manager

- `chrome.tabs.query({})` → every tab in every window: `id, windowId,
  title, url, active, groupId`. Grouped by `windowId` this yields the full
  tab list per Chrome window (today we only have the ACTIVE tab per window,
  from Hyprland's window title).
- `chrome.processes.getProcessInfo()` → tab↔process mapping, but with
  Chrome-INTERNAL process ids, not OS pids. **Mapping a row in the
  subprocess list to a specific tab remains impossible.** The honest UX is:
  window titles + full tab list per browser window, plus role labels
  (renderer/gpu/network) for OS subprocesses.
- A minimal "Task Manager Tabs" extension would be ~40 lines: on tab
  events (created/removed/updated/activated/moved) send the full
  `chrome.tabs.query` result to a native host
  `io.github.avillagran.taskmanager`, which writes
  `~/.cache/omarchy/task-manager/tabs.json`; the Rust helper merges it into
  `state` (per chrome-family app: `tabs: [...]`).

## Extension installation paths on Linux (trade-offs)

1. **Guided unpacked (rootless, manual)** — register the native host, then
   the user does chrome://extensions → Developer mode → Load unpacked once.
   Mailbox's current default. Works everywhere, but manual friction and no
   auto-update.
2. **Chromium flags file (rootless, automatic on Chromium only)** — append
   `--load-extension=<path>` to the user's `chromium-flags.conf`. Chrome
   and Brave do not read that file, so it is not a general solution.
3. **System external CRX (privileged, automatic on Chrome)** — root-owned
   signed CRX + registration JSON in `/opt/google/chrome/extensions/`.
   Auto-installs, but every byte that crosses the privilege boundary must
   be sealed/pinned (mailbox has a polished pkexec + sealed-memfd
   prototype). This privileged surface is EXACTLY what stalls marketplace
   review (see below).
4. **Chrome Web Store, unlisted (recommended)** — upload the extension zip
   once; the listing stays unlisted. The plugin's "Install in browser"
   button just opens the CWS URL. One click, auto-updates, works in
   Chrome/Brave/Edge. The extension ID is preserved because the manifest
   already carries its `key`. The plugin then contains ZERO privileged
   code — nothing for the marketplace scanner to escalate. Google's CWS
   review is a separate, standard gate and does not involve Omarchy.

## Mailbox marketplace status (measured 2026-10-06)

Local preflight (`omarchy-plugin-validate` + official security-baseline
scanner, `~/Work/omarchy-plugins/marketplace-preflight.sh`):

- **Compatibility validation: PASS** (no findings).
- **Scanner outcome: `review-required`** — triggered by the *privilege*
  capability:
  - `Panel.qml:147` and `:197` run `pkexec root.bridgeSystemInstallBin`
    (the system-CRX install/uninstall buttons).
  - `README.md` documents the pkexec flow (`/opt/google/chrome/extensions/`).
  - Plus the ordinary *installer* capability (`bin/mailbox-bridge-install.js`,
    `bin/mailbox-bridge-system-install.sh`) — expected for any plugin with
    setup code; not a blocker by itself.
- Manual-review grep candidates in the preflight log are false positives
  (regex matches in comments; pid-suffixed temp files that are atomically
  renamed).

### Recommended mailbox fix

Remove the privileged path from the submitted commit — delete
`Panel.qml`'s two pkexec buttons, `bin/mailbox-system-extension.py`,
`bin/mailbox-bridge-system-install.sh`, `bridge-extension.crx` and
`bridge-extension.pem` (keep the PEM out of git entirely). Keep the
rootless native-host registration + guided unpacked install, or replace
the guided flow with the CWS listing for a one-click install. The scanner
then sees no privilege boundary and the submission should pass with only
the standard installer review. If the system-CRX prototype is kept for
local experiments, it must live outside the submitted tree (separate
branch/repo), never in the reviewed commit.
