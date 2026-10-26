//! omarchy-task-manager engine.
//!
//! Usage:
//!   task-manager state          JSON: {mem:{...}, monitors:[...], apps:[...]}
//!   task-manager freeze T       freeze app + squeeze its RAM (memory.high)
//!   task-manager thaw T         restore memory.high + resume
//!   task-manager focus T        focus the app's window
//!   task-manager kill T         thaw + SIGTERM, SIGKILL if still alive
//!   task-manager shell-reset [force|list]   restart the Omarchy shell
//!
//! T is `PID` or `PID:START` (START = /proc/PID/stat starttime, as printed in
//! the state JSON): with START the command refuses a pid the kernel reused.
//!
//! Freeze = the cgroup v2 freezer of the app's scope (atomic per app), written
//! directly in the user's delegated cgroup subtree. While frozen, memory.high
//! is lowered so the kernel reclaims the app's cold pages to swap — RAM
//! actually drops without killing the app. Every signal goes through a pidfd.

#[macro_use]
mod json;
mod governor;
mod hypr;
mod safefs;
mod shell;
mod sys;

use json::Value;
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::process::{Command, Stdio};

const CGROOT: &str = "/sys/fs/cgroup";
/// Background comm-group floor.
const MIN_BG_RSS_KB: u64 = 30 * 1024;
/// Auto-freeze never targets apps smaller than this.
const MIN_FREEZE_MB: u64 = 100;
/// Squeeze target while frozen: clamp(current/4, SQUEEZE_MIN, SQUEEZE_MAX).
const SQUEEZE_MIN_BYTES: u64 = 96 * 1024 * 1024;
const SQUEEZE_MAX_BYTES: u64 = 512 * 1024 * 1024;
/// Longest string field handed to the QML (titles, names, units).
const FIELD_CAP: usize = 256;
/// Most rows of each list in the state JSON.
const MAX_APPS: usize = 256;
const MAX_CLIENTS: usize = 1024;
/// Read caps for kernel files.
const CAP_DEFAULT: u64 = 1024 * 1024;
const CAP_STATUS: u64 = 64 * 1024;
const CAP_CMDLINE: u64 = 256 * 1024;

/// Never touch the compositor, shell, audio stack, or terminals (a frozen
/// terminal would freeze the shell/agent running inside it).
const EXCLUDE_COMMS: &[&str] = &[
    "Hyprland",
    "quickshell",
    "pipewire",
    "wireplumber",
    "waybar",
    "hyprpaper",
    "hypridle",
    "hyprlock",
    "uwsm",
    "dbus-broker",
    "hermes",
    "systemd",
    "foot",
    "alacritty",
    "kitty",
    "ghostty",
    "wezterm",
    "bash",
    "zsh",
    "fish",
    "task-manager",
];

fn current_uid() -> u32 {
    sys::uid()
}

fn runtime() -> Option<safefs::Dir> {
    match safefs::runtime() {
        Ok(d) => Some(d),
        Err(e) => {
            eprintln!("task-manager: runtime dir unavailable: {e}");
            None
        }
    }
}

fn state_dir() -> Option<safefs::Dir> {
    match safefs::state() {
        Ok(d) => Some(d),
        Err(e) => {
            eprintln!("task-manager: state dir unavailable: {e}");
            None
        }
    }
}

/// Truncate to FIELD_CAP chars (char boundary safe).
fn cap_str(s: &str) -> String {
    s.chars().take(FIELD_CAP).collect()
}

/// Run a helper with a deadline; stdout/stderr discarded. Returns success.
fn run_bounded(prog: &str, args: &[&str], secs: u64) -> bool {
    let Ok(mut child) = Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(secs);
    loop {
        match child.try_wait() {
            Ok(Some(st)) => return st.success(),
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

#[derive(Clone)]
struct Win {
    pid: u64,
    address: String,
    title: String,
    /// Window class (app id): the card looks up the app's icon with it.
    class: String,
    x: i64,
    y: i64,
    w: i64,
    h: i64,
    ws: i64,
    monitor: String,
    pinned: bool,
}

/// (name, active workspace id, x, y) per monitor, in hyprctl order
/// (client.monitor is an index into this array).
fn monitors() -> Vec<(String, i64, i64, i64, bool, i64, i64)> {
    let Some(Value::Array(arr)) = hypr::query("monitors") else {
        return Vec::new();
    };
    arr.iter()
        .take(64)
        .filter_map(|m| {
            let name = cap_str(m.get("name")?.as_str()?);
            let ws = m
                .get("activeWorkspace")
                .and_then(|w| w.get("id"))
                .and_then(Value::as_i64)
                .unwrap_or(0);
            let x = m.get("x").and_then(Value::as_i64).unwrap_or(0);
            let y = m.get("y").and_then(Value::as_i64).unwrap_or(0);
            let focused = m.get("focused").and_then(Value::as_bool).unwrap_or(false);
            let w = m.get("width").and_then(Value::as_i64).unwrap_or(0);
            let h = m.get("height").and_then(Value::as_i64).unwrap_or(0);
            Some((name, ws, x, y, focused, w, h))
        })
        .collect()
}

fn clients(mons: &[(String, i64, i64, i64, bool, i64, i64)]) -> Vec<Win> {
    let Some(Value::Array(arr)) = hypr::query("clients") else {
        return Vec::new();
    };
    arr.iter()
        .take(MAX_CLIENTS)
        .filter(|c| c.get("mapped").and_then(Value::as_bool).unwrap_or(true))
        .filter_map(|c| {
            let at = c.get("at")?.as_array()?;
            let size = c.get("size")?.as_array()?;
            let mon_idx = c.get("monitor").and_then(Value::as_i64).unwrap_or(-1);
            let monitor = if mon_idx >= 0 && (mon_idx as usize) < mons.len() {
                mons[mon_idx as usize].0.clone()
            } else {
                String::new()
            };
            Some(Win {
                pid: c.get("pid")?.as_u64()?,
                address: c
                    .get("address")?
                    .as_str()
                    .filter(|a| hypr::valid_address(a))?
                    .to_string(),
                title: c
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .chars()
                    .take(60)
                    .collect(),
                class: c
                    .get("class")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .chars()
                    .take(128)
                    .collect(),
                x: at.first().and_then(Value::as_i64).unwrap_or(0),
                y: at.get(1).and_then(Value::as_i64).unwrap_or(0),
                w: size.first().and_then(Value::as_i64).unwrap_or(0),
                h: size.get(1).and_then(Value::as_i64).unwrap_or(0),
                ws: c
                    .get("workspace")
                    .and_then(|w| w.get("id"))
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
                monitor,
                pinned: c.get("pinned").and_then(Value::as_bool).unwrap_or(false),
            })
        })
        .collect()
}

/// Bounded read of a kernel file (/proc, /sys), trimmed.
fn read_trim(path: &str) -> Option<String> {
    read_capped(path, CAP_DEFAULT)
}

fn read_capped(path: &str, cap: u64) -> Option<String> {
    let b = safefs::read_kernel(path, cap)?;
    Some(String::from_utf8_lossy(&b).trim().to_string())
}

fn proc_cgroup(pid: u64) -> Option<(String, String)> {
    let raw = read_trim(&format!("/proc/{pid}/cgroup"))?;
    let path = raw.split("::").nth(1)?.to_string();
    let unit = path.trim_end_matches('/').rsplit('/').next()?.to_string();
    Some((path, unit))
}

fn is_app_scope(unit: &str) -> bool {
    unit.starts_with("app-") && unit.ends_with(".scope")
}

fn unit_procs(cgpath: &str) -> Vec<u64> {
    read_trim(&format!("{CGROOT}{cgpath}/cgroup.procs"))
        .map(|s| s.lines().filter_map(|l| l.parse().ok()).collect())
        .unwrap_or_default()
}

fn rss_kb(pid: u64) -> u64 {
    status_kb(pid).0
}

fn comm(pid: u64) -> String {
    with_pid(pid, |e| {
        e.comm
            .get_or_insert_with(|| read_trim(&format!("/proc/{pid}/comm")).unwrap_or_else(|| "?".into()))
            .clone()
    })
}

/// (VmRSS, VmSwap) in kB, from one read of /proc/PID/status.
fn status_kb(pid: u64) -> (u64, u64) {
    with_pid(pid, |e| {
        *e.status.get_or_insert_with(|| {
            let Some(s) = read_capped(&format!("/proc/{pid}/status"), CAP_STATUS) else {
                return (0, 0);
            };
            let field = |k: &str| {
                s.lines()
                    .find_map(|l| l.strip_prefix(k))
                    .and_then(|v| v.split_whitespace().next())
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(0)
            };
            (field("VmRSS:"), field("VmSwap:"))
        })
    })
}

/// Per-pid memo, dropped wholesale after PID_TTL. One tick asks for the
/// same comm/status from several places (governor, background groups,
/// history); reading /proc once per pid per tick keeps the watchdog cheap.
const PID_TTL: std::time::Duration = std::time::Duration::from_millis(250);

#[derive(Default)]
struct PidMemo {
    comm: Option<String>,
    status: Option<(u64, u64)>,
}

thread_local! {
    static PIDS: std::cell::RefCell<(Option<std::time::Instant>, BTreeMap<u64, PidMemo>)> =
        const { std::cell::RefCell::new((None, BTreeMap::new())) };
}

fn with_pid<R>(pid: u64, f: impl FnOnce(&mut PidMemo) -> R) -> R {
    PIDS.with(|c| {
        let mut c = c.borrow_mut();
        if !matches!(c.0, Some(t) if t.elapsed() < PID_TTL) {
            c.0 = Some(std::time::Instant::now());
            c.1.clear();
        }
        f(c.1.entry(pid).or_default())
    })
}

fn scope_frozen(cgpath: &str) -> bool {
    read_trim(&format!("{CGROOT}{cgpath}/cgroup.freeze")).as_deref() == Some("1")
}

fn pid_stopped(pid: u64) -> bool {
    let Some(stat) = read_trim(&format!("/proc/{pid}/stat")) else {
        return false;
    };
    // Fields after the final ')' start with: state ppid pgrp ...
    stat.rsplit(')')
        .next()
        .and_then(|t| t.split_whitespace().next())
        .map(|s| s == "T")
        .unwrap_or(false)
}

/// Marker file: what WE froze. Apps that stop themselves (state T on their
/// own) must not show up as paused by us. Scope markers ALSO cover the async
/// cgroup.freeze transition window (freeze=0 until fully frozen, so right
/// after a freeze the row would vanish if its RSS already squeezed low).
/// Pids are stored with their start time, so a reused pid is never "ours".
const MARKER: &str = "frozen.json";

struct Marker {
    pids: Vec<(u64, u64)>,
    scopes: Vec<String>,
}

fn marker_read() -> Marker {
    let mut m = Marker { pids: Vec::new(), scopes: Vec::new() };
    let Some(text) = runtime().and_then(|d| d.read_string(MARKER)) else {
        return m;
    };
    let Ok(v) = json::from_str(&text) else {
        return m;
    };
    if let Some(a) = v.get("pids").and_then(Value::as_array) {
        m.pids = a
            .iter()
            .take(4096)
            .filter_map(|x| Some((x[0].as_u64()?, x[1].as_u64()?)))
            .collect();
    }
    if let Some(a) = v.get("scopes").and_then(Value::as_array) {
        m.scopes = a
            .iter()
            .take(4096)
            .filter_map(|x| x.as_str().filter(|p| cg_path_ok(p)).map(str::to_string))
            .collect();
    }
    m
}

fn marker_write(m: &Marker) {
    let pids: Vec<Value> = m
        .pids
        .iter()
        .map(|(p, s)| Value::Array(vec![json!(*p), json!(*s)]))
        .collect();
    let scopes: Vec<Value> = m.scopes.iter().map(|s| json!(s)).collect();
    let v = json!({"pids": pids, "scopes": scopes});
    if let Some(d) = runtime() {
        let _ = d.write_atomic(MARKER, v.to_string().as_bytes());
    }
}

/// Pids we stopped that are still the same processes.
fn marker_pids() -> Vec<u64> {
    marker_read()
        .pids
        .into_iter()
        .filter(|(p, s)| start_time(*p) == Some(*s))
        .map(|(p, _)| p)
        .collect()
}

fn marker_units() -> Vec<String> {
    marker_read().scopes.iter().map(|p| unit_of(p)).collect()
}

fn unit_of(cgpath: &str) -> String {
    cgpath.trim_end_matches('/').rsplit('/').next().unwrap_or("").to_string()
}

fn marker_add(pid: u64) {
    let Some(st) = start_time(pid) else { return };
    let mut m = marker_read();
    m.pids.retain(|(p, _)| *p != pid);
    m.pids.push((pid, st));
    marker_write(&m);
}

fn marker_remove(pid: u64) {
    let mut m = marker_read();
    m.pids.retain(|(p, _)| *p != pid);
    marker_write(&m);
}

fn marker_add_scope(cgpath: &str) {
    let mut m = marker_read();
    if !m.scopes.iter().any(|x| x == cgpath) {
        m.scopes.push(cgpath.to_string());
    }
    marker_write(&m);
}

fn marker_remove_scope(cgpath: &str) {
    let mut m = marker_read();
    m.scopes.retain(|x| x != cgpath);
    marker_write(&m);
}

fn mem_current(cgpath: &str) -> u64 {
    read_trim(&format!("{CGROOT}{cgpath}/memory.current"))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

/// Our delegated cgroup subtree (relative to CGROOT).
fn user_root() -> String {
    format!(
        "/user.slice/user-{uid}.slice/user@{uid}.service",
        uid = current_uid()
    )
}

/// Only cgroups inside our own delegated subtree are ever written.
fn cg_path_ok(cgpath: &str) -> bool {
    cgpath.starts_with(&format!("{}/", user_root()))
        && !cgpath.split('/').any(|c| c == ".." || c == ".")
        && !cgpath.contains('\0')
}

/// Write a control file of one of our cgroups (no symlink following).
fn cg_write(cgpath: &str, file: &str, value: &str) -> bool {
    cg_path_ok(cgpath) && safefs::write_kernel(&format!("{CGROOT}{cgpath}/{file}"), value)
}

fn set_memory_high(cgpath: &str, value: &str) {
    let _ = cg_write(cgpath, "memory.high", value);
}

/// Signal a process through a pidfd. With `start`, only if it is still the
/// process that started then (the pidfd pins it, so check-then-signal on
/// it cannot hit a reused pid).
fn signal(pid: u64, start: Option<u64>, signo: i32) -> bool {
    let Ok(fd) = sys::Pidfd::open(pid) else {
        return false;
    };
    let Some(now) = start_time(pid) else {
        return false;
    };
    if start.is_some_and(|s| s != now) {
        return false;
    }
    fd.signal(signo)
}

/// Signal a family member found by a /proc scan: pinned first, then
/// re-checked to still carry the family's comm and our uid.
fn signal_member(pid: u64, family_comm: &str, signo: i32) -> bool {
    let Ok(fd) = sys::Pidfd::open(pid) else {
        return false;
    };
    if comm(pid) != family_comm || !owned_by_us(pid) {
        return false;
    }
    fd.signal(signo)
}

fn owned_by_us(pid: u64) -> bool {
    use std::os::unix::fs::MetadataExt;
    fs::metadata(format!("/proc/{pid}"))
        .map(|m| m.uid() == current_uid())
        .unwrap_or(false)
}

fn zswap_status() -> (bool, bool, bool) {
    // (kernel supports it, currently enabled, swap already zram-backed)
    // Omarchy stock ships swap-on-zram with zswap deliberately OFF: zram
    // already compresses in RAM, so the enable-zswap banner must not nag.
    let p = "/sys/module/zswap/parameters/enabled";
    let zram = read_trim("/proc/swaps")
        .map(|s| s.lines().skip(1).any(|l| l.contains("zram")))
        .unwrap_or(false);
    if !std::path::Path::new(p).exists() {
        return (false, false, zram);
    }
    let enabled = read_trim(p).as_deref() == Some("Y");
    (true, enabled, zram)
}

/// Read a numeric UI pref from prefs.json (written by `pref K V`).
fn pref_num(key: &str, dflt: f64) -> f64 {
    let v = read_prefs();
    match v.get(key) {
        Some(Value::Bool(b)) => {
            if *b {
                1.0
            } else {
                0.0
            }
        }
        Some(x) => x.as_f64().unwrap_or(dflt),
        None => dflt,
    }
}

/// Pressure thresholds (prefs-backed; env still wins, for testing).
/// The user configures the maximum USED RAM % they tolerate (watchMaxRam,
/// default 94); the watchdog trips when FREE RAM falls below the remainder.
fn crit_avail_pct() -> f64 {
    if let Ok(v) = env::var("TM_CRIT_AVAIL_PCT") {
        if let Ok(n) = v.parse() {
            return n;
        }
    }
    100.0 - pref_num("watchMaxRam", 94.0).clamp(50.0, 99.0)
}
fn crit_psi() -> f64 {
    env::var("TM_CRIT_PSI")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(30.0)
}
/// CPU % above which the watchdog also freezes (0 = CPU trigger off).
fn crit_cpu_pct() -> f64 {
    if let Ok(v) = env::var("TM_CRIT_CPU_PCT") {
        if let Ok(n) = v.parse() {
            return n;
        }
    }
    let n = pref_num("watchMaxCpu", 0.0);
    if n <= 0.0 {
        0.0
    } else {
        n.clamp(50.0, 99.0)
    }
}
fn recover_avail_pct() -> f64 {
    env::var("TM_RECOVER_AVAIL_PCT")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(12.0)
}
fn max_freeze_per_episode() -> u32 {
    env::var("TM_MAX_FREEZE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(3)
}

/// (avail_pct, critical)
fn pressure(total: u64, avail: u64, _psi_some: f64, psi_full: f64) -> (f64, bool) {
    let pct = if total > 0 {
        avail as f64 * 100.0 / total as f64
    } else {
        100.0
    };
    (pct, freeze_critical(pct, crit_avail_pct(), psi_full, crit_psi()))
}

/// Freezing is the LAST resort: the governor owns everything above real
/// scarcity. PSI alone never freezes (a zram reclaim burst pushes psi_full
/// past 10 with half the RAM free; that froze Chrome at 55.8% avail), and
/// even PSI near scarcity froze an idle user's Chrome at 17% avail after a
/// reboot (session restore + a daemon starting): stalls only count within
/// half the critical margin again, and only when severe.
fn freeze_critical(pct: f64, crit: f64, psi_full: f64, crit_psi: f64) -> bool {
    pct < crit || (pct < crit * 1.5 && psi_full >= crit_psi)
}

/// (mem_total_mb, mem_avail_mb, psi_some_avg10, psi_full_avg10, swap_total_mb, swap_used_mb)
fn mem_info() -> (u64, u64, f64, f64, u64, u64) {
    let mut total = 0;
    let mut avail = 0;
    let mut swap_total = 0;
    let mut swap_free = 0;
    if let Some(mi) = read_trim("/proc/meminfo") {
        for line in mi.lines() {
            let kb = |r: &str| -> u64 {
                r.split_whitespace()
                    .next()
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0)
                    / 1024
            };
            if let Some(r) = line.strip_prefix("MemTotal:") {
                total = kb(r);
            } else if let Some(r) = line.strip_prefix("MemAvailable:") {
                avail = kb(r);
            } else if let Some(r) = line.strip_prefix("SwapTotal:") {
                swap_total = kb(r);
            } else if let Some(r) = line.strip_prefix("SwapFree:") {
                swap_free = kb(r);
            }
        }
    }
    let mut psi_some = 0.0;
    let mut psi_full = 0.0;
    if let Some(p) = read_trim("/proc/pressure/memory") {
        for line in p.lines() {
            for tok in line.split_whitespace() {
                if let Some(v) = tok.strip_prefix("avg10=") {
                    let n: f64 = v.parse().unwrap_or(0.0);
                    if line.starts_with("some") {
                        psi_some = n;
                    } else if line.starts_with("full") {
                        psi_full = n;
                    }
                }
            }
        }
    }
    (
        total,
        avail,
        psi_some,
        psi_full,
        swap_total,
        swap_total.saturating_sub(swap_free),
    )
}

/// Escaped JSON string CONTENT (no quotes), truncated to FIELD_CAP chars,
/// for the hand-built state output.
fn json_escape(s: &str) -> String {
    let q = json::quote(&cap_str(s));
    q[1..q.len() - 1].to_string()
}

fn win_json(w: &Win) -> String {
    format!(
        "{{\"addr\":\"{}\",\"x\":{},\"y\":{},\"w\":{},\"h\":{},\"ws\":{},\"mon\":\"{}\",\"pinned\":{},\"title\":\"{}\"}}",
        json_escape(&w.address),
        w.x,
        w.y,
        w.w,
        w.h,
        w.ws,
        json_escape(&w.monitor),
        w.pinned,
        json_escape(&w.title)
    )
}

/// Human role of a subprocess, parsed from its cmdline. Chromium/Electron
/// children all share the parent's comm; the --type flag is what
/// distinguishes a tab renderer from the GPU process or network service.
fn proc_role(pid: u64) -> String {
    let Some(raw) = safefs::read_kernel(&format!("/proc/{pid}/cmdline"), CAP_CMDLINE) else {
        return String::new();
    };
    let s = String::from_utf8_lossy(&raw).replace('\0', " ");
    if let Some(i) = s.find("--type=") {
        let t = &s[i + 7..];
        let end = t.find(' ').unwrap_or(t.len());
        return match &t[..end] {
            "renderer" => "renderer".into(),
            "gpu-process" => "gpu".into(),
            "utility" => {
                // --utility-sub-type=network.mojom.NetworkService -> "network"
                if let Some(j) = s.find("--utility-sub-type=") {
                    let u = &s[j + 19..];
                    let ue = u.find(' ').unwrap_or(u.len());
                    u[..ue].split('.').next().unwrap_or("utility").to_string()
                } else {
                    "utility".into()
                }
            }
            "zygote" => "zygote".into(),
            "crashpad-handler" => "crashpad".into(),
            other => other.to_string(),
        };
    }
    if s.contains("crashpad") {
        return "crashpad".into();
    }
    String::new()
}

/// All user pids sharing a comm (the app's full "family", across scopes —
/// chrome splits into 2+ scopes; the tree/freeze must treat it as ONE app).
fn comm_family(pid: u64) -> Vec<u64> {
    let target = comm(pid);
    let mut out = FAMILIES.with(|f| {
        let mut f = f.borrow_mut();
        let fresh = matches!(&*f, Some((t, _)) if t.elapsed() < FAMILY_TTL);
        if !fresh {
            *f = Some((std::time::Instant::now(), user_comms()));
        }
        f.as_ref()
            .and_then(|(_, m)| m.get(&target).cloned())
            .unwrap_or_default()
    });
    if out.is_empty() {
        out.push(pid);
    }
    out
}

/// One /proc pass grouping the user's pids by comm. Callers ask for many
/// families per tick (every window, every background group): scanning /proc
/// once per family made the watchdog O(apps × procs).
const FAMILY_TTL: std::time::Duration = std::time::Duration::from_millis(250);

thread_local! {
    static FAMILIES: std::cell::RefCell<Option<(std::time::Instant, BTreeMap<String, Vec<u64>>)>> =
        const { std::cell::RefCell::new(None) };
}

fn user_comms() -> BTreeMap<String, Vec<u64>> {
    use std::os::unix::fs::MetadataExt;
    let uid = current_uid();
    let self_pid = std::process::id() as u64;
    let mut map: BTreeMap<String, Vec<u64>> = BTreeMap::new();
    let Ok(entries) = fs::read_dir("/proc") else {
        return map;
    };
    for e in entries.flatten() {
        let Some(p) = e.file_name().to_str().and_then(|s| s.parse::<u64>().ok()) else {
            continue;
        };
        if p == self_pid {
            continue;
        }
        let Ok(md) = fs::metadata(e.path()) else {
            continue;
        };
        if md.uid() != uid {
            continue;
        }
        map.entry(comm(p)).or_default().push(p);
    }
    map
}

/// Unique app-scope (cgpath, unit) pairs covering a process family.
fn family_scopes(family: &[u64]) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for p in family {
        if let Some((cg, u)) = proc_cgroup(*p) {
            if is_app_scope(&u) && !out.iter().any(|(_, uu)| uu == &u) {
                out.push((cg, u));
            }
        }
    }
    out
}

/// Background process groups (no window), grouped by comm, summed RSS.
struct BgRec {
    name: String,
    rss_mb: u64,
    swap_mb: u64,
    procs: usize,
    pid: u64, // biggest pid of the group (representative for actions)
    unit: String,
    mechanism: &'static str,
    frozen: bool,
}

/// Per-process swap usage (VmSwap, kB) — cheap status read.
fn swap_kb(pid: u64) -> u64 {
    status_kb(pid).1
}

fn collect_background(by_pid: &BTreeMap<u64, Vec<Win>>, marks: &[u64]) -> Vec<BgRec> {
    use std::os::unix::fs::MetadataExt;
    let uid = current_uid();
    let self_pid = std::process::id() as u64;
    // Comms that own a window live in the windowed section (their background
    // scope-mates are inside that row's tree) — never duplicated here.
    let windowed_comms: Vec<String> = by_pid
        .keys()
        .map(|p| comm(*p))
        .filter(|c| !EXCLUDE_COMMS.contains(&c.as_str()))
        .collect();
    let mut groups: BTreeMap<String, (u64, u64, Vec<u64>)> = BTreeMap::new();
    let Ok(entries) = fs::read_dir("/proc") else {
        return Vec::new();
    };
    for e in entries.flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<u64>().ok()) else {
            continue;
        };
        if windowed_set_contains(by_pid, pid) || pid == self_pid {
            continue;
        }
        let Ok(md) = fs::metadata(e.path()) else {
            continue;
        };
        if md.uid() != uid {
            continue;
        }
        let c = comm(pid);
        if EXCLUDE_COMMS.contains(&c.as_str()) || windowed_comms.contains(&c) {
            continue;
        }
        let r = rss_kb(pid);
        let g = groups.entry(c).or_insert((0, 0, Vec::new()));
        g.0 += r;
        g.1 += swap_kb(pid);
        g.2.push(pid);
    }
    let our_units = marker_units();
    let mut out: Vec<BgRec> = groups
        .into_iter()
        .filter_map(|(name, (rkb, skb, pids))| {
            let biggest = pids
                .iter()
                .max_by_key(|p| rss_kb(**p))
                .copied()
                .unwrap_or(0);
            let (mechanism, unit, frozen) = match proc_cgroup(biggest) {
                Some((cg, u)) if is_app_scope(&u) => {
                    let f = scope_frozen(&cg) || our_units.contains(&u);
                    ("scope", u, f)
                }
                _ => (
                    "signal",
                    String::new(),
                    marks.contains(&biggest) && pid_stopped(biggest),
                ),
            };
            // Floor applies only to running rows: a frozen app's RSS can be
            // squeezed to near zero and the row must NOT vanish. The floor
            // weighs rss+swap TOGETHER so a fully-swapped sleeper (tiny RSS,
            // hundreds of MB in swap — the classic idle server) still lists.
            if rkb + skb < MIN_BG_RSS_KB && !frozen {
                return None;
            }
            Some(BgRec {
                name,
                rss_mb: rkb / 1024,
                swap_mb: skb / 1024,
                procs: pids.len(),
                pid: biggest,
                unit,
                mechanism,
                frozen,
            })
        })
        .collect();
    out.sort_by(|a, b| (b.rss_mb + b.swap_mb).cmp(&(a.rss_mb + a.swap_mb)));
    out.truncate(40);
    out
}

fn windowed_set_contains(by_pid: &BTreeMap<u64, Vec<Win>>, pid: u64) -> bool {
    by_pid.contains_key(&pid)
}

/// System daemons: processes NOT owned by the session user, grouped by comm,
/// sorted by RSS. Informational only — we cannot (and must not) signal
/// foreign pids, so the UI renders no action buttons for these rows.
fn collect_system(by_pid: &BTreeMap<u64, Vec<Win>>) -> Vec<BgRec> {
    system_groups(by_pid).into_iter().map(|(r, _)| r).collect()
}

/// The top system groups with every pid of each: the history sums their
/// CPU (comm_family only knows the user's own pids).
fn system_groups(by_pid: &BTreeMap<u64, Vec<Win>>) -> Vec<(BgRec, Vec<u64>)> {
    use std::os::unix::fs::MetadataExt;
    let uid = current_uid();
    let self_pid = std::process::id() as u64;
    let windowed_comms: Vec<String> = by_pid
        .keys()
        .map(|p| comm(*p))
        .filter(|c| !EXCLUDE_COMMS.contains(&c.as_str()))
        .collect();
    let mut groups: BTreeMap<String, (u64, Vec<u64>)> = BTreeMap::new();
    let Ok(entries) = fs::read_dir("/proc") else {
        return Vec::new();
    };
    for e in entries.flatten() {
        let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<u64>().ok()) else {
            continue;
        };
        if windowed_set_contains(by_pid, pid) || pid == self_pid {
            continue;
        }
        let Ok(md) = fs::metadata(e.path()) else {
            continue;
        };
        if md.uid() == uid {
            continue; // ours: already listed under Apps/Background
        }
        let c = comm(pid);
        if EXCLUDE_COMMS.contains(&c.as_str()) || windowed_comms.contains(&c) {
            continue;
        }
        let r = rss_kb(pid);
        if r == 0 {
            continue; // kernel threads carry no RSS
        }
        let g = groups.entry(c).or_insert((0, Vec::new()));
        g.0 += r;
        g.1.push(pid);
    }
    let mut out: Vec<(BgRec, Vec<u64>)> = groups
        .into_iter()
        .map(|(name, (rkb, pids))| {
            let rec = BgRec {
                name,
                rss_mb: rkb / 1024,
                swap_mb: 0, // system daemons: informational only, no swap tally
                procs: pids.len(),
                pid: pids.iter().copied().max().unwrap_or(0),
                unit: String::new(),
                mechanism: "signal",
                frozen: false,
            };
            (rec, pids)
        })
        .collect();
    out.sort_by(|a, b| b.0.rss_mb.cmp(&a.0.rss_mb));
    // Keep it short: this section shares the scroll viewport with the app
    // list — 6 top offenders usually fit without pushing it below the fold.
    out.truncate(6);
    out
}

/// `brief`: windowed apps only (no background/system scans) for the polls
/// while the card is closed: the veils and the pill need nothing else.
fn cmd_state(brief: bool) {
    let mons = monitors();
    let mut by_pid: BTreeMap<u64, Vec<Win>> = BTreeMap::new();
    for w in clients(&mons) {
        by_pid.entry(w.pid).or_default().push(w);
    }

    let our_marks = marker_pids();
    let our_units = marker_units();
    let mut apps = Vec::new();
    for (pid, wins) in &by_pid {
        let c = comm(*pid);
        if EXCLUDE_COMMS.contains(&c.as_str()) {
            continue;
        }
        // ONE row per app: RSS/procs cover the whole comm family (the
        // "background" scope-mates are inside this row's tree).
        let family = comm_family(*pid);
        let scopes = family_scopes(&family);
        let rss_total_kb: u64 = family.iter().map(|p| rss_kb(*p)).sum();
        let (mechanism, unit, frozen) = if !scopes.is_empty() {
            // Frozen = kernel says so OR we marked the unit (covers the
            // async freeze transition, when RSS may already be squeezed
            // below the listing floor and the row would otherwise vanish).
            let f = scopes.iter().any(|(cg, _)| scope_frozen(cg))
                || scopes.iter().any(|(_, u)| our_units.contains(u));
            ("scope", scopes[0].1.clone(), f)
        } else {
            // Signal mechanism: only report apps WE stopped (self-stopped
            // processes like updaters must not show up as paused).
            let marked = our_marks.contains(pid) && pid_stopped(*pid);
            let u = proc_cgroup(*pid).map(|(_, u)| u).unwrap_or_default();
            ("signal", u, marked)
        };
        // Windowed apps ALWAYS list: their window is on screen. No RSS floor
        // — a just-thawed app sits below it while its pages fault back in
        // from swap, and hiding the row then makes it "vanish after resume".
        apps.push((
            *pid,
            wins,
            mechanism,
            rss_total_kb / 1024,
            frozen,
            unit,
            family.len(),
        ));
    }
    apps.sort_by(|a, b| b.3.cmp(&a.3));
    apps.truncate(MAX_APPS);

    let mut out = String::from("\"apps\":[");
    let mut first = true;
    for (pid, wins, mechanism, rss_mb, frozen, unit, nprocs) in &apps {
        if !first {
            out.push(',');
        }
        first = false;
        let wins_json: Vec<String> = wins.iter().take(64).map(win_json).collect();
        let c = comm(*pid);
        out.push_str(&format!(
            "{{\"pid\":{pid},\"start\":{},\"name\":\"{}\",\"title\":\"{}\",\"class\":\"{}\",\"rss_mb\":{rss_mb},\"unit\":\"{}\",\"mechanism\":\"{mechanism}\",\"frozen\":{frozen},\"windows\":{},\"procs\":{nprocs},\"wins\":[{}]}}",
            start_time(*pid).unwrap_or(0),
            json_escape(&c),
            json_escape(&wins[0].title),
            json_escape(&wins[0].class),
            json_escape(unit),
            wins.len(),
            wins_json.join(",")
        ));
    }
    out.push(']');

    let background = if brief { Vec::new() } else { collect_background(&by_pid, &our_marks) };
    let mut bg_json = String::from("\"background\":[");
    let mut first = true;
    for b in &background {
        if !first {
            bg_json.push(',');
        }
        first = false;
        bg_json.push_str(&format!(
            "{{\"pid\":{},\"start\":{},\"name\":\"{}\",\"rss_mb\":{},\"swap_mb\":{},\"procs\":{},\"unit\":\"{}\",\"mechanism\":\"{}\",\"frozen\":{}}}",
            b.pid,
            start_time(b.pid).unwrap_or(0),
            json_escape(&b.name),
            b.rss_mb,
            b.swap_mb,
            b.procs,
            json_escape(&b.unit),
            b.mechanism,
            b.frozen
        ));
    }
    bg_json.push(']');

    // System daemons (not ours): same row shape, no actionable fields.
    let system = if brief { Vec::new() } else { collect_system(&by_pid) };
    let mut sys_json = String::from("\"system\":[");
    let mut first = true;
    for s in &system {
        if !first {
            sys_json.push(',');
        }
        first = false;
        sys_json.push_str(&format!(
            "{{\"pid\":{},\"start\":{},\"name\":\"{}\",\"rss_mb\":{},\"procs\":{}}}",
            s.pid,
            start_time(s.pid).unwrap_or(0),
            json_escape(&s.name),
            s.rss_mb,
            s.procs
        ));
    }
    sys_json.push(']');

    let mons_json: Vec<String> = mons
        .iter()
        .map(|(name, ws, x, y, focused, w, h)| {
            format!(
                "{{\"name\":\"{}\",\"active_ws\":{ws},\"x\":{x},\"y\":{y},\"focused\":{focused},\"w\":{w},\"h\":{h}}}",
                json_escape(name)
            )
        })
        .collect();

    let (total, avail, psi, psi_full, swap_total, swap_used) = mem_info();
    let (zswap_avail, zswap_on, zram_backed) = zswap_status();
    let (avail_pct, critical) = pressure(total, avail, psi, psi_full);
    let now_json = match now_from_history() {
        Some((c, m)) => format!("{{\"cpu\":{c:.1},\"mem\":{m:.1}}}"),
        None => "null".to_string(),
    };
    let prefs = read_prefs().to_string();

    // Suggestions: evidence-based, each with an optional one-click action.
    let mut sug: Vec<String> = Vec::new();
    for b in &background {
        // Fully-swapped sleeper: the idle-llama-server pattern. Tiny RSS,
        // big swap — closing it returns the swap immediately.
        if !b.frozen && b.swap_mb >= 200 && b.rss_mb <= 100 {
            let Some(st) = start_time(b.pid) else { continue };
            sug.push(
                json!({
                    "kind": "sleeper",
                    "name": cap_str(&b.name),
                    "swap_mb": b.swap_mb,
                    "text": format!(
                        "{} has {} MB asleep in swap; closing it frees that memory",
                        cap_str(&b.name),
                        b.swap_mb
                    ),
                    "action": "kill",
                    "pid": b.pid,
                    "start": st
                })
                .to_string(),
            );
        }
    }
    // Governor at work: say what is being held back, so slow builds are
    // explained instead of looking broken.
    let gov: Value = json::from_str(&governor::status_json()).unwrap_or(Value::Null);
    if let Some(lim) = gov.get("limited").and_then(|v| v.as_array()) {
        if !lim.is_empty() {
            let names: Vec<String> = lim
                .iter()
                .take(3)
                .filter_map(|e| Some(format!("{} ≤{} MB", cap_str(e.get("name")?.as_str()?), e.get("high_mb")?.as_u64()?)))
                .collect();
            sug.push(
                json!({
                    "kind": "governor",
                    "count": lim.len(),
                    "names": names.join(", "),
                    "text": format!(
                        "Holding back {} background process(es) to keep the desktop smooth: {}",
                        lim.len(),
                        names.join(", ")
                    ),
                    "action": "none",
                    "pid": 0
                })
                .to_string(),
            );
        }
    }
    if avail_pct < 25.0 {
        sug.push(
            "{\"kind\":\"pressure\",\"text\":\"Memory pressure is high: pause the apps you are not using\",\"action\":\"none\",\"pid\":0}".to_string(),
        );
    }
    let sug_json = format!("\"suggestions\":[{}]", sug.join(","));
    let gov_json = if gov.is_null() { "null".to_string() } else { gov.to_string() };
    println!(
        "{{\"engine\":\"rust\",\"mem\":{{\"total_mb\":{total},\"avail_mb\":{avail},\"psi_some10\":{psi:.2},\"swap_total_mb\":{swap_total},\"swap_used_mb\":{swap_used}}},\"pressure\":{{\"avail_pct\":{avail_pct:.1},\"critical\":{critical}}},\"zswap\":{{\"available\":{zswap_avail},\"enabled\":{zswap_on},\"zram\":{zram_backed}}},\"governor\":{gov_json},\"now\":{now_json},\"prefs\":{prefs},\"monitors\":[{}],{out},{bg_json},{sys_json},{sug_json}}}",
        mons_json.join(",")
    );
}

/// All window clients whose pid belongs to the same app (scope mates).
fn app_windows(pid: u64) -> Vec<Win> {
    let mons = monitors();
    let members: Vec<u64> = match proc_cgroup(pid) {
        Some((cgpath, unit)) if is_app_scope(&unit) => unit_procs(&cgpath),
        _ => vec![pid],
    };
    clients(&mons)
        .into_iter()
        .filter(|w| members.contains(&w.pid))
        .collect()
}

/// A command's process argument: `PID` or `PID:START`.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Target {
    pid: u64,
    start: Option<u64>,
}

fn parse_target(arg: &str) -> Option<Target> {
    let (p, s) = match arg.split_once(':') {
        Some((p, s)) => (p, Some(s)),
        None => (arg, None),
    };
    if p.is_empty() || !p.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let pid: u64 = p.parse().ok().filter(|p| *p > 1 && *p <= i32::MAX as u64)?;
    let start = match s {
        Some(s) if !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit()) => Some(s.parse().ok()?),
        Some(_) => return None,
        None => None,
    };
    Some(Target { pid, start })
}

/// The pid must still name the process the caller saw: pinned with a pidfd
/// first, then compared by start time. Returns the verified start time;
/// exits 3 (doing nothing) when the process is gone or the pid was reused.
fn verify(t: Target) -> u64 {
    let pinned = sys::Pidfd::open(t.pid);
    let now = start_time(t.pid);
    match (pinned, now) {
        (Ok(_), Some(now)) if t.start.is_none_or(|s| s == now) => now,
        _ => {
            eprintln!("task-manager: pid {} is gone or was reused; nothing done", t.pid);
            std::process::exit(3);
        }
    }
}

/// Freeze an app family (cgroup freezer per scope, signals outside scopes).
fn freeze_family(pid: u64) -> Marker {
    let mut stopped = Marker { pids: Vec::new(), scopes: Vec::new() };
    let c = comm(pid);
    let family = comm_family(pid);
    let scopes = family_scopes(&family);
    if scopes.is_empty() {
        // No scope: signal-stop every family member.
        for p in &family {
            if signal_member(*p, &c, sys::SIGSTOP) {
                marker_add(*p);
                if let Some(st) = start_time(*p) {
                    stopped.pids.push((*p, st));
                }
            }
        }
        return stopped;
    }
    for (cgpath, _) in &scopes {
        if cg_write(cgpath, "cgroup.freeze", "1") {
            marker_add_scope(cgpath);
            stopped.scopes.push(cgpath.clone());
        }
        // Squeeze: let the kernel reclaim the frozen app's cold pages.
        let cur = mem_current(cgpath);
        if cur > 0 {
            let target = (cur / 4).clamp(SQUEEZE_MIN_BYTES, SQUEEZE_MAX_BYTES);
            set_memory_high(cgpath, &target.to_string());
        }
    }
    // Family members living outside any app scope: signal-stop them too.
    let scoped: Vec<u64> = scopes.iter().flat_map(|(cg, _)| unit_procs(cg)).collect();
    for p in &family {
        if !scoped.contains(p) && signal_member(*p, &c, sys::SIGSTOP) {
            marker_add(*p);
            if let Some(st) = start_time(*p) {
                stopped.pids.push((*p, st));
            }
        }
    }
    stopped
}

fn thaw_family(pid: u64) {
    let c = comm(pid);
    let family = comm_family(pid);
    let scopes = family_scopes(&family);
    for (cgpath, _) in &scopes {
        // Restore headroom BEFORE resuming so the app can allocate.
        set_memory_high(cgpath, "max");
        cg_write(cgpath, "cgroup.freeze", "0");
        marker_remove_scope(cgpath);
    }
    for p in &family {
        // CONT is a no-op for running processes; stopped stragglers (or a
        // scope-less family) resume.
        if scopes.is_empty() || pid_stopped(*p) {
            signal_member(*p, &c, sys::SIGCONT);
        }
        marker_remove(*p);
    }
}

fn cmd_freeze(t: Target) {
    verify(t);
    freeze_family(t.pid);
}

fn cmd_thaw(t: Target) {
    verify(t);
    thaw_family(t.pid);
}

fn cmd_focus(t: Target) {
    verify(t);
    if let Some(w) = app_windows(t.pid).first() {
        if hypr::valid_address(&w.address) {
            hypr::dispatch(&format!(r#"hl.dsp.focus({{ window = "address:{}" }})"#, w.address));
        }
    }
}

fn cmd_kill(t: Target) {
    verify(t);
    let c = comm(t.pid);
    // Pin every member BEFORE anything changes: the TERM/KILL below then go
    // to these exact processes, whatever pids the kernel hands out meanwhile.
    let pinned: Vec<sys::Pidfd> = comm_family(t.pid)
        .into_iter()
        .filter_map(|p| {
            let fd = sys::Pidfd::open(p).ok()?;
            (comm(p) == c && owned_by_us(p)).then_some(fd)
        })
        .collect();
    // A frozen process cannot handle SIGTERM until resumed.
    thaw_family(t.pid);
    for fd in &pinned {
        fd.signal(sys::SIGTERM);
    }
    kill_survivors(&pinned);
}

/// starttime (field 22) from the text of /proc/PID/stat; None for zombies.
fn parse_starttime(stat: &str) -> Option<u64> {
    let rest = stat.get(stat.rfind(')')? + 1..)?;
    let f: Vec<&str> = rest.split_whitespace().collect();
    if matches!(f.first(), Some(&"Z") | Some(&"X")) {
        return None; // dead, waiting to be reaped
    }
    f.get(19)?.parse().ok()
}

/// Start time (clock ticks since boot) from /proc/PID/stat: tells a pid
/// that is still ours from one the kernel reused after we signalled it.
fn start_time(pid: u64) -> Option<u64> {
    parse_starttime(&read_capped(&format!("/proc/{pid}/stat"), CAP_STATUS)?)
}

/// A hung app ignores SIGTERM (its handler runs on the stuck main loop):
/// give it a grace period to exit cleanly, then SIGKILL whatever is left,
/// through the same pidfds.
fn kill_survivors(pinned: &[sys::Pidfd]) {
    const GRACE: std::time::Duration = std::time::Duration::from_millis(2500);
    let deadline = std::time::Instant::now() + GRACE;
    while pinned.iter().any(|fd| !fd.exited(0)) && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    for fd in pinned.iter().filter(|fd| !fd.exited(0)) {
        fd.signal(sys::SIGKILL);
    }
}

// ---------- single-thread (subprocess) control ----------
// Browser tabs live in renderer pids INSIDE the app's scope, so the scope
// freezer cannot touch one process alone: freeze the scope and the whole
// browser pauses. Single-pid control therefore always uses signals + marker
// files, exactly like the no-scope fallback, and never touches memory.high.

/// Pause ONE subprocess (e.g. a hung browser tab/renderer).
fn cmd_freeze_pid(t: Target) {
    let st = verify(t);
    if pid_stopped(t.pid) {
        return;
    }
    if signal(t.pid, Some(st), sys::SIGSTOP) {
        marker_add(t.pid);
    }
}

/// Resume ONE subprocess paused with freeze-pid (or by anyone: CONT is a
/// no-op for a running process).
fn cmd_thaw_pid(t: Target) {
    let st = verify(t);
    signal(t.pid, Some(st), sys::SIGCONT);
    marker_remove(t.pid);
}

/// Close ONE subprocess: CONT first (a stopped process cannot die cleanly),
/// then SIGTERM (SIGKILL after a grace period). Killing a renderer shows the
/// browser's per-tab crash page, which is what the user wants for a hung tab.
fn cmd_kill_pid(t: Target) {
    let Ok(fd) = sys::Pidfd::open(t.pid) else {
        verify(t); // exits 3
        return;
    };
    let st = verify(t);
    if start_time(t.pid) != Some(st) {
        return;
    }
    fd.signal(sys::SIGCONT);
    marker_remove(t.pid);
    fd.signal(sys::SIGTERM);
    kill_survivors(&[fd]);
}

// ---------- live history (written by `watch`, read by state/history) ----------
const HISTORY: &str = "history.json";
const PREFS: &str = "prefs.json";
const EMPTY_HISTORY: &str = "{\"ts\":[],\"cpu\":[],\"mem\":[],\"gpu\":null,\"cores\":[],\"apps\":{}}";

/// Writable UI prefs: (key, kind). Kinds: bool, mode, sort, px, ram, cpu.
const PREF_KEYS: &[(&str, &str)] = &[
    ("barStats", "bool"),
    ("showGraphs", "bool"),
    ("graphDetail", "bool"),
    ("sparklines", "bool"),
    ("veils", "bool"),
    ("watchdog", "bool"),
    ("barMode", "mode"),
    ("cardW", "px"),
    ("cardH", "px"),
    ("sortBy", "sort"),
    ("watchMaxRam", "ram"),
    ("watchMaxCpu", "cpu"),
    ("engine", "engine"),
];

/// Validate one pref value; Some(json value) when acceptable.
fn pref_value(kind: &str, value: &str) -> Option<Value> {
    match kind {
        "bool" => match value {
            "1" | "true" => Some(json!(true)),
            "0" | "false" => Some(json!(false)),
            _ => None,
        },
        // Tri-state pill display: off / numbers / numbers+graph.
        "mode" => ["off", "numbers", "graph"].contains(&value).then(|| json!(value)),
        "sort" => ["ram", "cpu", "name"].contains(&value).then(|| json!(value)),
        // Which engine the card runs: auto (Rust when built) or light (Python).
        "engine" => ["auto", "light"].contains(&value).then(|| json!(value)),
        // Persisted card geometry (px, sanity-clamped), kept as a string.
        "px" => value
            .parse::<u32>()
            .ok()
            .filter(|n| (300..=3000).contains(n))
            .map(|n| json!(n.to_string())),
        // Watchdog thresholds (%): RAM used 50..=99; CPU 0 (off) or 50..=99.
        "ram" => value.parse::<u32>().ok().filter(|n| (50..=99).contains(n)).map(|n| json!(n)),
        "cpu" => value
            .parse::<u32>()
            .ok()
            .filter(|n| *n == 0 || (50..=99).contains(n))
            .map(|n| json!(n)),
        _ => None,
    }
}

/// Prefs as stored, keeping only known keys with values of the right shape
/// (the file is re-validated on every read, never echoed raw).
fn read_prefs() -> Value {
    let raw = state_dir().and_then(|d| d.read_string(PREFS)).unwrap_or_default();
    let v = json::from_str(&raw).unwrap_or(Value::Null);
    let mut out = json!({});
    for (k, kind) in PREF_KEYS {
        let Some(x) = v.get(k) else { continue };
        let ok = match (*kind, x) {
            ("bool", Value::Bool(_)) => true,
            ("mode" | "sort" | "px" | "engine", Value::String(s)) => pref_value(kind, s).is_some(),
            ("ram" | "cpu", n) => n.as_u64().is_some_and(|n| pref_value(kind, &n.to_string()).is_some()),
            _ => false,
        };
        if ok {
            out[*k] = x.clone();
        }
    }
    out
}

/// utime+stime jiffies for a pid (robust against spaces/parens in comm).
fn proc_jiffies(pid: u64) -> u64 {
    let Some(text) = read_capped(&format!("/proc/{pid}/stat"), CAP_STATUS) else {
        return 0;
    };
    let Some(rp) = text.rfind(')') else {
        return 0;
    };
    let f: Vec<&str> = text.get(rp + 1..).unwrap_or("").split_whitespace().collect();
    let u: u64 = f.get(11).and_then(|s| s.parse().ok()).unwrap_or(0);
    let s: u64 = f.get(12).and_then(|s| s.parse().ok()).unwrap_or(0);
    u + s
}

/// (busy, total, per-core (busy,total)) from /proc/stat.
fn cpu_times() -> (u64, u64, Vec<(u64, u64)>) {
    let Some(text) = read_trim("/proc/stat") else {
        return (0, 0, Vec::new());
    };
    let mut total = (0u64, 0u64);
    let mut cores = Vec::new();
    for line in text.lines() {
        let is_total = line.starts_with("cpu ");
        let is_core =
            line.len() > 4 && line.starts_with("cpu") && line.as_bytes()[3].is_ascii_digit();
        if !is_total && !is_core {
            continue;
        }
        let v: Vec<u64> = line
            .split_whitespace()
            .skip(1)
            .filter_map(|s| s.parse().ok())
            .collect();
        if v.len() < 5 {
            continue;
        }
        let busy = v[0] + v[1] + v[2] + v[5] + v[6] + v.get(7).copied().unwrap_or(0);
        let all = busy + v[3] + v[4];
        if is_total {
            total = (busy, all);
        } else {
            cores.push((busy, all));
        }
    }
    (total.0, total.1, cores)
}

const HIST_LEN: usize = 120; // 2s cadence -> 4 minutes

struct Hist {
    ts: Vec<u64>,
    cpu: Vec<f32>,
    mem: Vec<f32>,
    cores: Vec<Vec<f32>>,
    apps: BTreeMap<String, (Vec<f32>, Vec<f32>)>, // key -> (rss_mb, cpu_pct)
    last_seen: BTreeMap<String, usize>,
    tick: usize,
}

impl Hist {
    fn new() -> Self {
        Self {
            ts: Vec::new(),
            cpu: Vec::new(),
            mem: Vec::new(),
            cores: Vec::new(),
            apps: BTreeMap::new(),
            last_seen: BTreeMap::new(),
            tick: 0,
        }
    }

    fn push(&mut self, cpu: f32, mem: f32, cores: Vec<f32>, apps: Vec<(String, f32, f32)>) {
        self.tick += 1;
        self.ts.push(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
        );
        self.cpu.push(cpu);
        self.mem.push(mem);
        self.cores.push(cores);
        for (k, rss, c) in apps {
            let e = self.apps.entry(k.clone()).or_insert_with(|| {
                let pad = self.ts.len().saturating_sub(1);
                (vec![0.0; pad], vec![0.0; pad])
            });
            e.0.push(rss);
            e.1.push(c);
            self.last_seen.insert(k, self.tick);
        }
        // keep every app series aligned with ts
        for e in self.apps.values_mut() {
            while (e.0.len() as usize) < self.ts.len() {
                e.0.push(*e.0.last().unwrap_or(&0.0));
                e.1.push(0.0);
            }
        }
        // prune apps gone for 30+ samples
        let cur = self.tick;
        let seen = &self.last_seen;
        self.apps
            .retain(|k, _| cur - seen.get(k).copied().unwrap_or(0) < 30);
        // cap length
        if self.ts.len() > HIST_LEN {
            let drop = self.ts.len() - HIST_LEN;
            self.ts.drain(0..drop);
            self.cpu.drain(0..drop);
            self.mem.drain(0..drop);
            self.cores.drain(0..drop);
            for e in self.apps.values_mut() {
                e.0.drain(0..drop.min(e.0.len()));
                e.1.drain(0..drop.min(e.1.len()));
            }
        }
    }

    fn to_json(&self) -> String {
        let f32s = |v: &[f32]| {
            v.iter()
                .map(|x| format!("{x:.1}"))
                .collect::<Vec<_>>()
                .join(",")
        };
        let cores: Vec<String> = self
            .cores
            .iter()
            .map(|c| format!("[{}]", f32s(c)))
            .collect();
        let apps: Vec<String> = self
            .apps
            .iter()
            .map(|(k, (rss, cpu))| {
                format!(
                    "\"{}\":{{\"rss\":[{}],\"cpu\":[{}]}}",
                    json_escape(k),
                    f32s(rss),
                    f32s(cpu)
                )
            })
            .collect();
        format!(
            "{{\"ts\":[{}],\"cpu\":[{}],\"mem\":[{}],\"gpu\":null,\"cores\":[{}],\"apps\":{{{}}}}}",
            self.ts
                .iter()
                .map(|t| t.to_string())
                .collect::<Vec<_>>()
                .join(","),
            f32s(&self.cpu),
            f32s(&self.mem),
            cores.join(","),
            apps.join(",")
        )
    }

    fn write(&self) {
        if let Some(d) = runtime() {
            let _ = d.write_atomic(HISTORY, self.to_json().as_bytes());
        }
    }
}

/// Latest instantaneous values from the history tail (if the daemon is alive).
fn now_from_history() -> Option<(f32, f32)> {
    let text = runtime()?.read_string(HISTORY)?;
    let v = json::from_str(&text).ok()?;
    let cpu = v.get("cpu")?.as_array()?.last()?.as_f64()? as f32;
    let mem = v.get("mem")?.as_array()?.last()?.as_f64()? as f32;
    let ts = v.get("ts")?.as_array()?.last()?.as_u64()?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .ok()?
        .as_secs();
    if now.saturating_sub(ts) > 15 {
        return None; // daemon dead or stale
    }
    Some((cpu, mem))
}

/// Per-process rows for the tree view: the WHOLE family (same comm), so
/// background scope-mates appear inside the app's tree.
fn cmd_procs(t: Target) {
    verify(t);
    let pid = t.pid;
    let members = comm_family(pid);
    // Hierarchy beats raw size: the browser main process first, then
    // renderers by RSS (the actual tab cost), then service roles, with
    // zygote/crashpad anchors last. Processes with no role (every non-Chromium
    // app) share rank 1 and stay purely RSS-ordered, as before.
    let mut rows: Vec<(u64, String, u64, String, String)> = members
        .iter()
        .map(|p| {
            let state = read_capped(&format!("/proc/{p}/stat"), CAP_STATUS)
                .and_then(|t| t.rfind(')').and_then(|rp| t.get(rp + 1..).map(str::to_string)))
                .and_then(|rest| rest.split_whitespace().next().and_then(|s| s.chars().next()))
                .filter(|c| c.is_ascii_alphabetic())
                .map(|c| c.to_string())
                .unwrap_or_else(|| "?".into());
            (
                *p,
                comm(*p),
                rss_kb(*p) / 1024,
                state,
                if *p == pid {
                    "browser".to_string()
                } else {
                    proc_role(*p)
                },
            )
        })
        .collect();
    fn role_rank(r: &str) -> u8 {
        match r {
            "browser" => 0,
            "renderer" => 1,
            "gpu" => 2,
            "network" => 3,
            "audio" => 4,
            "utility" | "storage" => 5,
            "zygote" => 6,
            "crashpad" => 7,
            _ => 1, // unknown roles sort with renderers, sized
        }
    }
    rows.sort_by(|a, b| role_rank(&a.4).cmp(&role_rank(&b.4)).then(b.2.cmp(&a.2)));
    rows.truncate(40);
    let json: Vec<String> = rows
        .iter()
        .map(|(p, c, r, s, role)| {
            format!(
                "{{\"pid\":{p},\"start\":{},\"comm\":\"{}\",\"role\":\"{}\",\"rss_mb\":{r},\"state\":\"{s}\"}}",
                start_time(*p).unwrap_or(0),
                json_escape(c),
                json_escape(role)
            )
        })
        .collect();
    println!("[{}]", json.join(","));
}

/// Set a UI preference (persisted, read back via state.prefs).
fn cmd_pref(key: &str, value: &str) {
    let Some((_, kind)) = PREF_KEYS.iter().find(|(k, _)| *k == key) else {
        return;
    };
    let Some(val) = pref_value(kind, value) else {
        return;
    };
    let mut v = read_prefs();
    v[key] = val;
    if let Some(d) = state_dir() {
        let _ = d.write_atomic(PREFS, v.to_string().as_bytes());
    }
}

/// The history the watchdog wrote, re-serialized (never echoed raw).
fn cmd_history() {
    let v = runtime()
        .and_then(|d| d.read_string(HISTORY))
        .and_then(|t| json::from_str(&t).ok())
        .filter(Value::is_object);
    match v {
        Some(v) => println!("{v}"),
        None => println!("{EMPTY_HISTORY}"),
    }
}

fn focused_pid() -> Option<u64> {
    hypr::query("activewindow")?.get("pid")?.as_u64()
}

/// Wait for sustained recovery, and space out resumes to observe their impact.
#[derive(Default)]
struct Recovery {
    since: Option<std::time::Instant>,
}

impl Recovery {
    fn ready(&mut self, now: std::time::Instant, healthy: bool) -> bool {
        if !healthy {
            self.since = None;
            return false;
        }
        let since = self.since.get_or_insert(now);
        if now.duration_since(*since) < std::time::Duration::from_secs(10) {
            return false;
        }
        self.since = Some(now);
        true
    }
}

fn recovery_healthy(
    total: u64, pct: f64, some: f64, full: f64,
    cpu: f32, cpu_max: f64, crit_avail: f64, recover: f64,
) -> bool {
    total > 0 && pct > recover.max(crit_avail * 1.5)
        && some < 10.0 && full < 1.0
        && (cpu_max <= 0.0 || (cpu as f64) < (cpu_max - 10.0).max(0.0))
}

struct AutoPause {
    name: String,
    mb: u64,
    owned: Marker,
    notification: Option<std::process::Child>,
}

impl Drop for AutoPause {
    fn drop(&mut self) {
        self.close_notification();
    }
}

impl AutoPause {
    fn close_notification(&mut self) {
        if let Some(mut child) = self.notification.take() {
            drop(child.stdin.take());
            std::thread::spawn(move || {
                let end = std::time::Instant::now() + std::time::Duration::from_secs(6);
                loop {
                    match child.try_wait() {
                        Ok(Some(_)) => break,
                        Ok(None) if std::time::Instant::now() < end =>
                            std::thread::sleep(std::time::Duration::from_millis(50)),
                        _ => { let _ = child.kill(); let _ = child.wait(); break; }
                    }
                }
            });
        }
    }
    fn prune(&mut self) -> bool {
        let m = marker_read();
        self.owned.pids.retain(|(p, st)| {
            m.pids.contains(&(*p, *st)) && start_time(*p) == Some(*st) && pid_stopped(*p)
        });
        self.owned.scopes.retain(|s| m.scopes.contains(s) && scope_frozen(s));
        let active = !self.owned.pids.is_empty() || !self.owned.scopes.is_empty();
        if !active { self.close_notification(); }
        active
    }

    fn resume(&mut self) -> bool {
        // Resume only the exact stops we recorded, not the whole comm family.
        self.owned.scopes.retain(|s| {
            if cg_write(s, "memory.high", "max") && cg_write(s, "cgroup.freeze", "0") {
                marker_remove_scope(s);
                false
            } else {
                true
            }
        });
        self.owned.pids.retain(|(p, st)| {
            if signal(*p, Some(*st), sys::SIGCONT) {
                marker_remove(*p);
                false
            } else {
                true
            }
        });
        let done = self.owned.pids.is_empty() && self.owned.scopes.is_empty();
        if done { self.close_notification(); }
        done
    }
}

/// Biggest candidate, excluding focused, stopped and cooling-down apps.
fn freeze_biggest(skip: &std::collections::BTreeSet<String>) -> Option<AutoPause> {
    let mons = monitors();
    let mut by_pid: BTreeMap<u64, Vec<Win>> = BTreeMap::new();
    for w in clients(&mons) {
        by_pid.entry(w.pid).or_default().push(w);
    }
    let marks = marker_pids();
    let marked_scopes = marker_read().scopes;
    let focus = focused_pid();
    let focus_unit = focus.and_then(|p| proc_cgroup(p).map(|(_, u)| u));

    let mut best: Option<(u64, String, u64)> = None; // (pid, name, rss_mb)
    let mut consider = |pid: u64, name: String, rss_kb: u64, unit: String, frozen: bool| {
        if frozen || rss_kb < MIN_FREEZE_MB * 1024 {
            return;
        }
        if skip.contains(&name) {
            return;
        }
        if Some(pid) == focus {
            return;
        }
        if !unit.is_empty() && Some(&unit) == focus_unit.as_ref() {
            return;
        }
        let mb = rss_kb / 1024;
        if best.as_ref().map(|b| mb > b.2).unwrap_or(true) {
            best = Some((pid, name, mb));
        }
    };

    for (pid, _) in &by_pid {
        let c = comm(*pid);
        if EXCLUDE_COMMS.contains(&c.as_str()) {
            continue;
        }
        let family = comm_family(*pid);
        let scopes = family_scopes(&family);
        let total: u64 = family.iter().map(|p| rss_kb(*p)).sum();
        let frozen = family.iter().any(|p| marks.contains(p) || pid_stopped(*p))
            || scopes.iter().any(|(cg, _)| scope_frozen(cg) || marked_scopes.contains(cg));
        let unit = scopes.first().map(|(_, u)| u.clone()).unwrap_or_default();
        consider(*pid, c, total, unit, frozen);
    }
    for bg in collect_background(&by_pid, &marks) {
        // Auto-freeze only via scope (atomic, reversible) — no signal stops.
        if bg.mechanism == "scope" {
            let family = comm_family(bg.pid);
            let paused = bg.frozen
                || family.iter().any(|p| marks.contains(p) || pid_stopped(*p))
                || family_scopes(&family).iter().any(|(cg, _)| {
                    scope_frozen(cg) || marked_scopes.contains(cg)
                });
            consider(bg.pid, bg.name, bg.rss_mb * 1024, String::new(), paused);
        }
    }

    let (pid, name, mb) = best?;
    let before = marker_read();
    let mut owned = freeze_family(pid);
    owned.pids.retain(|p| !before.pids.contains(p));
    owned.scopes.retain(|s| !before.scopes.contains(s));
    if owned.pids.is_empty() && owned.scopes.is_empty() {
        return None;
    }
    // The user must KNOW an app was auto-paused, or it looks like a crash.
    let (title, body) = notify_autopause_text(&name, mb);
    // Both engines use the same bounded renderer and notification lifetime.
    // The release executable lives at bin/task-manager-rs/target/release.
    let helper = env::current_exe().ok().and_then(|p| {
        p.ancestors().nth(4).map(|bin| bin.join("pause-notification.py"))
    });
    let notification = helper.and_then(|p| Command::new("python3")
        .args(["-I", "-S"]).arg(p).args([&name, &cap_str(&title), &body])
        .stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().ok());
    Some(AutoPause { name, mb, owned, notification })
}

/// Localized auto-pause notification text (daemon has no i18n.json access).
fn notify_autopause_text(name: &str, mb: u64) -> (String, String) {
    let lang = env::var("LANGUAGE")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| env::var("LANG").ok())
        .unwrap_or_else(|| "en".to_string());
    let lang = lang.split([':', '.', '_']).next().unwrap_or("en");
    match lang {
        "es" => (
            format!("{name} pausada automáticamente ({mb} MB)"),
            "Se reanudará automáticamente cuando los recursos estén estables; también puedes reanudarla desde el Administrador de tareas.".to_string(),
        ),
        _ => (
            format!("{name} auto-paused ({mb} MB)"),
            "It will resume automatically once resources are stable; you can also resume it from the Task Manager.".to_string(),
        ),
    }
}

/// One full history sample: system cpu/mem, per-core, top-8 apps by RSS.
fn sample_history(
    hist: &mut Hist,
    prev: &mut (u64, u64, Vec<(u64, u64)>),
    prev_apps: &mut BTreeMap<u64, u64>,
) {
    let st = cpu_times();
    let dt = st.1.saturating_sub(prev.1).max(1);
    let cpu = st.0.saturating_sub(prev.0) as f32 * 100.0 / dt as f32;
    let mut core_pcts = Vec::new();
    for (i, (b, t)) in st.2.iter().enumerate() {
        let (pb, pt) = prev.2.get(i).copied().unwrap_or((*b, *t));
        let d = t.saturating_sub(pt).max(1);
        core_pcts.push(b.saturating_sub(pb) as f32 * 100.0 / d as f32);
    }
    let ncores = st.2.len().max(1) as f32;
    *prev = st;

    let (ttotal, tavail, _, _, _, _) = mem_info();
    let mem_pct = if ttotal > 0 {
        (ttotal - tavail) as f32 * 100.0 / ttotal as f32
    } else {
        0.0
    };

    let mons = monitors();
    let mut by_pid: BTreeMap<u64, Vec<Win>> = BTreeMap::new();
    for w in clients(&mons) {
        by_pid.entry(w.pid).or_default().push(w);
    }
    // One entry per history key (first RSS, union of pids), so each series
    // gets exactly one sample per tick.
    fn add(groups: &mut Vec<(String, f32, Vec<u64>)>, key: String, rss_mb: f32, pids: Vec<u64>) {
        if let Some(g) = groups.iter_mut().find(|g| g.0 == key) {
            for p in pids {
                if !g.2.contains(&p) {
                    g.2.push(p);
                }
            }
        } else {
            groups.push((key, rss_mb, pids));
        }
    }
    let mut groups: Vec<(String, f32, Vec<u64>)> = Vec::new();
    for pid in by_pid.keys() {
        let c = comm(*pid);
        if EXCLUDE_COMMS.contains(&c.as_str()) {
            continue;
        }
        // Family-wide series: matches the row's RSS (window + background).
        let family = comm_family(*pid);
        let rss: u64 = family.iter().map(|p| rss_kb(*p)).sum();
        let key = family_scopes(&family)
            .first()
            .map(|(_, u)| u.clone())
            .unwrap_or_else(|| format!("pid{pid}"));
        add(&mut groups, key, rss as f32 / 1024.0, family);
    }
    // Every background group gets its own series, keyed "bg:<comm>" (its
    // biggest pid can change between ticks, the name doesn't). Helpers that
    // share a windowed app's scope (a browser's "Isolated Web Co") also
    // count toward that app's row, so the row shows the whole app.
    let marks = marker_pids();
    for bg in collect_background(&by_pid, &marks) {
        let family = comm_family(bg.pid);
        if !bg.unit.is_empty() && groups.iter().any(|g| g.0 == bg.unit) {
            add(&mut groups, bg.unit.clone(), 0.0, family.clone());
        }
        add(&mut groups, format!("bg:{}", bg.name), bg.rss_mb as f32, family);
    }
    // System daemons: keyed "sys:<comm>", CPU summed over the group's pids
    // (/proc/<pid>/stat is world-readable, nothing is signalled).
    for (grp, pids) in system_groups(&by_pid) {
        add(&mut groups, format!("sys:{}", grp.name), grp.rss_mb as f32, pids);
    }
    // CPU per group = sum of per-pid jiffy deltas since the last tick. A pid
    // first seen this tick adds 0: summing raw totals instead counted a new
    // child's whole lifetime as one tick (false spikes on Firefox tabs).
    let mut next_pids: BTreeMap<u64, u64> = BTreeMap::new();
    let mut apps: Vec<(String, f32, f32)> = Vec::new();
    for (key, rss_mb, pids) in groups {
        let d: u64 = pids
            .iter()
            .map(|p| {
                let j = proc_jiffies(*p);
                next_pids.insert(*p, j);
                prev_apps.get(p).map_or(0, |pj| j.saturating_sub(*pj))
            })
            .sum();
        // dt spans every core, so d/dt is the share of the whole machine;
        // times ncores gives % of one core, like top (100% = a full core).
        apps.push((key, rss_mb, d as f32 * ncores * 100.0 / dt as f32));
    }
    apps.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    // Enough series for every listed row (windowed apps, up to 40
    // background groups and 6 system ones) to show CPU%.
    apps.truncate(72);
    *prev_apps = next_pids;
    hist.push(cpu, mem_pct, core_pcts, apps);
    hist.write();
}

/// Undo everything this engine froze or limited: governor limits first
/// (they skip scopes we froze), then every scope and pid in the marker.
fn release_everything() {
    let n = governor::release_all();
    let m = marker_read();
    for cg in &m.scopes {
        set_memory_high(cg, "max");
        cg_write(cg, "cgroup.freeze", "0");
    }
    for (p, st) in &m.pids {
        signal(*p, Some(*st), sys::SIGCONT);
    }
    marker_write(&Marker { pids: Vec::new(), scopes: Vec::new() });
    eprintln!(
        "task-manager watch: released {n} limit(s), thawed {} scope(s) and {} process(es)",
        m.scopes.len(),
        m.pids.len()
    );
}

static STOP: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn stopping() -> bool {
    STOP.load(std::sync::atomic::Ordering::SeqCst)
}

/// Lifeline: the parent (the shell) holds our stdin open; EOF means it is
/// gone, so the watchdog must not outlive it with apps left frozen.
fn start_lifeline() {
    std::thread::spawn(|| {
        use std::io::Read;
        let mut buf = [0u8; 256];
        let mut stdin = std::io::stdin();
        loop {
            match stdin.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
        }
        STOP.store(true, std::sync::atomic::Ordering::SeqCst);
    });
}

/// Sleep in short steps so a lifeline EOF is honoured quickly.
fn nap(ms: u64) {
    let mut left = ms;
    while left > 0 && !stopping() {
        let step = left.min(100);
        std::thread::sleep(std::time::Duration::from_millis(step));
        left -= step;
    }
}

/// Memory-pressure watchdog: freeze biggest apps while pressure is critical.
/// One per user (flock on the runtime dir's watch.lock): two governors would
/// fight over the same cgroups and the same governor.json.
fn cmd_watch(lifeline: bool) {
    let Some(rt) = runtime() else {
        std::process::exit(1);
    };
    let _lock = match rt.try_lock("watch.lock") {
        Ok(Some(fd)) => fd,
        Ok(None) => {
            println!("busy");
            std::process::exit(0);
        }
        Err(e) => {
            eprintln!("task-manager watch: lock: {e}");
            std::process::exit(1);
        }
    };
    if lifeline {
        start_lifeline();
    }
    eprintln!(
        "task-manager watch: pid {} crit avail<{:.0}%, or avail<{:.0}% + psi_full>{:.0}, sustained 5s, recover>{:.0}%, max {} per episode",
        std::process::id(),
        crit_avail_pct(),
        crit_avail_pct() * 1.5,
        crit_psi(),
        recover_avail_pct(),
        max_freeze_per_episode()
    );
    let mut hits = 0u32;
    let mut frozen_this_episode = 0u32;
    let mut hist = Hist::new();
    let mut prev_stat = cpu_times();
    let mut prev_cpu = cpu_times();
    let mut prev_apps: BTreeMap<u64, u64> = BTreeMap::new();
    // Per-app cooldown: never auto-freeze the same app twice within 10 min —
    // re-freezing the user's browser every pressure blip reads as "Chrome
    // keeps hanging".
    let mut last_frozen: BTreeMap<String, std::time::Instant> = BTreeMap::new();
    let mut auto_paused: Vec<AutoPause> = Vec::new();
    let mut recovery = Recovery::default();
    let mut no_candidates_since: Option<std::time::Instant> = None;
    let mut gov = governor::Governor::new();
    let mut tick = 0u32;
    loop {
        if stopping() {
            release_everything();
            std::process::exit(0);
        }
        let (total, avail, psi_some, psi_full, _, _) = mem_info();
        let (pct, mut crit) = pressure(total, avail, psi_some, psi_full);
        // Governor every 2s: squeeze background work early so the freeze
        // below stays a last resort.
        if tick % 4 == 0 {
            gov.tick(pct, psi_some);
        }
        // CPU trigger (pref watchMaxCpu, 0 = off): freeze the biggest app
        // when total CPU stays pegged — freezing stops the burn instantly.
        let cpu_max = crit_cpu_pct();
        let mut cpu_now = 0.0f32;
        if cpu_max > 0.0 {
            let st = cpu_times();
            let dt = st.1.saturating_sub(prev_cpu.1).max(1);
            cpu_now = st.0.saturating_sub(prev_cpu.0) as f32 * 100.0 / dt as f32;
            prev_cpu = st;
            if cpu_now >= cpu_max as f32 {
                crit = true;
            }
        }
        if crit {
            hits += 1;
        } else {
            hits = 0;
            no_candidates_since = None;
            if pct > recover_avail_pct() {
                frozen_this_episode = 0;
            }
        }
        auto_paused.retain_mut(AutoPause::prune);
        let healthy = recovery_healthy(total, pct, psi_some, psi_full, cpu_now, cpu_max,
                                       crit_avail_pct(), recover_avail_pct());
        if recovery.ready(std::time::Instant::now(), healthy && !auto_paused.is_empty()) {
            // Even a partially resumed app must remain freezable in an emergency.
            last_frozen.remove(&auto_paused[0].name);
            if auto_paused[0].resume() {
                let paused = auto_paused.remove(0);
                eprintln!("watch: resources stable — resumed {}", paused.name);
            }
        }
        // Sustained pressure only: 10 ticks × 500ms = 5s. Zram reclaim bursts
        // spike psi for 1-3s routinely; those must not freeze anything.
        if hits >= 10
            && frozen_this_episode < max_freeze_per_episode()
            && no_candidates_since.is_none()
        {
            // Cooldown names are excluded INSIDE the picker so a cooling-down
            // biggest app (Chrome) doesn't starve the next candidate.
            let skip: std::collections::BTreeSet<String> = last_frozen
                .iter()
                .filter(|(_, t)| t.elapsed() < std::time::Duration::from_secs(600))
                .map(|(n, _)| n.clone())
                .collect();
            match freeze_biggest(&skip) {
                Some(paused) => {
                    eprintln!(
                        "watch: pressure critical ({pct:.1}% avail, psi_some {psi_some:.1}, psi_full {psi_full:.1}, cpu {cpu_now:.0}%/{cpu_max:.0}) — froze {} ({} MB)", paused.name, paused.mb
                    );
                    last_frozen.insert(paused.name.clone(), std::time::Instant::now());
                    auto_paused.push(paused);
                    frozen_this_episode += 1;
                    hits = 0;
                    tick += 1;
                    nap(2000);
                    continue;
                }
                None => {
                    // Log once, then stay out of this episode: the loop's
                    // guard blocks further freeze attempts until pressure
                    // clears (no_candidates_since resets on the else branch).
                    // No extra sleep — the 500ms tick keeps sampling history.
                    eprintln!("watch: pressure critical but no candidates left");
                    hits = 0;
                    no_candidates_since = Some(std::time::Instant::now());
                }
            }
        }
        tick += 1;
        if tick % 4 == 0 {
            sample_history(&mut hist, &mut prev_stat, &mut prev_apps);
        }
        nap(500);
    }
}

fn usage() -> ! {
    eprintln!(
        "usage: task-manager <state [--brief]|freeze T|thaw T|focus T|kill T|freeze-pid T|thaw-pid T|kill-pid T|procs T|governor-explain|governor-release|pref K V|popup [0|1]|binds|veil-lock|shell-reset [force|list]|history|watch [--lifeline]|follow>  (T = PID or PID:START)"
    );
    std::process::exit(1)
}

/// Stream compositor events (Hyprland socket2), one per line, so the QML
/// veil layer can react INSTANTLY instead of polling: retop on focus,
/// follow on workspace moves, cleanup on close. Only veil-relevant events
/// are forwarded; lines are length-capped.
fn cmd_follow() {
    use std::io::Write;
    let mut out = std::io::stdout().lock();
    hypr::events(|l| {
        if l.starts_with("activewindowv2>>")
            || l.starts_with("movewindowv2>>")
            || l.starts_with("closewindow>>")
            || l.starts_with("openwindow>>")
            || l.starts_with("workspace>>")
            || l.starts_with("changefloatingmode>>")
        {
            // Consumer gone: stop.
            return writeln!(out, "{l}").is_ok() && out.flush().is_ok();
        }
        true
    });
}

/// Hold the veil-owner lock while our stdin (the shell) stays open: the
/// first BarWidget instance to get it renders the veils. The kernel drops
/// the lock when we exit, so a dead shell never leaves a stale owner.
fn cmd_veil_lock() {
    use std::io::{Read, Write};
    let lock = runtime().map(|d| d.try_lock("veil.lock"));
    let held = match lock {
        Some(Ok(Some(fd))) => fd,
        Some(Ok(None)) => {
            println!("busy");
            return;
        }
        _ => {
            println!("error");
            std::process::exit(1);
        }
    };
    let mut so = std::io::stdout();
    let _ = writeln!(so, "owned");
    let _ = so.flush();
    let mut buf = [0u8; 256];
    let mut stdin = std::io::stdin();
    while let Ok(n) = stdin.read(&mut buf) {
        if n == 0 {
            break;
        }
    }
    drop(held);
}

/// Shared popup-open flag (all BarWidget instances watch it).
fn cmd_popup(set: Option<&str>) {
    let Some(d) = runtime() else {
        std::process::exit(1);
    };
    match set {
        Some(v @ ("0" | "1")) => {
            if d.write_atomic("popup", v.as_bytes()).is_err() {
                std::process::exit(1);
            }
        }
        Some(_) => usage(),
        None => {
            let open = d
                .read_capped("popup", 16)
                .map(|b| b.first() == Some(&b'1'))
                .unwrap_or(false);
            println!("{}", if open { 1 } else { 0 });
        }
    }
}

/// Which of the Task Manager's optional Hyprland binds the user has set up.
fn cmd_binds() {
    let v = hypr::request_capped("j/binds", 2 * 1024 * 1024)
        .and_then(|t| json::from_str(&t).ok());
    let has = |desc: &str| {
        v.as_ref()
            .and_then(Value::as_array)
            .map(|a| a.iter().any(|b| b["description"].as_str() == Some(desc)))
            .unwrap_or(false)
    };
    println!(
        "{}",
        json!({"show": has("Task Manager"), "reset": has("Force reset shell")})
    );
}

fn target_arg(a: &str) -> Target {
    parse_target(a).unwrap_or_else(|| usage())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        usage();
    }
    let one = || -> Target {
        if args.len() != 3 {
            usage();
        }
        target_arg(&args[2])
    };
    match args[1].as_str() {
        "state" if args.len() == 2 => cmd_state(false),
        "state" if args.len() == 3 && args[2] == "--brief" => cmd_state(true),
        "freeze" => cmd_freeze(one()),
        "thaw" => cmd_thaw(one()),
        "focus" => cmd_focus(one()),
        "kill" => cmd_kill(one()),
        "freeze-pid" => cmd_freeze_pid(one()),
        "thaw-pid" => cmd_thaw_pid(one()),
        "kill-pid" => cmd_kill_pid(one()),
        "procs" => cmd_procs(one()),
        "governor-explain" => governor::cmd_explain(),
        "governor-release" => {
            let n = governor::release_all();
            println!("released {n}");
        }
        "watch" => match args.get(2).map(String::as_str) {
            None => cmd_watch(false),
            Some("--lifeline") => cmd_watch(true),
            Some(_) => usage(),
        },
        "follow" => cmd_follow(),
        "veil-lock" => cmd_veil_lock(),
        "popup" if args.len() <= 3 => cmd_popup(args.get(2).map(String::as_str)),
        "binds" => cmd_binds(),
        "history" => cmd_history(),
        "pref" if args.len() == 4 => cmd_pref(&args[2], &args[3]),
        "shell-reset" => match args.get(2).map(String::as_str) {
            Some("list") => shell::cmd_shell_reset_list(),
            Some("force") => shell::cmd_shell_reset(true),
            None => shell::cmd_shell_reset(false),
            Some(_) => usage(),
        },
        _ => usage(),
    }
}

#[cfg(test)]
mod tests {
    use super::{freeze_critical, parse_starttime, parse_target, pref_value, Target};

    #[test]
    fn recovery_waits_restarts_and_spaces_apps() {
        let mut r = super::Recovery::default();
        let now = std::time::Instant::now();
        let at = |secs| now + std::time::Duration::from_secs(secs);
        assert!(!r.ready(at(0), true));
        assert!(!r.ready(at(9), true));
        assert!(!r.ready(at(10), false));
        assert!(!r.ready(at(11), true));
        assert!(!r.ready(at(20), true));
        assert!(r.ready(at(21), true));
        assert!(!r.ready(at(22), true));
        assert!(r.ready(at(31), true));
        assert!(!r.ready(at(32), false));
    }

    #[test]
    fn recovery_requires_memory_psi_and_cpu_headroom() {
        let healthy = |total, pct, some, full, cpu, cpu_max, crit| {
            super::recovery_healthy(total, pct, some, full, cpu, cpu_max, crit, 12.0)
        };
        assert!(healthy(16000, 30.0, 0.0, 0.0, 50.0, 90.0, 6.0));
        assert!(!healthy(0, 30.0, 0.0, 0.0, 50.0, 90.0, 6.0));
        assert!(!healthy(16000, 12.0, 0.0, 0.0, 50.0, 90.0, 6.0));
        assert!(!healthy(16000, 30.0, 10.0, 0.0, 50.0, 90.0, 6.0));
        assert!(!healthy(16000, 30.0, 0.0, 1.0, 50.0, 90.0, 6.0));
        assert!(!healthy(16000, 30.0, 0.0, 0.0, 80.0, 90.0, 6.0));
        assert!(!healthy(16000, 30.0, 0.0, 0.0, 50.0, 90.0, 21.0));
        assert!(healthy(16000, 30.0, 0.0, 0.0, 100.0, 0.0, 6.0));
    }

    #[test]
    fn targets() {
        assert_eq!(parse_target("1234"), Some(Target { pid: 1234, start: None }));
        assert_eq!(parse_target("1234:987654"), Some(Target { pid: 1234, start: Some(987654) }));
        assert_eq!(parse_target("1234:"), None);
        assert_eq!(parse_target(":5"), None);
        assert_eq!(parse_target("-5"), None);
        assert_eq!(parse_target("1"), None);
        assert_eq!(parse_target("12x"), None);
        assert_eq!(parse_target("99999999999"), None);
        assert_eq!(parse_target("12:3:4"), None);
    }

    #[test]
    fn starttime() {
        // comm with spaces and parens; starttime is field 22.
        let stat = "4242 (Web (Content) x) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 6 0 0 20 0 1 0 778899 1000 50";
        assert_eq!(parse_starttime(stat), Some(778899));
        let zombie = "4242 (x) Z 1 4242 4242 0 -1 4194560 100 0 0 0 5 6 0 0 20 0 1 0 778899 1000 50";
        assert_eq!(parse_starttime(zombie), None);
        assert_eq!(parse_starttime("garbage"), None);
    }

    #[test]
    fn prefs_validation() {
        assert_eq!(pref_value("bool", "1").and_then(|v| v.as_bool()), Some(true));
        assert!(pref_value("bool", "yes").is_none());
        assert!(pref_value("mode", "graph").is_some());
        assert!(pref_value("mode", "x").is_none());
        assert!(pref_value("px", "200").is_none());
        assert!(pref_value("ram", "100").is_none());
        assert!(pref_value("cpu", "0").is_some());
    }

    #[test]
    fn freeze_only_at_real_scarcity() {
        // The 2026-10-20 false positive: 17% avail, psi_full 45.8.
        assert!(!freeze_critical(17.0, 6.0, 45.8, 30.0));
        // Plenty free, any stall: never.
        assert!(!freeze_critical(55.8, 6.0, 90.0, 30.0));
        // Below the critical margin: always.
        assert!(freeze_critical(5.0, 6.0, 0.0, 30.0));
        // Close to it with a severe stall: yes; with a mild one: no.
        assert!(freeze_critical(8.0, 6.0, 35.0, 30.0));
        assert!(!freeze_critical(8.0, 6.0, 15.0, 30.0));
    }
}
