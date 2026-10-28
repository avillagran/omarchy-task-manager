# Task Manager

![The Task Manager card: apps and background groups with CPU sparklines coloured by load, the governor holding back a background process, and the activity graph](preview.png)

Your Omarchy bar gains a kill switch for RAM hogs. When memory runs out,
apps freeze in place — greyed out, under the watchful eye of a blinking Omi —
while the kernel squeezes their idle pages into compressed RAM. Click, and
they come back like nothing happened.

## The fun parts

- **Pause any app.** One click (or `Space`) freezes a whole app family. CPU
  drops to zero on the spot, and the row (or an optional grey veil over its
  window, with the app's name on a green badge) tells you it is paused.
- **It watches while you don't.** The engine reads memory pressure every
  two seconds and auto-pauses the greediest apps before the desktop seizes
  up. You get a notification, not a lockup. Gear → Watchdog turns it off.
- **Frozen apps hand their RAM back.** While frozen, a temporary
  `memory.high` cap lets the kernel reclaim the app's cold pages, into
  compressed RAM on Omarchy's zram swap. Paused apps stop costing you
  memory, not just CPU.
- **You set the limits.** Gear → max RAM% before the watchdog bites,
  optional CPU ceiling, bar display, sparklines. Sane defaults, your call.
- **Hunt single browser tabs.** Expand any app's process tree and pause or
  kill one renderer — that one tab eating 2 GB — while the rest of the
  browser never notices.
- **Kill what won't die.** The crosshair button (or `K`) is xkill for
  Wayland: the card steps aside and the next window you click is killed by
  Hyprland itself (`Esc` cancels). Row kills escalate too: SIGTERM, then
  SIGKILL 2.5 s later for anything still alive.
- **Unstick the shell.** The reset button runs `omarchy-restart-shell`.
  Hold `SUPER` (or press it just before clicking) and it turns into a red
  bolt: the forced reset, for a shell too wedged to answer its own restart.
- **No fake "not responding" dialogs.** Hyprland's ANR popup is silenced
  exactly while a pause is ours, and restored the moment nothing is frozen.
- **Real numbers, live.** Bar pill (icon / numbers / numbers + graphs),
  per-row CPU sparklines on a fixed 0–100% scale whose bars take the CPU
  column's colours (so a past spike still shows), full CPU/RAM history with
  per-core detail, and a System section showing what the daemons are up to.
  Per-app CPU is % of one core, like `top`.
- **Keyboard first.** `↑↓` select, `Enter` focus, `Space` pause, `X` kill,
  `→` tree, `K` click-kill, `G` graphs, `D` cores, `B` bar mode, `R` refresh,
  `Esc` close. A legend line at the bottom of the card lists them all.
- **A list you can scan.** App icons, a RAM bar coloured by how full memory
  is, CPU and RAM in aligned columns that warm up with load, click a column
  title to sort, `/` to filter by name or PID, and quick filters (paused,
  CPU ≥ 5%, RAM ≥ 500 MB).
- **Speaks your language.** EN, ES, PT, FR, DE, following your Omarchy
  locale.

## Requirements

- Omarchy (Hyprland + the Omarchy shell) on cgroup v2.
- Nothing to install for the **light engine**: it runs on the system's
  `/usr/bin/python3` (stock on Omarchy), standard library only.
- Optional, for the **full engine**: Rust (`cargo`). On Omarchy: menu →
  Install → Development → Rust. The engine has no third-party crates.

## Install

```sh
omarchy plugin add https://github.com/avillagran/omarchy-task-manager --enable
```

Then put the widget on the bar from the Omarchy shell settings (or
`omarchy bar put io.github.avillagran.omarchy-task-manager --section right`).

The plugin ships **source only**, no prebuilt binary, and two engines that
speak the same commands and JSON:

| | Light (Python) | Full (Rust) |
|---|---|---|
| Needs | nothing (stock `python3`) | `cargo`, builds locally |
| List, pause/resume, kill, tree, veils | yes | yes |
| Pressure safety net (auto-pause) | yes | yes |
| Memory governor | yes | yes |
| Per-app CPU % | while the card is open | always |
| Watch, resident | ~17 MB; ~0.05% CPU while memory is calm, ~0.3% while the governor works | ~3 MB, ~1% CPU |

The card starts on the light engine at once. Unless you chose Light in the
gear panel, it also runs `bin/task-manager-build.sh`
(`cargo build --release --locked --offline` on `bin/task-manager-rs`; the
first time about a minute, later an incremental check) and switches to the full engine
when it builds. Without `cargo`, or if the build fails, it stays on the
light engine and the gear panel says why. Nothing is downloaded.

## Remove

```sh
omarchy plugin remove io.github.avillagran.omarchy-task-manager --yes
```

Removing or disabling the plugin stops the engine with the shell's widget:
it resumes every app it paused and drops every memory limit it set before
exiting. What stays behind, all yours to delete:

- `~/.local/state/omarchy-task-manager/` (preferences and card size)
- `~/.cache/omarchy-task-manager/` (the light engine's bytecode cache)
- any extra you applied from the gear panel: press **Remove** there first, or
  delete `~/.config/hypr/task-manager-*.lua` and their `require("hypr.task-manager-…")`
  lines in `hyprland.lua`

## What it touches

- **Reads:** `/proc`, `/sys/fs/cgroup` (your own user slice), memory
  pressure (PSI), and Hyprland's IPC socket.
- **Writes:** `cgroup.freeze`, `memory.high` and `memory.reclaim` inside
  your own user slice; its preferences in
  `~/.local/state/omarchy-task-manager/`; history, locks and runtime state
  in `$XDG_RUNTIME_DIR/omarchy-task-manager/` (gone at logout). Both are
  private (mode 0700), written atomically, and no symlink is followed.
- **Never:** your Hyprland or Omarchy config, your browser profiles, files
  outside those two directories, or the network. No root, no elevated
  helper, no background service: the engine is a child of the shell and
  dies with it.
- **Signals** go only to your own processes, through pidfds checked against
  the process start time, so a recycled PID can never be hit.

## How the pause works

Omarchy apps run in user scopes on cgroup v2. Freezing sets
`cgroup.freeze=1` (a SIGSTOP fallback covers strays), so a paused app burns
exactly 0 CPU. RAM reclaim is the kernel's own machinery (`memory.high`
plus compressed swap), and thaw restores everything in place. Kill always
thaws first: frozen processes can't handle SIGTERM.

Apps paused automatically by the watchdog resume automatically, one at a
time, after **10 continuous seconds** of healthy resources. Available RAM
must exceed both the recovery margin (12% by default) and 1.5 times the
critical margin, with memory PSI `some < 10` and `full < 1`. If the CPU
watchdog is enabled, CPU use must also fall 10 percentage points below its
limit. Any relapse restarts the wait; each resumed app gets another
10 seconds of observation before the next app resumes.

Only stops recorded by the current watchdog are eligible; existing manual
pauses remain paused. A manual resume or an exited process is removed from
the recovery queue. After automatic resume, the app can be paused again if
critical pressure returns for the usual 5 seconds (its old 10-minute
freeze cooldown is cleared). Both engines use the same policy. You can
still resume an app immediately from the card.

## Optional extras (in the gear panel, always asked first)

Nothing is written to your Hyprland config behind your back. **Apply** in
the gear panel opens a terminal (`bin/task-manager-configure.sh`) that
explains the change, shows the exact lines and asks; only a "yes" writes
anything. For each extra it creates one file of its own,
`~/.config/hypr/task-manager-<extra>.lua`, and adds one
`require("hypr.task-manager-<extra>")` line to `hyprland.lua`, after saving
a backup copy next to it (`hyprland.lua.task-manager-backup-<date>`). It
refuses symlinked files (dotfiles managers) and runs nothing as root.
**Remove** undoes both the same way. Hyprland reloads on its own; the panel
reads the binds back from Hyprland. You can also add the lines yourself:

- **Show window shortcut**, `SUPER+SHIFT+T`:

  ```lua
  hl.unbind("SUPER + SHIFT + T")
  o.bind("SUPER + SHIFT + T", "Task Manager", "omarchy-shell shell toggle io.github.avillagran.omarchy-task-manager")
  ```

- **Force shell reset shortcut**, `SUPER+CTRL+SHIFT+Delete`, the closest
  thing to CTRL+ALT+DEL that Omarchy leaves free. Hyprland runs it, so it
  works even when the shell is too frozen to click anything. It runs the
  light engine, so it works with or without Rust:

  ```lua
  o.bind("SUPER + CTRL + SHIFT + Delete", "Force reset shell", "<plugin dir>/bin/task-manager-light.sh shell-reset force")
  ```

- **Veils over paused windows.** The grey veil is a real floating window
  stacked over the frozen one, and it needs this window rule to open
  floating and undecorated. Apply it, then turn **Veils** on in the panel:

  ```lua
  hl.window_rule({
    name = "tm-veil-base",
    match = { class = "^org.quickshell$" },
    float = true,
    no_initial_focus = true,
    no_anim = true,
    border_size = 0,
    no_shadow = true,
    no_follow_mouse = true,
    decorate = false,
  })
  ```

## Memory governor

The watchdog's freeze is the last resort. Before that point, the governor
(part of the same engine, every 2 s) keeps the desktop fluid the way macOS
does, using cgroup v2 knobs on the user's own delegated subtree (no root):

| Level | When | What |
|---|---|---|
| calm | ≥ 30% RAM available | limits loosen gradually, then are removed |
| elevated | < 25% available (or stalls with < 33%) | windowless scopes (agents, builds, test runners) get a `memory.high` a few % below their size each tick, so they reclaim their own pages and slow down instead of evicting your apps; windowed apps unfocused for 2+ min hand cold pages to zram in small `memory.reclaim` chunks |
| critical | < 12% available | the same, harder; windowless services are limited too |

Never touched: the session (Hyprland, the shell), audio, the focused app,
anything frozen. A limited group that stalls on its own memory gets its
limit loosened, never squeezed into a livelock. Every limit is restored when
pressure clears, when the engine stops, and at the next start if it was
killed. The card lists what is being held back.

## When the shell itself is stuck

The reset button (`task-manager-launch.sh shell-reset`) is the normal
restart (`omarchy-restart-shell`). The forced reset (`shell-reset force`)
SIGKILLs, in order: the shell's supervisor (`omarchy-launch-shell`, which
would otherwise relaunch a second shell), every quickshell process of the
Omarchy shell config (the instance and any hung `qs ipc` clients), any
stuck `omarchy-restart-shell`, and the helpers the shell spawned, then
starts a fresh shell. Apps opened from the launcher (their own scopes)
survive, and so do quickshell instances of other configs.
`shell-reset list` prints what `force` would kill, killing nothing.

The reset first moves into its own session, since the button lives in the
shell being restarted. If the shell is so frozen that its buttons don't
respond, use the `SUPER+CTRL+SHIFT+Delete` extra above.

## zswap vs zram

Omarchy swaps to zram (compressed RAM), so the card stays quiet about zswap.
Only on a machine whose swap is a plain disk does the card suggest turning
zswap on (see the Arch Wiki page "Zswap"); it never changes it for you.

## Development note: `import QtQuick 6.11`

Every QML file imports `QtQuick 6.11` (and `QtQuick.Window 6.11`), never the
unversioned module. Qt 6.12 added a `QtQuick` `Color` singleton that shadows
`Color` from Omarchy's `qs.Commons`, leaving theme colors `undefined`
(white surfaces, black text, `Cannot read property 'background' of
undefined`). An unversioned `import QtQuick.Window` re-imports the latest
QtQuick and brings the problem back. New files must use the pinned import.

## Layout

    manifest.json
    BarWidget.qml                  bar pill + native movable window + veils
    Shared.js                      in-memory state shared by widget instances
    ActivityGraph.qml, OmiFace.qml graph and mascot
    i18n.json                      EN/ES/PT/FR/DE
    bin/task_manager_light.py      light engine (Python standard library)
    bin/task-manager-light.sh      runs it: python3 -I -S, bytecode cached in ~/.cache
    bin/task-manager-configure.sh  gear panel Apply/Remove: explains, asks, then edits ~/.config/hypr
    bin/task-manager-build.sh      offline, locked cargo build of the full engine
    bin/task-manager-launch.sh     runs the built full engine
    bin/task-manager-rs/           Rust engine source (no dependencies)
    tests/test_light_engine.py     python3 -I tests/test_light_engine.py

## License

MIT, see [LICENSE](LICENSE).

## Credits

- **Omi**, the mascot blinking over your paused apps, was an idea by
  [@tahayvr](https://github.com/tahayvr). The vector path comes from the
  official Omarchy brand assets.

### Pause notices and moving the panel

Automatic pause notices show the application's desktop icon with a pause badge.
The notice closes when all stops owned by that pause clear, including automatic
recovery and manual resume. A partial or failed resume keeps it visible. Closing
the watchdog also releases its notices; no notification-ID files are stored.
Both engines share `bin/pause-notification.py` (stock Python, `notify-send` and
`gdbus`). ImageMagick (`magick`) renders the badge in a private temporary directory;
if rendering or icon lookup is unavailable, the notice uses the themed app icon
and its explicit paused summary. Temporary images are removed after closure.

The panel is a native window: drag its header, use the compositor's move shortcut,
or resize it across monitors. Its size is saved after resizing. It follows normal
window stacking and workspace behavior. It no longer captures a monitor-wide
layer surface. CPU/RAM icons, percentages and bar graphs share the panel's usage
colors: green below 50%, yellow from 50%, orange from 75%, red from 90%.

The local Omarchy notification service can preserve the temporary icon across
reloads via the optional `x-omarchy-app-icon-path` hint. The service must remove
the visible card on the sender's `CloseNotification`, as well as drop its actions;
otherwise a completed pause leaves a stale toast despite a successful close.

### Rust builds and live reload

Rust still builds automatically on first use and after source updates, offline
and locked. Cargo output lives exclusively in
`${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-task-manager/rust/<installation-id>/`.
Both the build and launch scripts share the same cache resolver; separate source
installations have separate output directories. Cache subdirectories are private
(0700), and symlinks are refused. A cache configured inside a plugin falls back
to the normal user cache to avoid triggering live reload.

No build artifacts, lock files or Python bytecode are written under the installed
plugin. Existing `bin/task-manager-rs/target` artifacts are ignored and need not
be deleted or rebuilt by hand. Removing the Rust cache frees the build outputs;
the plugin automatically rebuilds on its next load. The Python fallback remains
available when Cargo is missing or a build fails.
