//! Chromium-family Memory Saver, as the user's own preference.
//!
//! On macOS and Windows, Chrome also discards background tabs when the OS
//! signals memory pressure. Linux sends no such signal, so tabs only leave
//! memory through Memory Saver's inactivity timer, and Chromium registers
//! that preference as disabled by default
//! (`performance_tuning.high_efficiency_mode.state`, 0 = off, 2 = on, in
//! the profile's "Local State"). The file is the user's, so no root is
//! involved, but a browser only reads it at startup and rewrites it from
//! memory on exit. So the user's intent is stored on disk once
//! (`chrome-memory-saver on`, or the card's button) and the watch daemon
//! applies it, with no further action, whenever that browser is not
//! running: at login before it is opened, or the moment it exits. A value
//! the user set themselves in the browser (the key exists) is never
//! overridden by the daemon.

use serde_json::Value;
use std::env;
use std::fs;
use std::path::Path;

const STATE_ON: i64 = 2;

struct Browser {
    name: &'static str,
    /// Profile dir under $HOME holding "Local State".
    profile: &'static str,
    /// Executable path prefix, to tell whether it runs.
    exe_prefix: &'static str,
}

const BROWSERS: &[Browser] = &[
    Browser { name: "chrome", profile: ".config/google-chrome", exe_prefix: "/opt/google/chrome/" },
    Browser { name: "chromium", profile: ".config/chromium", exe_prefix: "/usr/lib/chromium/" },
    Browser { name: "brave", profile: ".config/BraveSoftware/Brave-Browser", exe_prefix: "/opt/brave" },
];

fn home() -> String {
    env::var("HOME").unwrap_or_default()
}

fn local_state(b: &Browser) -> String {
    format!("{}/{}/Local State", home(), b.profile)
}

fn present(b: &Browser) -> bool {
    Path::new(&local_state(b)).exists()
}

/// The pref as stored: None = never set (Chromium's default, off).
fn stored(b: &Browser) -> Option<i64> {
    let raw = fs::read_to_string(local_state(b)).ok()?;
    let v: Value = serde_json::from_str(&raw).ok()?;
    v.pointer("/performance_tuning/high_efficiency_mode/state")?.as_i64()
}

fn running(b: &Browser) -> bool {
    let Ok(rd) = fs::read_dir("/proc") else {
        return false;
    };
    rd.flatten().any(|e| {
        fs::read_link(e.path().join("exe"))
            .map(|t| t.to_string_lossy().starts_with(b.exe_prefix))
            .unwrap_or(false)
    })
}

/// Persistent (survives reboots, unlike $XDG_RUNTIME_DIR): "on" / "off".
fn intent_path() -> String {
    format!("{}/.local/state/omarchy-task-manager/memory-saver", home())
}

fn intent_on() -> bool {
    fs::read_to_string(intent_path()).map(|s| s.trim() == "on").unwrap_or(false)
}

/// Write the pref (browser must be closed). Atomic: Local State is the
/// browser's whole machine-wide state; a torn write would reset it.
fn write_pref(b: &Browser, on: bool) -> bool {
    let path = local_state(b);
    let Ok(raw) = fs::read_to_string(&path) else {
        return false;
    };
    let Ok(mut v) = serde_json::from_str::<Value>(&raw) else {
        return false;
    };
    let Some(root) = v.as_object_mut() else {
        return false;
    };
    let pt = root
        .entry("performance_tuning")
        .or_insert_with(|| serde_json::json!({}));
    if !pt.is_object() {
        *pt = serde_json::json!({});
    }
    let hem = pt
        .as_object_mut()
        .unwrap()
        .entry("high_efficiency_mode")
        .or_insert_with(|| serde_json::json!({}));
    if !hem.is_object() {
        *hem = serde_json::json!({});
    }
    hem["state"] = Value::from(if on { STATE_ON } else { 0 });
    let tmp = format!("{path}.tm-tmp");
    fs::write(&tmp, v.to_string()).is_ok() && fs::rename(&tmp, &path).is_ok()
}

/// None = no Chromium-family profile. Some(true) = on everywhere, or
/// queued (intent on, browser running, pref untouched).
pub fn status() -> Option<bool> {
    let present: Vec<&Browser> = BROWSERS.iter().filter(|b| present(b)).collect();
    if present.is_empty() {
        return None;
    }
    let queued = intent_on();
    Some(present.iter().all(|b| match stored(b) {
        Some(s) => s == STATE_ON,
        None => queued,
    }))
}

/// Watch-daemon hook: apply the stored intent to every closed browser whose
/// pref is still untouched.
pub fn apply_pending() {
    if !intent_on() {
        return;
    }
    for b in BROWSERS {
        if !present(b) || stored(b).is_some() || running(b) {
            continue;
        }
        if write_pref(b, true) {
            eprintln!("browser: {} Memory Saver turned on", b.name);
        }
    }
}

/// `task-manager chrome-memory-saver [on|off]` (default on; the UI passes
/// a dummy pid). An explicit request: closed browsers get it now, even over
/// a previous value; running ones as soon as they close.
pub fn cmd_memory_saver(arg: Option<&str>) {
    let on = arg != Some("off");
    let p = intent_path();
    if let Some(dir) = Path::new(&p).parent() {
        let _ = fs::create_dir_all(dir);
    }
    let _ = fs::write(&p, if on { "on\n" } else { "off\n" });
    for b in BROWSERS.iter().filter(|b| present(b)) {
        let want = if on { STATE_ON } else { 0 };
        if stored(b).unwrap_or(0) == want {
            println!("{}: already {}", b.name, if on { "on" } else { "off" });
        } else if running(b) {
            println!("{}: running, applies itself when it closes", b.name);
        } else {
            let ok = write_pref(b, on);
            println!("{}: {}", b.name, if ok { "set" } else { "could not write Local State" });
        }
    }
}
