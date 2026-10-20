//! Memory governor: keep the desktop fluid BEFORE memory runs out.
//!
//! The freeze watchdog acts at real scarcity, when the system is already
//! thrashing. On a 16 GB Asahi box that point arrives many times a day, and
//! the biggest windowed app (the user's browser) is always the one frozen,
//! while the real growth comes from windowless batch work (agent builds,
//! linkers, test runners). macOS avoids this by squeezing background work
//! early; the governor does the same with cgroup v2 knobs we own (the whole
//! user@UID.service subtree is delegated to the user, no root needed):
//!
//! * batch (windowless scopes: agents, builds) -> memory.high, tightened a
//!   few % per tick while pressure is elevated, so they reclaim their own
//!   pages and get throttled instead of evicting the foreground's working set;
//! * services (windowless .service units) -> same, but only when critical;
//! * idle windowed apps (unfocused >= IDLE_AFTER) -> small memory.reclaim
//!   chunks: cold pages go to zram early, in the background, like macOS's
//!   compressor, instead of in a burst while the user waits;
//! * the session (compositor, shell), the focused app and anything frozen by
//!   us are never touched.
//!
//! Every limit we set is recorded in governor.json with the value it
//! replaced, and restored when pressure clears, on daemon start, and by
//! `task-manager governor-release` (install.sh --disable/--uninstall).

use crate::{
    clients, comm, current_uid, focused_pid, marker_units, monitors, pref_num, read_trim,
    runtime_dir, CGROOT,
};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::time::{Duration, Instant};

const MIB: u64 = 1024 * 1024;
/// memory.high never goes below this: a squeezed build must still progress.
const FLOOR_BYTES: u64 = 256 * MIB;
/// Batch/service leaves smaller than this are not worth limiting.
const MIN_LEAF_BYTES: u64 = 256 * MIB;
/// A windowed app counts as idle after this long without focus.
const IDLE_AFTER: Duration = Duration::from_secs(120);
/// Per-app proactive reclaim chunk cap, and the per-tick total budget.
const RECLAIM_CHUNK_MAX: u64 = 64 * MIB;
const RECLAIM_BUDGET_ELEVATED: u64 = 192 * MIB;
const RECLAIM_BUDGET_CRITICAL: u64 = 384 * MIB;
/// A limited leaf stalling this much on its own memory (memory.pressure
/// some avg10) is at its working set: loosen instead of squeezing into a
/// livelock.
const SELF_PSI_HOLD: f64 = 25.0;
/// Reclaim from an "idle" app that is refaulting this much would only churn.
const SELF_PSI_NO_RECLAIM: f64 = 10.0;
/// Most we push out of one app per idle period: switching back to it must
/// not mean faulting its whole working set in from zram.
const RECLAIM_PER_IDLE_MAX: u64 = 512 * MIB;

/// Processes that make a leaf untouchable wherever it lives.
const PROTECT_COMMS: &[&str] = &[
    "Hyprland",
    "quickshell",
    "pipewire",
    "pipewire-pulse",
    "wireplumber",
    "hyprlock",
    "hypridle",
    "uwsm",
    "dbus-broker",
    "dbus-daemon",
    "hermes",
    "task-manager-aa",
    "task-manager-x8",
];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Level {
    Calm,
    Elevated,
    Critical,
}

impl Level {
    fn as_str(self) -> &'static str {
        match self {
            Level::Calm => "calm",
            Level::Elevated => "elevated",
            Level::Critical => "critical",
        }
    }
}

/// System pressure level with hysteresis (no flapping around a threshold).
/// Elevated: under a quarter of RAM available, or sustained stalls with
/// under a third available. Critical: under 12% available.
pub fn level(avail_pct: f64, psi_some: f64, prev: Level) -> Level {
    let critical = match prev {
        Level::Critical => avail_pct < 15.0,
        _ => avail_pct < 12.0,
    };
    if critical {
        return Level::Critical;
    }
    let elevated = match prev {
        Level::Calm => avail_pct < 25.0 || (avail_pct < 33.0 && psi_some >= 20.0),
        _ => avail_pct < 30.0 || psi_some >= 10.0,
    };
    if elevated {
        Level::Elevated
    } else {
        Level::Calm
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Class {
    /// Session, audio, our own daemon, user-excluded tools: never touched.
    Protected,
    /// Holds the focused window.
    Foreground,
    /// Holds windows, not focused.
    Interactive,
    /// Windowless scope (agents, builds, `systemd-run --scope`).
    Batch,
    /// Windowless service unit.
    Service,
}

pub fn classify(path: &str, comms: &[String], focused: bool, windowed: bool) -> Class {
    if path.contains("/session.slice/")
        || path.ends_with("/init.scope")
        || path.contains("omarchy-task-manager")
        || comms.iter().any(|c| PROTECT_COMMS.contains(&c.as_str()))
    {
        return Class::Protected;
    }
    if focused {
        return Class::Foreground;
    }
    if windowed {
        return Class::Interactive;
    }
    if path.ends_with(".service") {
        Class::Service
    } else {
        Class::Batch
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum HighAction {
    Keep,
    Set(u64),
    Release,
}

/// Next memory.high for a leaf. `high` None = currently unlimited ("max").
/// `squeeze` = this class is eligible at the current level.
pub fn next_high(cur: u64, high: Option<u64>, level: Level, squeeze: bool, self_psi: f64) -> HighAction {
    if !squeeze {
        // Loosen gradually: dropping a tight limit at once lets the leaf
        // balloon straight back and re-create the pressure we just cleared.
        let Some(h) = high else {
            return HighAction::Keep;
        };
        let next = h + (h / 4).max(64 * MIB);
        return if next >= cur + 512 * MIB {
            HighAction::Release
        } else {
            HighAction::Set(next)
        };
    }
    if high.is_none() && cur < MIN_LEAF_BYTES {
        return HighAction::Keep;
    }
    if self_psi >= SELF_PSI_HOLD {
        return match high {
            Some(h) => HighAction::Set(h + h / 16),
            None => HighAction::Keep,
        };
    }
    let factor = if level == Level::Critical { 0.92 } else { 0.97 };
    let base = high.map(|h| h.min(cur)).unwrap_or(cur);
    let target = ((base as f64 * factor) as u64).max(FLOOR_BYTES);
    match high {
        Some(h) if target >= h => HighAction::Keep,
        None if target >= cur => HighAction::Keep,
        _ => HighAction::Set(target),
    }
}

/// Proactive reclaim chunk for an idle windowed app (0 = skip).
pub fn reclaim_chunk(cur: u64, self_psi: f64, budget_left: u64) -> u64 {
    if cur < MIN_LEAF_BYTES || self_psi >= SELF_PSI_NO_RECLAIM {
        return 0;
    }
    (cur / 20).min(RECLAIM_CHUNK_MAX).min(budget_left)
}

// ---------- cgroup I/O ----------

fn user_root() -> String {
    format!(
        "/user.slice/user-{uid}.slice/user@{uid}.service",
        uid = current_uid()
    )
}

/// Leaf cgroups (paths relative to CGROOT) under the delegated user subtree.
fn leaves() -> Vec<String> {
    fn walk(rel: &str, out: &mut Vec<String>, depth: u32) {
        let Ok(rd) = fs::read_dir(format!("{CGROOT}{rel}")) else {
            return;
        };
        let mut has_child = false;
        for e in rd.flatten() {
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) && depth < 8 {
                has_child = true;
                walk(&format!("{rel}/{}", e.file_name().to_string_lossy()), out, depth + 1);
            }
        }
        if !has_child {
            out.push(rel.to_string());
        }
    }
    let mut out = Vec::new();
    walk(&user_root(), &mut out, 0);
    out
}

fn read_u64(rel: &str, file: &str) -> u64 {
    read_trim(&format!("{CGROOT}{rel}/{file}"))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

fn read_high(rel: &str) -> Option<u64> {
    read_trim(&format!("{CGROOT}{rel}/memory.high")).and_then(|s| s.parse().ok())
}

fn self_psi(rel: &str) -> f64 {
    read_trim(&format!("{CGROOT}{rel}/memory.pressure"))
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("some"))
                .and_then(|l| l.split_whitespace().find_map(|t| t.strip_prefix("avg10=")))
                .and_then(|v| v.parse().ok())
        })
        .unwrap_or(0.0)
}

fn procs(rel: &str) -> Vec<u64> {
    read_trim(&format!("{CGROOT}{rel}/cgroup.procs"))
        .map(|s| s.lines().filter_map(|l| l.parse().ok()).collect())
        .unwrap_or_default()
}

fn frozen(rel: &str) -> bool {
    read_trim(&format!("{CGROOT}{rel}/cgroup.events"))
        .map(|s| s.lines().any(|l| l == "frozen 1"))
        .unwrap_or(false)
        || read_trim(&format!("{CGROOT}{rel}/cgroup.freeze")).as_deref() == Some("1")
}

fn write_high(rel: &str, value: &str) -> bool {
    fs::write(format!("{CGROOT}{rel}/memory.high"), value).is_ok()
}

fn unit_of(rel: &str) -> String {
    rel.rsplit('/').next().unwrap_or(rel).to_string()
}

/// Human label for a leaf: its biggest process's comm, plus the unit.
fn label(rel: &str, pids: &[u64]) -> String {
    let biggest = pids
        .iter()
        .max_by_key(|p| crate::rss_kb(**p))
        .map(|p| comm(*p))
        .unwrap_or_default();
    if biggest.is_empty() {
        unit_of(rel)
    } else {
        biggest
    }
}

// ---------- persisted state ----------

fn state_path() -> String {
    format!("{}/omarchy-task-manager/governor.json", runtime_dir())
}

fn write_atomic(path: &str, body: &str) {
    let _ = fs::create_dir_all(format!("{}/omarchy-task-manager", runtime_dir()));
    let tmp = format!("{path}.tmp");
    if fs::write(&tmp, body).is_ok() {
        let _ = fs::rename(&tmp, path);
    }
}

/// cgroup -> (memory.high it had before us, value we last wrote).
type Owned = BTreeMap<String, (String, u64)>;

fn load_saved() -> Owned {
    let raw = fs::read_to_string(state_path()).unwrap_or_default();
    let v: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);
    let mut out = BTreeMap::new();
    if let Some(m) = v.get("saved").and_then(|s| s.as_object()) {
        for (k, val) in m {
            let orig = val.get("orig").and_then(|o| o.as_str()).unwrap_or("max");
            let wrote = val.get("wrote").and_then(|w| w.as_u64()).unwrap_or(0);
            out.insert(k.clone(), (orig.to_string(), wrote));
        }
    }
    out
}

fn saved_json(saved: &Owned) -> Value {
    let m: serde_json::Map<String, Value> = saved
        .iter()
        .map(|(k, (o, w))| (k.clone(), serde_json::json!({"orig": o, "wrote": w})))
        .collect();
    Value::Object(m)
}

/// Restore every limit we set (daemon start/stop, governor-release). Only
/// values still equal to what we wrote: anything else was changed since by
/// someone else (thaw, the user) and is theirs now.
pub fn release_all() -> usize {
    let saved = load_saved();
    let skip: BTreeSet<String> = marker_units().into_iter().collect();
    let mut n = 0;
    for (rel, (orig, wrote)) in &saved {
        // A unit frozen by us owns its memory.high (freeze squeeze); thaw
        // restores it, so leave it alone here.
        if skip.contains(&unit_of(rel)) || read_high(rel) != Some(*wrote) {
            continue;
        }
        if write_high(rel, orig) {
            n += 1;
        }
    }
    write_atomic(
        &state_path(),
        "{\"level\":\"calm\",\"enabled\":true,\"saved\":{},\"limited\":[],\"reclaimed_mb\":0}",
    );
    n
}

// ---------- the controller ----------

pub struct Governor {
    level: Level,
    saved: Owned,
    last_focus: BTreeMap<String, Instant>,
    /// Bytes reclaimed from a leaf since it was last focused.
    idle_reclaimed: BTreeMap<String, u64>,
    started: Instant,
    reclaimed_total: u64,
}

impl Governor {
    pub fn new() -> Self {
        let n = release_all();
        if n > 0 {
            eprintln!("governor: restored {n} memory.high limit(s) left by a previous run");
        }
        Governor {
            level: Level::Calm,
            saved: BTreeMap::new(),
            last_focus: BTreeMap::new(),
            idle_reclaimed: BTreeMap::new(),
            started: Instant::now(),
            reclaimed_total: 0,
        }
    }

    fn enabled() -> bool {
        pref_num("governor", 1.0) > 0.0
    }

    /// One control step (call every ~2s).
    pub fn tick(&mut self, avail_pct: f64, psi_some: f64) {
        if !Self::enabled() {
            if !self.saved.is_empty() {
                release_all();
                self.saved.clear();
                eprintln!("governor: disabled by pref, limits released");
            }
            self.write_status(&[], false);
            return;
        }
        // TM_GOV_LEVEL pins the level (testing), like the other TM_* knobs.
        let lvl = match std::env::var("TM_GOV_LEVEL").as_deref() {
            Ok("calm") => Level::Calm,
            Ok("elevated") => Level::Elevated,
            Ok("critical") => Level::Critical,
            _ => level(avail_pct, psi_some, self.level),
        };
        if lvl != self.level {
            eprintln!(
                "governor: {} -> {} ({avail_pct:.1}% avail, psi_some {psi_some:.1})",
                self.level.as_str(),
                lvl.as_str()
            );
            self.level = lvl;
        }

        let mons = monitors();
        let windowed: BTreeSet<u64> = clients(&mons).iter().map(|w| w.pid).collect();
        // No compositor answer (restarting, hung, stale signature) = we
        // cannot tell windows from background: everything would look like
        // batch. Only releases are safe then.
        let blind = mons.is_empty() || windowed.is_empty();
        // A browser splits across scopes (window pid moved to its own scope,
        // renderers left in the launcher's), so "has a window" goes by comm
        // too, the same family rule the app rows use.
        let windowed_comms: BTreeSet<String> = windowed.iter().map(|p| comm(*p)).collect();
        let focus = focused_pid();
        // Same family rule for focus: the renderers of the focused browser
        // live in another scope than its window.
        let focus_comm = focus.map(comm);
        let ours_frozen: BTreeSet<String> = marker_units().into_iter().collect();
        let now = Instant::now();

        let mut limited: Vec<(String, String, u64, u64)> = Vec::new(); // (unit, label, cur, high)
        let mut budget = match lvl {
            Level::Critical => RECLAIM_BUDGET_CRITICAL,
            Level::Elevated => RECLAIM_BUDGET_ELEVATED,
            Level::Calm => 0,
        };
        let mut idle: Vec<(String, u64, f64, Duration)> = Vec::new();
        let mut live: BTreeSet<String> = BTreeSet::new();

        for rel in leaves() {
            let pids = procs(&rel);
            if pids.is_empty() {
                continue;
            }
            live.insert(rel.clone());
            let comms: Vec<String> = pids.iter().map(|p| comm(*p)).collect();
            let is_focused = focus.map(|f| pids.contains(&f)).unwrap_or(false)
                || focus_comm.as_ref().map(|c| comms.contains(c)).unwrap_or(false);
            if is_focused {
                self.last_focus.insert(rel.clone(), now);
                self.idle_reclaimed.remove(&rel);
            }
            if frozen(&rel) || ours_frozen.contains(&unit_of(&rel)) {
                continue;
            }
            let has_win = pids.iter().any(|p| windowed.contains(p))
                || comms.iter().any(|c| windowed_comms.contains(c));
            let class = classify(&rel, &comms, is_focused, has_win);
            let cur = read_u64(&rel, "memory.current");
            let high = read_high(&rel);
            let psi = self_psi(&rel);

            // Only drive limits we own; a user-set memory.high is theirs.
            // Ours = still holding exactly the value we wrote (a thaw or the
            // user may have rewritten it since).
            let ours = match self.saved.get(&rel) {
                Some((_, w)) => high == Some(*w),
                None => false,
            };
            if !ours && self.saved.remove(&rel).is_some() {
                self.persist();
            }
            if high.is_some() && !ours {
                continue;
            }
            let squeeze = !blind
                && match class {
                    Class::Batch => lvl != Level::Calm,
                    Class::Service => lvl == Level::Critical,
                    _ => false,
                };
            if !squeeze && !ours {
                if class == Class::Interactive && lvl != Level::Calm && !blind {
                    let since = self.last_focus.get(&rel).copied().unwrap_or(self.started);
                    if now.duration_since(since) >= IDLE_AFTER {
                        idle.push((rel.clone(), cur, psi, now.duration_since(since)));
                    }
                }
                continue;
            }
            // Leaving an eligible class (e.g. the user focused it): free it
            // at once, the user is waiting on it.
            let action = if ours && matches!(class, Class::Foreground | Class::Interactive | Class::Protected) {
                HighAction::Release
            } else {
                next_high(cur, high, lvl, squeeze, psi)
            };
            match action {
                HighAction::Keep => {
                    if let Some(h) = high {
                        limited.push((unit_of(&rel), label(&rel, &pids), cur, h));
                    }
                }
                HighAction::Set(v) => {
                    // The kernel stores memory.high in whole pages; a value
                    // aligned to 64 KiB reads back exactly on 4K/16K/64K
                    // pages, which is how ownership is recognised.
                    let v = v & !(64 * 1024 - 1);
                    // Record ownership BEFORE the write: a daemon killed in
                    // between must still find (and restore) this limit.
                    let orig = self
                        .saved
                        .get(&rel)
                        .map(|(o, _)| o.clone())
                        .unwrap_or_else(|| "max".to_string());
                    self.saved.insert(rel.clone(), (orig, v));
                    self.persist();
                    if !ours {
                        eprintln!(
                            "governor: limiting {} ({}, {} MB) at {} MB [{}]",
                            label(&rel, &pids),
                            unit_of(&rel),
                            cur / MIB,
                            v / MIB,
                            lvl.as_str()
                        );
                    }
                    if write_high(&rel, &v.to_string()) {
                        limited.push((unit_of(&rel), label(&rel, &pids), cur, v));
                    }
                }
                HighAction::Release => {
                    let orig = self
                        .saved
                        .get(&rel)
                        .map(|(o, _)| o.clone())
                        .unwrap_or_else(|| "max".into());
                    write_high(&rel, &orig);
                    self.saved.remove(&rel);
                    self.persist();
                    eprintln!("governor: released {} ({})", label(&rel, &pids), unit_of(&rel));
                }
            }
        }
        // Leaves that vanished (scope ended) take their limit with them.
        self.saved.retain(|k, _| live.contains(k));
        self.last_focus.retain(|k, _| live.contains(k));
        self.idle_reclaimed.retain(|k, _| live.contains(k));

        // Proactive reclaim, longest-idle first, then biggest.
        idle.sort_by_key(|i| (std::cmp::Reverse(i.3.as_secs() / 60), std::cmp::Reverse(i.1)));
        for (rel, cur, psi, _) in idle {
            let done = self.idle_reclaimed.get(&rel).copied().unwrap_or(0);
            let left = RECLAIM_PER_IDLE_MAX.saturating_sub(done).min(budget);
            let chunk = reclaim_chunk(cur, psi, left);
            if chunk == 0 {
                continue;
            }
            let before = read_u64(&rel, "memory.current");
            // EAGAIN (could not reclaim it all) is normal; count what moved.
            let _ = fs::write(format!("{CGROOT}{rel}/memory.reclaim"), chunk.to_string());
            let freed = before.saturating_sub(read_u64(&rel, "memory.current"));
            self.reclaimed_total += freed;
            *self.idle_reclaimed.entry(rel.clone()).or_insert(0) += chunk;
            budget = budget.saturating_sub(chunk);
            if budget == 0 {
                break;
            }
        }
        self.write_status(&limited, true);
    }

    /// Ownership only (status untouched): called right before each write.
    fn persist(&self) {
        let raw = fs::read_to_string(state_path()).unwrap_or_default();
        let mut v: Value = serde_json::from_str(&raw).unwrap_or_else(|_| serde_json::json!({}));
        if !v.is_object() {
            v = serde_json::json!({});
        }
        v["saved"] = saved_json(&self.saved);
        write_atomic(&state_path(), &v.to_string());
    }

    fn write_status(&self, limited: &[(String, String, u64, u64)], enabled: bool) {
        let saved = saved_json(&self.saved);
        let lim: Vec<Value> = limited
            .iter()
            .map(|(u, n, c, h)| {
                serde_json::json!({"unit": u, "name": n, "cur_mb": c / MIB, "high_mb": h / MIB})
            })
            .collect();
        let v = serde_json::json!({
            "level": self.level.as_str(),
            "enabled": enabled,
            "saved": saved,
            "limited": lim,
            "reclaimed_mb": self.reclaimed_total / MIB,
        });
        write_atomic(&state_path(), &v.to_string());
    }
}

/// Governor status JSON for `state` (written by the watch daemon).
pub fn status_json() -> String {
    let raw = fs::read_to_string(state_path()).unwrap_or_default();
    let mut v: Value = serde_json::from_str(&raw).unwrap_or_else(|_| serde_json::json!({}));
    if let Some(o) = v.as_object_mut() {
        o.remove("saved");
    }
    v.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn level_hysteresis() {
        assert_eq!(level(40.0, 0.0, Level::Calm), Level::Calm);
        assert_eq!(level(24.0, 0.0, Level::Calm), Level::Elevated);
        // Stalls only count with the RAM getting tight.
        assert_eq!(level(30.0, 25.0, Level::Calm), Level::Elevated);
        assert_eq!(level(50.0, 80.0, Level::Calm), Level::Calm);
        // Elevated holds until 30% available.
        assert_eq!(level(27.0, 0.0, Level::Elevated), Level::Elevated);
        assert_eq!(level(31.0, 0.0, Level::Elevated), Level::Calm);
        assert_eq!(level(11.0, 0.0, Level::Elevated), Level::Critical);
        assert_eq!(level(13.0, 0.0, Level::Critical), Level::Critical);
        assert_eq!(level(16.0, 0.0, Level::Critical), Level::Elevated);
    }

    #[test]
    fn classification() {
        let none: Vec<String> = vec![];
        let ses = "/user.slice/user-1001.slice/user@1001.service/session.slice/wayland-wm@hyprland.desktop.service";
        assert_eq!(classify(ses, &none, true, true), Class::Protected);
        let hermes = vec!["hermes".to_string()];
        assert_eq!(classify("/u/app.slice/hermes-gateway.service", &hermes, false, false), Class::Protected);
        let chrome = "/u/app.slice/app-com.google.Chrome-1.scope";
        assert_eq!(classify(chrome, &none, true, true), Class::Foreground);
        assert_eq!(classify(chrome, &none, false, true), Class::Interactive);
        let agent = "/u/app.slice/app-t3code.slice/app-t3code-agents.slice/t3code-claude-1.scope";
        assert_eq!(classify(agent, &none, false, false), Class::Batch);
        assert_eq!(classify("/u/app.slice/t3code.service", &none, false, false), Class::Service);
        assert_eq!(classify("/u/app.slice/omarchy-task-manager.service", &none, false, false), Class::Protected);
    }

    #[test]
    fn squeeze_steps_down_and_respects_floor() {
        let g = 1024 * MIB;
        match next_high(4 * g, None, Level::Elevated, true, 0.0) {
            HighAction::Set(v) => assert!(v < 4 * g && v > 3 * g),
            a => panic!("{a:?}"),
        }
        // Critical squeezes harder than elevated.
        let HighAction::Set(e) = next_high(4 * g, None, Level::Elevated, true, 0.0) else { panic!() };
        let HighAction::Set(c) = next_high(4 * g, None, Level::Critical, true, 0.0) else { panic!() };
        assert!(c < e);
        // Never below the floor; at the floor it holds.
        assert_eq!(next_high(300 * MIB, Some(FLOOR_BYTES), Level::Critical, true, 0.0), HighAction::Keep);
        // Small leaves are not worth a limit.
        assert_eq!(next_high(100 * MIB, None, Level::Critical, true, 0.0), HighAction::Keep);
    }

    #[test]
    fn squeeze_loosens_when_leaf_stalls() {
        let h = 1024 * MIB;
        assert_eq!(next_high(h, Some(h), Level::Critical, true, 55.0), HighAction::Set(h + h / 16));
        assert_eq!(next_high(h, None, Level::Critical, true, 55.0), HighAction::Keep);
    }

    #[test]
    fn release_is_gradual() {
        let h = 1024 * MIB;
        assert_eq!(next_high(h, Some(h), Level::Calm, false, 0.0), HighAction::Set(h + h / 4));
        assert_eq!(next_high(h, Some(h + 400 * MIB), Level::Calm, false, 0.0), HighAction::Release);
        assert_eq!(next_high(h, None, Level::Calm, false, 0.0), HighAction::Keep);
    }

    #[test]
    fn reclaim_chunks() {
        assert_eq!(reclaim_chunk(100 * MIB, 0.0, 1024 * MIB), 0);
        assert_eq!(reclaim_chunk(2048 * MIB, 0.0, 1024 * MIB), RECLAIM_CHUNK_MAX);
        assert_eq!(reclaim_chunk(400 * MIB, 0.0, 1024 * MIB), 20 * MIB);
        assert_eq!(reclaim_chunk(2048 * MIB, 0.0, 10 * MIB), 10 * MIB);
        assert_eq!(reclaim_chunk(2048 * MIB, 30.0, 1024 * MIB), 0);
    }
}
