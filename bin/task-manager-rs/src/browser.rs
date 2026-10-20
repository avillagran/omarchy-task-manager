//! Chromium-family Memory Saver, as the user's own preference.
//!
//! On macOS and Windows, Chrome also discards background tabs when the OS
//! signals memory pressure. Linux sends no such signal, so tabs only leave
//! memory through Memory Saver's inactivity timer, and Chromium registers
//! that preference as disabled by default
//! (`performance_tuning.high_efficiency_mode.state`, 0 = off, 2 = on, in
//! the profile's "Local State"). The file is the user's, so no root is
//! involved, but a running browser rewrites it from memory on exit:
//! - browser closed: the preference is written right away;
//! - browser running: its Performance settings page opens so the user can
//!   flip it now, and the change is queued; the watch daemon writes it the
//!   moment the browser exits.

use crate::runtime_dir;
use serde_json::Value;
use std::env;
use std::fs;
use std::path::Path;
use std::process::Command;

const STATE_ON: i64 = 2;

struct Browser {
    name: &'static str,
    /// Profile dir under $HOME holding "Local State".
    profile: &'static str,
    /// Executable path prefix, to tell whether it runs.
    exe_prefix: &'static str,
    /// Launcher that hands a URL to the running instance.
    launcher: &'static str,
}

const BROWSERS: &[Browser] = &[
    Browser { name: "chrome", profile: ".config/google-chrome", exe_prefix: "/opt/google/chrome/", launcher: "google-chrome-stable" },
    Browser { name: "chromium", profile: ".config/chromium", exe_prefix: "/usr/lib/chromium/", launcher: "chromium" },
    Browser { name: "brave", profile: ".config/BraveSoftware/Brave-Browser", exe_prefix: "/opt/brave", launcher: "brave" },
];

fn local_state(b: &Browser) -> String {
    format!("{}/{}/Local State", env::var("HOME").unwrap_or_default(), b.profile)
}

fn present(b: &Browser) -> bool {
    Path::new(&local_state(b)).exists()
}

fn state_of(b: &Browser) -> Option<i64> {
    let raw = fs::read_to_string(local_state(b)).ok()?;
    let v: Value = serde_json::from_str(&raw).ok()?;
    Some(
        v.pointer("/performance_tuning/high_efficiency_mode/state")
            .and_then(|s| s.as_i64())
            .unwrap_or(0),
    )
}

fn explicit(b: &Browser) -> bool {
    fs::read_to_string(local_state(b))
        .ok()
        .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
        .map(|v| v.pointer("/performance_tuning/high_efficiency_mode/state").is_some())
        .unwrap_or(false)
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

fn pending_path(b: &Browser) -> String {
    format!("{}/omarchy-task-manager/memory-saver-pending-{}", runtime_dir(), b.name)
}

/// Write the preference (browser must be closed). Atomic: Local State is
/// the browser's whole machine-wide state, a torn write would reset it.
fn write_pref(b: &Browser, on: bool) -> bool {
    let path = local_state(b);
    let Ok(raw) = fs::read_to_string(&path) else {
        return false;
    };
    let Ok(mut v) = serde_json::from_str::<Value>(&raw) else {
        return false;
    };
    if !v.is_object() {
        return false;
    }
    let pt = v
        .as_object_mut()
        .unwrap()
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

/// None = no Chromium-family profile; Some(on) = Memory Saver on in every
/// profile present (or queued for one that is running).
pub fn status() -> Option<bool> {
    let present: Vec<&Browser> = BROWSERS.iter().filter(|b| present(b)).collect();
    if present.is_empty() {
        return None;
    }
    Some(present.iter().all(|b| {
        state_of(b) == Some(STATE_ON) || Path::new(&pending_path(b)).exists()
    }))
}

/// Watch-daemon hook: apply queued changes once their browser has exited.
pub fn apply_pending() {
    for b in BROWSERS {
        let p = pending_path(b);
        let Ok(want) = fs::read_to_string(&p) else {
            continue;
        };
        if running(b) {
            continue;
        }
        let on = want.trim() != "off";
        // The user may have chosen in the settings page we opened: an
        // explicit value there is theirs (an untouched pref has no key).
        if explicit(b) && on {
            let _ = fs::remove_file(&p);
            continue;
        }
        if write_pref(b, on) {
            eprintln!("browser: {} Memory Saver {} (applied after exit)", b.name, if on { "on" } else { "off" });
        }
        let _ = fs::remove_file(&p);
    }
}

/// `task-manager chrome-memory-saver [on|off]` (default on; the UI passes
/// a dummy pid).
pub fn cmd_memory_saver(arg: Option<&str>) {
    let on = arg != Some("off");
    for b in BROWSERS.iter().filter(|b| present(b)) {
        if state_of(b) == Some(if on { STATE_ON } else { 0 }) {
            let _ = fs::remove_file(pending_path(b));
            println!("{}: already {}", b.name, if on { "on" } else { "off" });
            continue;
        }
        if !running(b) {
            let ok = write_pref(b, on);
            println!("{}: {}", b.name, if ok { "set" } else { "could not write Local State" });
            continue;
        }
        let _ = fs::create_dir_all(format!("{}/omarchy-task-manager", runtime_dir()));
        let _ = fs::write(pending_path(b), if on { "on" } else { "off" });
        let _ = Command::new(b.launcher)
            .arg("chrome://settings/performance")
            .spawn();
        println!(
            "{}: running; settings page opened, and the change applies itself when it exits",
            b.name
        );
    }
}
