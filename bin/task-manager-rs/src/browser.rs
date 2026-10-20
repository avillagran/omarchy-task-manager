//! Chromium-family Memory Saver via managed policy.
//!
//! On macOS and Windows, Chrome also discards background tabs when the OS
//! signals memory pressure. Linux has no such signal for it, so tabs only
//! ever leave memory through Memory Saver's inactivity timer, and that is
//! user-controlled. The `HighEfficiencyModeEnabled` policy (chrome.* 108+)
//! turns it on for good; the savings level stays the user's choice.
//! Omarchy already manages Chrome through /etc/opt/chrome/policies/managed
//! (theme colors), so this adds no new "managed" banner.

use std::fs;
use std::path::Path;
use std::process::Command;

const POLICY_FILE: &str = "omarchy-task-manager-memory-saver.json";
const POLICY_BODY: &str = "{\"HighEfficiencyModeEnabled\": true}\n";

/// (browser binary that must exist, its managed-policy dir)
const BROWSERS: &[(&str, &str)] = &[
    ("/opt/google/chrome/chrome", "/etc/opt/chrome/policies/managed"),
    ("/usr/bin/chromium", "/etc/chromium/policies/managed"),
    ("/usr/bin/brave", "/etc/brave/policies/managed"),
];

fn installed() -> impl Iterator<Item = &'static str> {
    BROWSERS
        .iter()
        .filter(|(bin, _)| Path::new(bin).exists())
        .map(|(_, dir)| *dir)
}

/// None = no Chromium-family browser installed; Some(on) otherwise
/// (on = our policy is in place for every installed browser).
pub fn status() -> Option<bool> {
    let dirs: Vec<&str> = installed().collect();
    if dirs.is_empty() {
        return None;
    }
    Some(dirs.iter().all(|d| Path::new(&format!("{d}/{POLICY_FILE}")).exists()))
}

fn apply(on: bool) -> bool {
    let mut ok = true;
    for dir in installed() {
        let path = format!("{dir}/{POLICY_FILE}");
        let r = if on {
            fs::create_dir_all(dir).and_then(|_| fs::write(&path, POLICY_BODY))
        } else if Path::new(&path).exists() {
            fs::remove_file(&path)
        } else {
            Ok(())
        };
        if let Err(e) = r {
            eprintln!("{path}: {e}");
            ok = false;
        }
    }
    ok
}

fn is_root() -> bool {
    use std::os::unix::fs::MetadataExt;
    fs::metadata("/proc/self").map(|m| m.uid() == 0).unwrap_or(false)
}

/// `task-manager chrome-memory-saver [on|off]` (default on; the UI passes
/// a dummy pid). Writes need root: as root it applies directly; otherwise
/// it re-runs itself through sudo, in Omarchy's floating terminal when a
/// password is needed.
pub fn cmd_memory_saver(arg: Option<&str>) {
    let on = arg != Some("off");
    if is_root() {
        let ok = apply(on);
        println!("{}", if ok { "ok" } else { "failed" });
        if ok {
            println!(
                "Memory Saver {}: browsers pick it up within minutes (chrome://policy > Reload policies applies it now).",
                if on { "enforced" } else { "back to user control" }
            );
        }
        return;
    }
    let me = std::env::current_exe()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| "task-manager".into());
    let verb = if on { "on" } else { "off" };
    let quiet = Command::new("sudo")
        .args(["-n", &me, "chrome-memory-saver", verb])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if quiet {
        return;
    }
    let cmd = format!("sudo '{me}' chrome-memory-saver {verb}");
    let spawned = Command::new("omarchy-launch-floating-terminal-with-presentation")
        .arg(&cmd)
        .spawn()
        .is_ok();
    if !spawned {
        println!("run: {cmd}");
    }
}
