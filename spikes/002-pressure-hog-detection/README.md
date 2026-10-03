# 002: pressure-and-hog-detection — Verdict: VALIDATED

Question: Given Linux on Omarchy, can we reliably detect (a) imminent memory
exhaustion and (b) which apps are the hogs, cheaply enough for a daemon?

## Evidence (verified live on this box, 2026-10-03)

- PSI is active: `/proc/pressure/memory` exposes `some`/`full` stall averages
  (avg10/avg60/avg300). This is the same signal Android lmkd and
  systemd-oomd use.
- `MemAvailable` in /proc/meminfo is the coarse fallback threshold.
- Per-process hog ranking works from /proc:
  - `VmRSS` from /proc/<pid>/status — cheap, per-poll.
  - PSS from /proc/<pid>/smaps_rollup — accurate shared-mem accounting
    (sample: chrome rss=1.2G/pss=1.3G, libkrun VM rss=1.7G/pss=5.9G).
- systemd-oomd is packaged but DISABLED on this box → no conflict; our daemon
  owns the policy. oomd only kills anyway — it has no freeze mode.

### Policy sketch
- Trigger: `some avg10 > 5` (or MemAvailable < 5% total) sustained ~1s.
- Candidates: user-owned `app-*.scope` sorted by summed PSS, excluding the
  focused window's app, Hyprland, quickshell, pipewire, terminals with
  foreground jobs, and the plugin's own service.
- Freeze biggest-first until pressure drops or N apps frozen, then open dialog.
- Re-trigger loop: after RESUME/CONTINUAR, keep polling; if pressure is still
  critical and nothing was closed, dialog reappears (exactly the
  Windows/macOS behavior requested).

### Recommendation
Poll PSI every 250–500 ms from a small systemd user service
(PartOf=graphical-session.target). Publish state to the QML plugin via a
state.json + file watch (proven pattern from omarchy-audio-background).
