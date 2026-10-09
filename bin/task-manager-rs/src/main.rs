//! omarchy-task-manager helper (POC v2).
//!
//! Usage:
//!   task-manager state          JSON: {mem:{...}, monitors:[...], apps:[...]}
//!   task-manager freeze <pid>   freeze app + squeeze its RAM (memory.high)
//!   task-manager thaw <pid>     restore memory.high + resume
//!   task-manager focus <pid>    focus the app's window
//!   task-manager kill <pid>     thaw + SIGTERM
//!
//! Freeze = cgroup v2 freezer via `systemctl --user freeze` (atomic per app).
//! While frozen, memory.high is lowered so the kernel reclaims the app's cold
//! pages to swap — RAM actually drops without killing the app.
//! The grey visual is rendered by the QML overlay (state JSON carries window
//! geometry for frozen apps); no compositor rules are needed.

use serde_json::Value;
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

const CGROOT: &str = "/sys/fs/cgroup";
/// Background comm-group floor.
const MIN_BG_RSS_KB: u64 = 30 * 1024;
/// Auto-freeze never targets apps smaller than this.
const MIN_FREEZE_MB: u64 = 100;
/// One-liner the user runs to enable zswap for this boot (shown in the UI).
const ZSWAP_ENABLE_CMD: &str = "sudo sh -c 'echo Y > /sys/module/zswap/parameters/enabled'";
/// Squeeze target while frozen: clamp(current/4, SQUEEZE_MIN, SQUEEZE_MAX).
const SQUEEZE_MIN_BYTES: u64 = 96 * 1024 * 1024;
const SQUEEZE_MAX_BYTES: u64 = 512 * 1024 * 1024;

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
];

fn runtime_dir() -> String {
    env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| format!("/run/user/{}", current_uid()))
}

fn current_uid() -> u32 {
    // No libc dep for one number: read the owner uid of /proc/self.
    use std::os::unix::fs::MetadataExt;
    fs::metadata("/proc/self").map(|m| m.uid()).unwrap_or(1000)
}

fn live_sig() -> String {
    let rd = runtime_dir();
    let cur = env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_default();
    if !cur.is_empty() && Path::new(&format!("{rd}/hypr/{cur}/.socket.sock")).exists() {
        return cur;
    }
    if let Ok(entries) = fs::read_dir(format!("{rd}/hypr")) {
        let mut names: Vec<String> = entries
            .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
            .collect();
        names.sort();
        for n in names {
            if Path::new(&format!("{rd}/hypr/{n}/.socket.sock")).exists() {
                return n;
            }
        }
    }
    cur
}

fn hyprctl(args: &[&str]) -> String {
    let out = Command::new("hyprctl")
        .args(args)
        .env("HYPRLAND_INSTANCE_SIGNATURE", live_sig())
        .output();
    match out {
        Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
        Err(_) => String::new(),
    }
}

#[derive(Clone)]
struct Win {
    pid: u64,
    address: String,
    title: String,
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
    let text = hyprctl(&["monitors", "-j"]);
    let Ok(Value::Array(arr)) = serde_json::from_str::<Value>(&text) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|m| {
            let name = m.get("name")?.as_str()?.to_string();
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
    let text = hyprctl(&["clients", "-j"]);
    let Ok(Value::Array(arr)) = serde_json::from_str::<Value>(&text) else {
        return Vec::new();
    };
    arr.iter()
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
                address: c.get("address")?.as_str()?.to_string(),
                title: c
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .chars()
                    .take(60)
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

fn read_trim(path: &str) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_string())
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
    let Some(status) = read_trim(&format!("/proc/{pid}/status")) else {
        return 0;
    };
    for line in status.lines() {
        if let Some(rest) = line.strip_prefix("VmRSS:") {
            return rest
                .split_whitespace()
                .next()
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
        }
    }
    0
}

fn comm(pid: u64) -> String {
    read_trim(&format!("/proc/{pid}/comm")).unwrap_or_else(|| "?".into())
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
/// own) must not show up as paused by us. Unit markers ALSO cover the async
/// cgroup.freeze transition window (freeze=0 until fully frozen, so right
/// after a freeze the row would vanish if its RSS already squeezed low).
fn marker_path() -> String {
    format!("{}/tm-frozen.json", runtime_dir())
}

fn marker_read() -> (Vec<u64>, Vec<String>) {
    let Some(text) = read_trim(&marker_path()) else {
        return (Vec::new(), Vec::new());
    };
    let Ok(v) = serde_json::from_str::<Value>(&text) else {
        return (Vec::new(), Vec::new());
    };
    let pids = v
        .get("pids")
        .and_then(|p| p.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_u64()).collect())
        .unwrap_or_default();
    let units = v
        .get("units")
        .and_then(|p| p.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();
    (pids, units)
}

fn marker_pids() -> Vec<u64> {
    marker_read().0
}

fn marker_units() -> Vec<String> {
    marker_read().1
}

fn marker_write(pids: &[u64], units: &[String]) {
    let pl: Vec<String> = pids.iter().map(|p| p.to_string()).collect();
    let ul: Vec<String> = units
        .iter()
        .map(|u| format!("\"{}\"", json_escape(u)))
        .collect();
    let _ = fs::write(
        marker_path(),
        format!(
            "{{\"pids\":[{}],\"units\":[{}]}}",
            pl.join(","),
            ul.join(",")
        ),
    );
}

fn marker_add(pid: u64) {
    let (mut p, u) = marker_read();
    if !p.contains(&pid) {
        p.push(pid);
    }
    marker_write(&p, &u);
}

fn marker_remove(pid: u64) {
    let (p, u) = marker_read();
    let p: Vec<u64> = p.into_iter().filter(|x| *x != pid).collect();
    marker_write(&p, &u);
}

fn marker_add_unit(unit: &str) {
    let (p, mut u) = marker_read();
    if !u.iter().any(|x| x == unit) {
        u.push(unit.to_string());
    }
    marker_write(&p, &u);
}

fn marker_remove_unit(unit: &str) {
    let (p, u) = marker_read();
    let u: Vec<String> = u.into_iter().filter(|x| x != unit).collect();
    marker_write(&p, &u);
}

fn mem_current(cgpath: &str) -> u64 {
    read_trim(&format!("{CGROOT}{cgpath}/memory.current"))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

fn set_memory_high(cgpath: &str, value: &str) {
    let _ = fs::write(format!("{CGROOT}{cgpath}/memory.high"), value);
}

fn systemctl_user(args: &[&str]) {
    let mut full = vec!["--user"];
    full.extend_from_slice(args);
    let _ = Command::new("systemctl").args(&full).output();
}

fn sig(pid: u64, sig: &str) {
    let _ = Command::new("kill").args([sig, &pid.to_string()]).output();
}

fn zswap_status() -> (bool, bool, bool) {
    // (kernel supports it, currently enabled, swap already zram-backed)
    // Omarchy stock ships swap-on-zram with zswap deliberately OFF: zram
    // already compresses in RAM, so the enable-zswap banner must not nag.
    let p = "/sys/module/zswap/parameters/enabled";
    let zram = read_trim("/proc/swaps")
        .map(|s| s.lines().skip(1).any(|l| l.contains("zram")))
        .unwrap_or(false);
    if !Path::new(p).exists() {
        return (false, false, zram);
    }
    let enabled = read_trim(p).as_deref() == Some("Y");
    (true, enabled, zram)
}

/// Read a numeric UI pref from prefs.json (written by `pref K V`).
fn pref_num(key: &str, dflt: f64) -> f64 {
    let cur = read_prefs();
    let v: Value = serde_json::from_str(&cur).unwrap_or_else(|_| serde_json::json!({}));
    v.get(key).and_then(|x| x.as_f64()).unwrap_or(dflt)
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
        .unwrap_or(10.0)
}
/// CPU % above which the watchdog also freezes (0 = CPU trigger off).
fn crit_cpu_pct() -> f64 {
    if let Ok(v) = env::var("TM_CRIT_CPU_PCT") {
        if let Ok(n) = v.parse() {
            return n;
        }
    }
    let n = pref_num("watchMaxCpu", 0.0);
    if n <= 0.0 { 0.0 } else { n.clamp(50.0, 99.0) }
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
fn pressure(total: u64, avail: u64, psi: f64) -> (f64, bool) {
    let pct = if total > 0 {
        avail as f64 * 100.0 / total as f64
    } else {
        100.0
    };
    (pct, pct < crit_avail_pct() || psi > crit_psi())
}

/// (mem_total_mb, mem_avail_mb, psi_some_avg10, swap_total_mb, swap_used_mb)
fn mem_info() -> (u64, u64, f64, u64, u64) {
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
    let mut psi = 0.0;
    if let Some(p) = read_trim("/proc/pressure/memory") {
        if let Some(line) = p.lines().next() {
            for tok in line.split_whitespace() {
                if let Some(v) = tok.strip_prefix("avg10=") {
                    psi = v.parse().unwrap_or(0.0);
                }
            }
        }
    }
    (
        total,
        avail,
        psi,
        swap_total,
        swap_total.saturating_sub(swap_free),
    )
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', " ")
        .replace('\r', " ")
}

fn win_json(w: &Win) -> String {
    format!(
        "{{\"addr\":\"{}\",\"x\":{},\"y\":{},\"w\":{},\"h\":{},\"ws\":{},\"mon\":\"{}\",\"pinned\":{},\"title\":\"{}\"}}",
        w.address,
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
    let Ok(raw) = fs::read(format!("/proc/{pid}/cmdline")) else {
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
    use std::os::unix::fs::MetadataExt;
    let target = comm(pid);
    let uid = current_uid();
    let self_pid = std::process::id() as u64;
    let mut out = Vec::new();
    let Ok(entries) = fs::read_dir("/proc") else {
        return vec![pid];
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
        if comm(p) == target {
            out.push(p);
        }
    }
    if out.is_empty() {
        out.push(pid);
    }
    out
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
    procs: usize,
    pid: u64, // biggest pid of the group (representative for actions)
    unit: String,
    mechanism: &'static str,
    frozen: bool,
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
        if md.uid() != uid {
            continue;
        }
        let c = comm(pid);
        if EXCLUDE_COMMS.contains(&c.as_str()) || windowed_comms.contains(&c) {
            continue;
        }
        let r = rss_kb(pid);
        let g = groups.entry(c).or_insert((0, Vec::new()));
        g.0 += r;
        g.1.push(pid);
    }
    let our_units = marker_units();
    let mut out: Vec<BgRec> = groups
        .into_iter()
        .filter_map(|(name, (rkb, pids))| {
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
            // squeezed to near zero and the row must NOT vanish.
            if rkb < MIN_BG_RSS_KB && !frozen {
                return None;
            }
            Some(BgRec {
                name,
                rss_mb: rkb / 1024,
                procs: pids.len(),
                pid: biggest,
                unit,
                mechanism,
                frozen,
            })
        })
        .collect();
    out.sort_by(|a, b| b.rss_mb.cmp(&a.rss_mb));
    out.truncate(12);
    out
}

fn windowed_set_contains(by_pid: &BTreeMap<u64, Vec<Win>>, pid: u64) -> bool {
    by_pid.contains_key(&pid)
}

/// System daemons: processes NOT owned by the session user, grouped by comm,
/// sorted by RSS. Informational only — we cannot (and must not) signal
/// foreign pids, so the UI renders no action buttons for these rows.
fn collect_system(by_pid: &BTreeMap<u64, Vec<Win>>) -> Vec<BgRec> {
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
    let mut out: Vec<BgRec> = groups
        .into_iter()
        .map(|(name, (rkb, pids))| BgRec {
            name,
            rss_mb: rkb / 1024,
            procs: pids.len(),
            pid: pids.iter().copied().max().unwrap_or(0),
            unit: String::new(),
            mechanism: "signal",
            frozen: false,
        })
        .collect();
    out.sort_by(|a, b| b.rss_mb.cmp(&a.rss_mb));
    // Keep it short: this section shares the scroll viewport with the app
    // list — 6 top offenders usually fit without pushing it below the fold.
    out.truncate(6);
    out
}

fn cmd_state() {
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

    let mut out = String::from("\"apps\":[");
    let mut first = true;
    for (pid, wins, mechanism, rss_mb, frozen, unit, nprocs) in &apps {
        if !first {
            out.push(',');
        }
        first = false;
        let wins_json: Vec<String> = wins.iter().map(win_json).collect();
        // Browser families get the live tab list reported by the companion
        // extension (written to the cache by `tabs-host`); others get [].
        let c = comm(*pid);
        let tabs_json = if is_browser_comm(&c) { tabs_cache_json() } else { "[]".to_string() };
        out.push_str(&format!(
            "{{\"pid\":{pid},\"name\":\"{}\",\"title\":\"{}\",\"rss_mb\":{rss_mb},\"unit\":\"{}\",\"mechanism\":\"{mechanism}\",\"frozen\":{frozen},\"windows\":{},\"procs\":{nprocs},\"wins\":[{}],\"tabs\":{}}}",
            json_escape(&c),
            json_escape(&wins[0].title),
            json_escape(unit),
            wins.len(),
            wins_json.join(","),
            tabs_json
        ));
    }
    out.push(']');

    let background = collect_background(&by_pid, &our_marks);
    let mut bg_json = String::from("\"background\":[");
    let mut first = true;
    for b in &background {
        if !first {
            bg_json.push(',');
        }
        first = false;
        bg_json.push_str(&format!(
            "{{\"pid\":{},\"name\":\"{}\",\"rss_mb\":{},\"procs\":{},\"unit\":\"{}\",\"mechanism\":\"{}\",\"frozen\":{}}}",
            b.pid,
            json_escape(&b.name),
            b.rss_mb,
            b.procs,
            json_escape(&b.unit),
            b.mechanism,
            b.frozen
        ));
    }
    bg_json.push(']');

    // System daemons (not ours): same row shape, no actionable fields.
    let system = collect_system(&by_pid);
    let mut sys_json = String::from("\"system\":[");
    let mut first = true;
    for s in &system {
        if !first {
            sys_json.push(',');
        }
        first = false;
        sys_json.push_str(&format!(
            "{{\"pid\":{},\"name\":\"{}\",\"rss_mb\":{},\"procs\":{}}}",
            s.pid,
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

    let (total, avail, psi, swap_total, swap_used) = mem_info();
    let (zswap_avail, zswap_on, zram_backed) = zswap_status();
    let (avail_pct, critical) = pressure(total, avail, psi);
    let now_json = match now_from_history() {
        Some((c, m)) => format!("{{\"cpu\":{c:.1},\"mem\":{m:.1}}}"),
        None => "null".to_string(),
    };
    let prefs = read_prefs();
    println!(
        "{{\"mem\":{{\"total_mb\":{total},\"avail_mb\":{avail},\"psi_some10\":{psi:.2},\"swap_total_mb\":{swap_total},\"swap_used_mb\":{swap_used}}},\"pressure\":{{\"avail_pct\":{avail_pct:.1},\"critical\":{critical}}},\"zswap\":{{\"available\":{zswap_avail},\"enabled\":{zswap_on},\"zram\":{zram_backed}}},\"now\":{now_json},\"prefs\":{prefs},\"monitors\":[{}],{out},{bg_json},{sys_json}}}",
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

fn cmd_freeze(pid: u64) {
    let family = comm_family(pid);
    let scopes = family_scopes(&family);
    if scopes.is_empty() {
        // No systemd scope: signal-stop every family member.
        for p in &family {
            sig(*p, "-STOP");
            marker_add(*p);
        }
        return;
    }
    for (cgpath, unit) in &scopes {
        systemctl_user(&["freeze", unit]);
        marker_add_unit(unit);
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
        if !scoped.contains(p) {
            sig(*p, "-STOP");
            marker_add(*p);
        }
    }
}

fn cmd_thaw(pid: u64) {
    let family = comm_family(pid);
    let scopes = family_scopes(&family);
    for (cgpath, unit) in &scopes {
        // Restore headroom BEFORE resuming so the app can allocate.
        set_memory_high(cgpath, "max");
        systemctl_user(&["thaw", unit]);
        marker_remove_unit(unit);
    }
    if scopes.is_empty() {
        for p in &family {
            sig(*p, "-CONT");
            marker_remove(*p);
        }
        return;
    }
    // Signal-stopped stragglers (outside scopes) get CONT as well.
    for p in &family {
        if pid_stopped(*p) {
            sig(*p, "-CONT");
        }
        marker_remove(*p);
    }
}

fn cmd_focus(pid: u64) {
    if let Some(w) = app_windows(pid).first() {
        hyprctl(&[
            "dispatch",
            &format!(r#"hl.dsp.focus({{ window = "address:{}" }})"#, w.address),
        ]);
    }
}

fn cmd_kill(pid: u64) {
    // A frozen process cannot handle SIGTERM until resumed.
    let family = comm_family(pid);
    cmd_thaw(pid);
    for p in &family {
        sig(*p, "-TERM");
    }
}

// ---------- single-thread (subprocess) control ----------
// Browser tabs live in renderer pids INSIDE the app's systemd scope, so the
// scope freezer cannot touch one thread alone: freeze the scope and the whole
// browser pauses. Single-pid control therefore always uses signals + marker
// files, exactly like the no-scope fallback, and never touches memory.high.

/// Pause ONE subprocess (e.g. a hung browser tab/renderer).
fn cmd_freeze_pid(pid: u64) {
    if pid_stopped(pid) {
        return;
    }
    sig(pid, "-STOP");
    marker_add(pid);
}

/// Resume ONE subprocess paused with freeze-pid (or by anyone: CONT is a
/// no-op for a running process).
fn cmd_thaw_pid(pid: u64) {
    sig(pid, "-CONT");
    marker_remove(pid);
}

/// Close ONE subprocess: CONT first (a stopped process cannot die cleanly),
/// then SIGTERM. Killing a renderer shows the browser's per-tab crash page,
/// which is exactly what the user wants for a hung tab.
fn cmd_kill_pid(pid: u64) {
    sig(pid, "-CONT");
    marker_remove(pid);
    sig(pid, "-TERM");
}

// ---------- live history (written by `watch`, read by state/history) ----------
fn history_path() -> String {
    let rt = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    format!("{rt}/omarchy-task-manager/history.json")
}

fn prefs_path() -> String {
    let home = env::var("HOME").unwrap_or_default();
    format!("{home}/.local/state/omarchy-task-manager/prefs.json")
}

fn read_prefs() -> String {
    fs::read_to_string(prefs_path()).unwrap_or_else(|_| "{}".into())
}

/// utime+stime jiffies for a pid (robust against spaces/parens in comm).
fn proc_jiffies(pid: u64) -> u64 {
    let Ok(text) = fs::read_to_string(format!("/proc/{pid}/stat")) else {
        return 0;
    };
    let Some(rp) = text.rfind(')') else {
        return 0;
    };
    let f: Vec<&str> = text[rp + 2..].split_whitespace().collect();
    let u: u64 = f.get(11).and_then(|s| s.parse().ok()).unwrap_or(0);
    let s: u64 = f.get(12).and_then(|s| s.parse().ok()).unwrap_or(0);
    u + s
}

/// (busy, total, per-core (busy,total)) from /proc/stat.
fn cpu_times() -> (u64, u64, Vec<(u64, u64)>) {
    let Ok(text) = fs::read_to_string("/proc/stat") else {
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
        let p = history_path();
        if let Some(parent) = Path::new(&p).parent() {
            let _ = fs::create_dir_all(parent);
        }
        let tmp = format!("{p}.tmp");
        if fs::write(&tmp, self.to_json()).is_ok() {
            let _ = fs::rename(&tmp, &p);
        }
    }
}

/// Latest instantaneous values from the history tail (if the daemon is alive).
fn now_from_history() -> Option<(f32, f32)> {
    let text = fs::read_to_string(history_path()).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
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
fn cmd_procs(pid: u64) {
    let members = comm_family(pid);
    // Hierarchy beats raw size: the browser main process first, then
    // renderers by RSS (the actual tab cost), then service roles, with
    // zygote/crashpad anchors last. Processes with no role (every non-Chromium
    // app) share rank 1 and stay purely RSS-ordered, as before.
    let mut rows: Vec<(u64, String, u64, String, String)> = members
        .iter()
        .map(|p| {
            let state = fs::read_to_string(format!("/proc/{p}/stat"))
                .ok()
                .and_then(|t| t.rfind(')').map(|rp| t[rp + 2..].to_string()))
                .and_then(|rest| rest.chars().next().map(|c| c.to_string()))
                .unwrap_or_else(|| "?".into());
            (*p, comm(*p), rss_kb(*p) / 1024, state, if *p == pid { "browser".to_string() } else { proc_role(*p) })
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
                "{{\"pid\":{p},\"comm\":\"{}\",\"role\":\"{}\",\"rss_mb\":{r},\"state\":\"{s}\"}}",
                json_escape(c),
                json_escape(role)
            )
        })
        .collect();
    println!("[{}]", json.join(","));
}

/// Set a UI preference (persisted, read back via state.prefs).
fn cmd_pref(key: &str, value: &str) {
    let allowed = [
        "barStats",
        "showGraphs",
        "graphDetail",
        "sparklines",
        "barMode",
        "cardW",
        "cardH",
        "sortBy",
        "watchMaxRam",
        "watchMaxCpu",
    ];
    if !allowed.contains(&key) {
        return;
    }
    let p = prefs_path();
    if let Some(parent) = Path::new(&p).parent() {
        let _ = fs::create_dir_all(parent);
    }
    let cur = read_prefs();
    let mut v: Value = serde_json::from_str(&cur).unwrap_or_else(|_| serde_json::json!({}));
    if key == "barMode" {
        // Tri-state pill display: off / numbers / numbers+graph.
        if !["off", "numbers", "graph"].contains(&value) {
            return;
        }
        v[key] = serde_json::json!(value);
    } else if key == "sortBy" {
        if !["ram", "cpu", "name"].contains(&value) {
            return;
        }
        v[key] = serde_json::json!(value);
    } else if key == "cardW" || key == "cardH" {
        // Persisted card geometry (px, sanity-clamped).
        let Ok(n) = value.parse::<u32>() else { return };
        if !(300..=3000).contains(&n) {
            return;
        }
        v[key] = serde_json::json!(value);
    } else if key == "watchMaxRam" || key == "watchMaxCpu" {
        // Watchdog thresholds (%): RAM used 50..=99; CPU 0 (off) or 50..=99.
        let Ok(n) = value.parse::<u32>() else { return };
        let ok = if key == "watchMaxRam" {
            (50..=99).contains(&n)
        } else {
            n == 0 || (50..=99).contains(&n)
        };
        if !ok {
            return;
        }
        v[key] = serde_json::json!(n);
    } else {
        v[key] = serde_json::json!(value == "1" || value == "true");
    }
    let tmp = format!("{p}.tmp");
    if let Ok(text) = serde_json::to_string(&v) {
        if fs::write(&tmp, text).is_ok() {
            let _ = fs::rename(&tmp, &p);
        }
    }
}

fn cmd_history() {
    match fs::read_to_string(history_path()) {
        Ok(text) => println!("{text}"),
        Err(_) => {
            println!("{{\"ts\":[],\"cpu\":[],\"mem\":[],\"gpu\":null,\"cores\":[],\"apps\":{{}}}}")
        }
    }
}

fn focused_pid() -> Option<u64> {
    let text = hyprctl(&["activewindow", "-j"]);
    let v: Value = serde_json::from_str(&text).ok()?;
    v.get("pid")?.as_u64()
}

/// Biggest freezable candidate: windowed app or background scope, never the
/// focused app, never already-frozen, >= MIN_FREEZE_MB.
fn freeze_biggest() -> Option<String> {
    let mons = monitors();
    let mut by_pid: BTreeMap<u64, Vec<Win>> = BTreeMap::new();
    for w in clients(&mons) {
        by_pid.entry(w.pid).or_default().push(w);
    }
    let marks = marker_pids();
    let focus = focused_pid();
    let focus_unit = focus.and_then(|p| proc_cgroup(p).map(|(_, u)| u));

    let mut best: Option<(u64, String, u64)> = None; // (pid, name, rss_mb)
    let mut consider = |pid: u64, name: String, rss_kb: u64, unit: String, frozen: bool| {
        if frozen || rss_kb < MIN_FREEZE_MB * 1024 {
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
        let frozen = !scopes.is_empty() && scopes.iter().all(|(cg, _)| scope_frozen(cg));
        let unit = scopes.first().map(|(_, u)| u.clone()).unwrap_or_default();
        consider(*pid, c, total, unit, frozen);
    }
    for bg in collect_background(&by_pid, &marks) {
        // Auto-freeze only via scope (atomic, reversible) — no signal stops.
        if bg.mechanism == "scope" {
            consider(bg.pid, bg.name, bg.rss_mb * 1024, String::new(), bg.frozen);
        }
    }

    let (pid, name, mb) = best?;
    cmd_freeze(pid);
    // The user must KNOW an app was auto-paused, or it looks like a crash.
    let (title, body) = notify_autopause_text(&name, mb);
    let _ = Command::new("notify-send")
        .args(["-a", "Task Manager", "-u", "critical", &title, &body])
        .spawn();
    Some(format!("{name} ({mb} MB)"))
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
            "Presión de memoria — reanúdala desde el Administrador de tareas.".to_string(),
        ),
        _ => (
            format!("{name} auto-paused ({mb} MB)"),
            "Memory pressure — resume it from the Task Manager.".to_string(),
        ),
    }
}

/// One full history sample: system cpu/mem, per-core, top-8 apps by RSS.
fn sample_history(
    hist: &mut Hist,
    prev: &mut (u64, u64, Vec<(u64, u64)>),
    prev_apps: &mut BTreeMap<String, u64>,
) {
    let st = cpu_times();
    let dt = st.1.saturating_sub(prev.1).max(1);
    let cpu = st.0.saturating_sub(prev.0) as f32 * 100.0 / dt as f32;
    let ncores = st.2.len().max(1) as f32;
    let mut core_pcts = Vec::new();
    for (i, (b, t)) in st.2.iter().enumerate() {
        let (pb, pt) = prev.2.get(i).copied().unwrap_or((*b, *t));
        let d = t.saturating_sub(pt).max(1);
        core_pcts.push(b.saturating_sub(pb) as f32 * 100.0 / d as f32);
    }
    *prev = st;

    let (ttotal, tavail, _, _, _) = mem_info();
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
    let mut apps: Vec<(String, f32, f32)> = Vec::new();
    for pid in by_pid.keys() {
        let c = comm(*pid);
        if EXCLUDE_COMMS.contains(&c.as_str()) {
            continue;
        }
        // Family-wide series: matches the row's RSS (window + background).
        let family = comm_family(*pid);
        let rss: u64 = family.iter().map(|p| rss_kb(*p)).sum();
        let j: u64 = family.iter().map(|p| proc_jiffies(*p)).sum();
        let key = family_scopes(&family)
            .first()
            .map(|(_, u)| u.clone())
            .unwrap_or_else(|| format!("pid{pid}"));
        let pj = prev_apps.insert(key.clone(), j).unwrap_or(j);
        let cpu_pct = j.saturating_sub(pj) as f32 * ncores * 100.0 / dt as f32;
        apps.push((key, rss as f32 / 1024.0, cpu_pct));
    }
    // Background scope groups get series too (CPU% next to their names).
    let marks = marker_pids();
    for bg in collect_background(&by_pid, &marks) {
        if bg.mechanism != "scope" || bg.unit.is_empty() {
            continue;
        }
        let family = comm_family(bg.pid);
        let j: u64 = family.iter().map(|p| proc_jiffies(*p)).sum();
        let pj = prev_apps.insert(bg.unit.clone(), j).unwrap_or(j);
        let cpu_pct = j.saturating_sub(pj) as f32 * ncores * 100.0 / dt as f32;
        apps.push((bg.unit, bg.rss_mb as f32, cpu_pct));
    }
    apps.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    // Keep enough series for every listed row to show CPU% (was 8: small
    // windowed apps fell off and showed no percentage).
    apps.truncate(16);
    prev_apps.retain(|k, _| apps.iter().any(|a| &a.0 == k));
    hist.push(cpu, mem_pct, core_pcts, apps);
    hist.write();
}

/// Memory-pressure watchdog: freeze biggest apps while pressure is critical.
fn cmd_watch() {
    eprintln!(
        "task-manager watch: pid {} crit avail<{:.0}% or psi>{:.0}, recover>{:.0}%, max {} per episode",
        std::process::id(),
        crit_avail_pct(),
        crit_psi(),
        recover_avail_pct(),
        max_freeze_per_episode()
    );
    let mut hits = 0u32;
    let mut frozen_this_episode = 0u32;
    let mut hist = Hist::new();
    let mut prev_stat = cpu_times();
    let mut prev_cpu = cpu_times();
    let mut prev_apps: BTreeMap<String, u64> = BTreeMap::new();
    let mut tick = 0u32;
    loop {
        let (total, avail, psi, _, _) = mem_info();
        let (pct, mut crit) = pressure(total, avail, psi);
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
            if pct > recover_avail_pct() {
                frozen_this_episode = 0;
            }
        }
        if hits >= 2 && frozen_this_episode < max_freeze_per_episode() {
            match freeze_biggest() {
                Some(what) => {
                    eprintln!(
                        "watch: pressure critical ({pct:.1}% avail, psi {psi:.1}, cpu {cpu_now:.0}%/{cpu_max:.0}) — froze {what}"
                    );
                    frozen_this_episode += 1;
                    hits = 0;
                    std::thread::sleep(std::time::Duration::from_millis(2000));
                    continue;
                }
                None => {
                    eprintln!("watch: pressure critical but no candidates left");
                    hits = 0;
                }
            }
        }
        tick += 1;
        if tick % 4 == 0 {
            sample_history(&mut hist, &mut prev_stat, &mut prev_apps);
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
}

/// Copy the zswap enable command to the clipboard via wl-copy (stdin form).
fn cmd_zswap_copy() {
    use std::io::Write;
    let mut child = match Command::new("wl-copy")
        .stdin(std::process::Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => {
            // No clipboard tool: print the command so the caller can show it.
            println!("{ZSWAP_ENABLE_CMD}");
            return;
        }
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(ZSWAP_ENABLE_CMD.as_bytes());
    }
    let _ = child.wait();
}

fn usage() -> ! {
    eprintln!(
        "usage: task-manager <state|wins PID|freeze PID|thaw PID|focus PID|kill PID|freeze-pid PID|thaw-pid PID|kill-pid PID|procs PID|zswap-copy|pref K V|history|watch|follow>"
    );
    std::process::exit(1)
}

/// Stream compositor events (Hyprland socket2), one per line, so the QML
/// veil layer can react INSTANTLY instead of polling: retop on focus,
/// follow on workspace moves, cleanup on close. Only veil-relevant events
/// are forwarded.
fn cmd_follow() {
    use std::io::{BufRead, BufReader, Write};
    let his = env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_default();
    let path = format!("{}/hypr/{}/.socket2.sock", runtime_dir(), his);
    let sock = match std::os::unix::net::UnixStream::connect(&path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("follow: connect {path}: {e}");
            std::process::exit(1);
        }
    };
    let reader = BufReader::new(sock);
    let mut out = std::io::stdout().lock();
    for line in reader.lines() {
        let Ok(l) = line else { break };
        if l.starts_with("activewindowv2>>")
            || l.starts_with("movewindowv2>>")
            || l.starts_with("closewindow>>")
            || l.starts_with("openwindow>>")
            || l.starts_with("workspace>>")
            || l.starts_with("changefloatingmode>>")
        {
            if writeln!(out, "{l}").is_err() || out.flush().is_err() {
                break; // consumer gone
            }
        }
    }
}

/// Native Messaging host for the companion "Omarchy Task Manager Tabs"
/// extension (long-lived port mode, connectNative): reads framed tab reports
/// from stdin and persists them atomically (user-only, 0600), and forwards
/// local commands (written by `tabs-cmd`) back to the extension over stdout.
/// Chrome keeps this process alive for the browser session.
fn cmd_tabs_host() {
    use std::io::Read;
    let Some(home) = env::var_os("HOME") else {
        std::process::exit(1);
    };
    let dir = Path::new(&home).join(".cache/omarchy/task-manager");
    let _ = fs::create_dir_all(&dir);
    let cmd_path = dir.join("tabs-cmd.json");
    let cache = dir.join("tabs.json");

    // Writer thread: poll the command file, forward each command to the
    // extension (framed), and remove it once sent.
    let cmd_tx;
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    cmd_tx = tx;
    std::thread::spawn(move || loop {
        if let Ok(text) = fs::read_to_string(&cmd_path) {
            if serde_json::from_str::<Value>(&text).is_ok() {
                let _ = cmd_tx.send(text);
                let _ = fs::remove_file(&cmd_path);
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(400));
    });

    let stdout = std::io::stdout();
    std::thread::spawn(move || {
        use std::io::Write as _;
        while let Ok(cmd) = rx.recv() {
            let mut out = stdout.lock();
            let _ = out.write_all(&(cmd.len() as u32).to_le_bytes());
            let _ = out.write_all(cmd.as_bytes());
            let _ = out.flush();
        }
    });

    let stdin = std::io::stdin();
    let mut input = stdin.lock();
    loop {
        let mut len = [0u8; 4];
        if input.read_exact(&mut len).is_err() {
            break; // browser closed the port
        }
        let n = u32::from_le_bytes(len) as usize;
        if n == 0 || n > 4 * 1024 * 1024 {
            break;
        }
        let mut buf = vec![0u8; n];
        if input.read_exact(&mut buf).is_err() {
            break;
        }
        let Ok(v) = serde_json::from_slice::<Value>(&buf) else {
            continue;
        };
        let Some(tabs) = v.get("tabs").and_then(|t| t.as_array()) else {
            continue;
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        let out = serde_json::json!({ "updatedAt": now, "tabs": tabs }).to_string();
        let tmp = dir.join(format!("tabs.json.{}", std::process::id()));
        {
            use std::os::unix::fs::OpenOptionsExt;
            if let Ok(mut f) = fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&tmp)
            {
                use std::io::Write as _;
                if f.write_all(out.as_bytes()).is_ok() {
                    let _ = fs::rename(&tmp, &cache);
                }
            }
        }
    }
}

/// Queue a command for the browser extension (e.g. `tabs-cmd discard 123`).
/// The long-lived tabs host forwards it to the extension within ~0.5s.
fn cmd_tabs_cmd(action: &str, id: &str) {
    let tab_id: u64 = id.parse().unwrap_or_else(|_| usage());
    if action != "discard" {
        usage();
    }
    let Some(home) = env::var_os("HOME") else {
        std::process::exit(1);
    };
    let dir = Path::new(&home).join(".cache/omarchy/task-manager");
    let _ = fs::create_dir_all(&dir);
    let out = serde_json::json!({ "action": action, "tabId": tab_id }).to_string();
    let tmp = dir.join(format!("tabs-cmd.json.{}", std::process::id()));
    let dst = dir.join("tabs-cmd.json");
    {
        use std::os::unix::fs::OpenOptionsExt;
        if let Ok(mut f) = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
        {
            use std::io::Write as _;
            if f.write_all(out.as_bytes()).is_ok() {
                let _ = fs::rename(&tmp, &dst);
            }
        }
    }
}

/// Browser comms that consume the tabs cache.
fn is_browser_comm(c: &str) -> bool {
    let l = c.to_lowercase();
    l.contains("chrom") || l.contains("brave") || l.contains("edge")
}

/// The tabs cache as a JSON array string, only while fresh (the extension
/// reports on every tab event; stale >2min means the browser/bridge is off).
fn tabs_cache_json() -> String {
    let Some(home) = env::var_os("HOME") else {
        return "[]".into();
    };
    let path = Path::new(&home).join(".cache/omarchy/task-manager/tabs.json");
    let Ok(meta) = fs::metadata(&path) else {
        return "[]".into();
    };
    let fresh = meta
        .modified()
        .ok()
        .and_then(|m| m.elapsed().ok())
        .map(|e| e.as_secs() < 120)
        .unwrap_or(false);
    if !fresh {
        return "[]".into();
    }
    let Ok(text) = fs::read_to_string(&path) else {
        return "[]".into();
    };
    let Ok(v) = serde_json::from_str::<Value>(&text) else {
        return "[]".into();
    };
    v.get("tabs")
        .and_then(|t| t.as_array())
        .map(|a| Value::Array(a.clone()).to_string())
        .unwrap_or_else(|| "[]".into())
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        usage();
    }
    match args[1].as_str() {
        "state" => cmd_state(),
        "freeze" if args.len() == 3 => cmd_freeze(args[2].parse().unwrap_or_else(|_| usage())),
        "thaw" if args.len() == 3 => cmd_thaw(args[2].parse().unwrap_or_else(|_| usage())),
        "focus" if args.len() == 3 => cmd_focus(args[2].parse().unwrap_or_else(|_| usage())),
        "kill" if args.len() == 3 => cmd_kill(args[2].parse().unwrap_or_else(|_| usage())),
        "freeze-pid" if args.len() == 3 => cmd_freeze_pid(args[2].parse().unwrap_or_else(|_| usage())),
        "thaw-pid" if args.len() == 3 => cmd_thaw_pid(args[2].parse().unwrap_or_else(|_| usage())),
        "kill-pid" if args.len() == 3 => cmd_kill_pid(args[2].parse().unwrap_or_else(|_| usage())),
        "zswap-copy" => cmd_zswap_copy(),
        "watch" => cmd_watch(),
        "follow" => cmd_follow(),
        "tabs-host" => cmd_tabs_host(),
        "tabs-cmd" if args.len() == 4 => cmd_tabs_cmd(&args[2], &args[3]),
        "history" => cmd_history(),
        "procs" if args.len() == 3 => cmd_procs(args[2].parse().unwrap_or_else(|_| usage())),
        "pref" if args.len() == 4 => cmd_pref(&args[2], &args[3]),
        _ => usage(),
    }
}
