# 001: freeze-resume-via-cgroups — Verdict: VALIDATED

Question: Given a user app in its own systemd scope, when memory pressure is
critical, can we atomically pause and resume the whole app without root?

## Evidence (verified live on this box, 2026-10-03)

- cgroup v2 (`cgroup2fs`), systemd 262, `cgroup.freeze` delegated to the user.
- Apps are launched in per-app scopes by UWSM:
  `app-Hyprland-google\x2dchrome\x2dstable-*.scope`, `app-com.google.Chrome-11674.scope`, ...
- Live test: CPU spinner in a throwaway scope:
  - RUNNING: utime delta 149 jiffies / 1.5s (~100% CPU)
  - `systemctl --user freeze tm-spin4.scope` → rc=0, `cgroup.freeze=1`
  - FROZEN: utime delta 0 — fully stopped by the kernel freezer
  - `systemctl --user thaw` → rc=0
  - THAWED: delta 149 again — clean resume, process kept its full state
- No root, no polkit: the user owns `user@1001.service/app.slice`.

### What worked
- Atomic freeze of ALL processes of an app (vs SIGSTOP per-PID races).
- Frozen processes keep their RSS/state — resume is instant and lossless.

### What didn't / caveats
- Apps launched from a terminal share the terminal's scope — freezing the
  scope would freeze the terminal. Fallback: SIGSTOP/SIGCONT per-PID, or skip
  those apps. V1: only freeze dedicated `app-*.scope` units.
- `systemd-run --user --scope` is SYNCHRONOUS (blocks until exit). Launch it
  backgrounded when scripting tests.

### Recommendation for the real build
Freeze = `systemctl --user freeze <unit>`; resume = `thaw`; close =
`systemctl --user kill --signal=TERM <unit>` (then KILL after grace period).
Map scope → windows via the scope's cgroup.procs ∩ `hyprctl clients -j` pids.
