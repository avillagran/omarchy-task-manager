# 003: grey-out-frozen-windows — Verdict: PARTIAL (two workable paths)

Question: Given a frozen app, can we make its windows look grey like
Windows/macOS suspended apps?

## Evidence (verified live, 2026-10-03)

- Hyprland 0.56.2 (sensei-wrapped dispatchers: `hl.dsp.*`).
- `hyprctl clients -j` exposes per-window: pid, class, title, at, size,
  workspace, monitor, address → geometry tracking is trivial.
- A frozen Wayland client simply stops committing buffers: the compositor
  keeps showing the LAST frame. The window looks normal but never updates and
  ignores input — Hyprland does NOT grey it out natively, and there is no
  per-window saturation windowrule.

### What works (pick in v1 design)
- Path A (recommended): translucent grey OVERLAY surface (layer-shell,
  Overlay layer, no keyboard focus, pass-through or click-blocking mouse
  region) positioned over each frozen window's geometry from
  `hyprctl clients -j`; move it when the window moves. Proven tech in our
  plugins (CardWindow/overlay patterns).
- Path B (cheap): per-window opacity windowrule/dispatch (dim the window
  itself). Less "grey", more "faded"; zero extra surfaces.

### What didn't
- No native compositor grey-out. Saturation shaders per window don't exist
  in Hyprland 0.56.

### Recommendation
V1: Path B (one dispatcher call per window) + list in the dialog.
V2: Path A overlays if the fade isn't obvious enough.
