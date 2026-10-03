# 004: reclaim-ram-from-frozen-apps (v2) — Verdict: PARTIAL, deferred

Question: Can we actually FREE RAM from a frozen app without killing it, like
Windows does with suspended UWP apps?

## Evidence (checked live, 2026-10-03)

- `process_madvise(MADV_PAGEOUT)` (Linux 5.10+) lets the kernel reclaim a
  process's cold anonymous pages while it sleeps — the Windows model.
- BUT `kernel.yama.ptrace_scope = 1` on this box: process_madvise on another
  user's/sibling's process requires ptrace access → only parent→child or
  CAP_SYS_PTRACE. Our unprivileged daemon canNOT pageout arbitrary apps.

### Options
- v1: freeze-only. Stops the thrash loop (no execution → no new faults) even
  though RSS stays. Matches the requested UX (pause → dialog → user closes).
- v2a: tiny privileged helper (polkit or setcap CAP_SYS_PTRACE) for pageout.
- v2b: run daemon as a systemd service with the capability, parented
  appropriately. Weigh security surface vs benefit.

### Recommendation
Ship v1 freeze-only; measure whether frozen-but-resident RAM is actually a
problem in practice before adding a privileged pageout path.
