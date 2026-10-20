//! RAM held by files: tmpfs hygiene.
//!
//! /tmp and $XDG_RUNTIME_DIR are tmpfs. A file there is RAM (or swap) until
//! deleted, and no reclaim can drop it. Measured on a 16 GB box after 2.5
//! days: 6.6 GB of stale build trees in /tmp plus 1 GB of logs from 3 350
//! dead quickshell instances in $XDG_RUNTIME_DIR/quickshell/by-id, i.e.
//! half the RAM pinned by garbage.
//!
//! * quickshell logs of dead instances are deleted automatically (they are
//!   only useful while the instance runs);
//! * stale /tmp trees (ours, untouched for STALE_AFTER, not open by any
//!   process) are reported as a suggestion and deleted only on request
//!   (`task-manager clean-tmp`).

use crate::{current_uid, runtime_dir};
use serde_json::Value;
use std::collections::BTreeSet;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

const MIB: u64 = 1024 * 1024;
/// A /tmp tree is stale when nothing in it changed for this long.
const STALE_AFTER: Duration = Duration::from_secs(24 * 3600);
/// Dead quickshell instance dirs younger than this are kept (crash triage).
const QS_KEEP: Duration = Duration::from_secs(3600);
/// Walk cap per /tmp entry: bigger trees are skipped, not guessed.
const WALK_CAP: usize = 200_000;
/// Entries smaller than this are not worth a deletion (RAM is the point).
const MIN_ENTRY_BYTES: u64 = 1024 * 1024;
/// Report stale /tmp only above this much.
pub const TMP_SUGGEST_MIN_MB: u64 = 256;

fn report_path() -> String {
    format!("{}/omarchy-task-manager/hygiene.json", runtime_dir())
}

fn is_tmpfs(mount: &str) -> bool {
    fs::read_to_string("/proc/mounts")
        .map(|m| {
            m.lines().any(|l| {
                let mut f = l.split_whitespace();
                let (_, mp, ty) = (f.next(), f.next(), f.next());
                mp == Some(mount) && ty == Some("tmpfs")
            })
        })
        .unwrap_or(false)
}

/// (bytes, newest change, entries) of a tree; None past WALK_CAP or when
/// the tree reaches into another filesystem (a mount under /tmp: sshfs,
/// FUSE, bind) — that is never ours to delete. "Change" is max(mtime,
/// ctime): tar/cp -a/rsync -a backdate mtime, nobody can backdate ctime.
fn tree_stat(p: &Path) -> Option<(u64, SystemTime, usize)> {
    let dev = fs::symlink_metadata(p).ok()?.dev();
    let mut bytes = 0u64;
    let mut newest = SystemTime::UNIX_EPOCH;
    let mut n = 0usize;
    let mut stack = vec![p.to_path_buf()];
    while let Some(cur) = stack.pop() {
        let Ok(md) = fs::symlink_metadata(&cur) else {
            continue;
        };
        n += 1;
        if n > WALK_CAP || md.dev() != dev {
            return None;
        }
        bytes += md.blocks() * 512;
        if let Ok(m) = md.modified() {
            newest = newest.max(m);
        }
        let ctime = SystemTime::UNIX_EPOCH + Duration::new(md.ctime().max(0) as u64, 0);
        newest = newest.max(ctime);
        if md.is_dir() {
            if let Ok(rd) = fs::read_dir(&cur) {
                stack.extend(rd.flatten().map(|e| e.path()));
            }
        }
    }
    Some((bytes, newest, n))
}

/// Every path under `prefix` some live process holds (cwd, fds, mappings).
fn paths_in_use(prefix: &str) -> BTreeSet<PathBuf> {
    let mut out = BTreeSet::new();
    let Ok(rd) = fs::read_dir("/proc") else {
        return out;
    };
    for e in rd.flatten() {
        if e.file_name().to_str().and_then(|s| s.parse::<u64>().ok()).is_none() {
            continue;
        }
        let base = e.path();
        if let Ok(t) = fs::read_link(base.join("cwd")) {
            if t.starts_with(prefix) {
                out.insert(t);
            }
        }
        if let Ok(fds) = fs::read_dir(base.join("fd")) {
            for fd in fds.flatten() {
                if let Ok(t) = fs::read_link(fd.path()) {
                    if t.starts_with(prefix) {
                        out.insert(t);
                    }
                }
            }
        }
        if let Ok(maps) = fs::read_to_string(base.join("maps")) {
            for l in maps.lines() {
                if let Some(i) = l.find(prefix) {
                    out.insert(PathBuf::from(l[i..].trim_end_matches(" (deleted)")));
                }
            }
        }
    }
    out
}

pub struct Stale {
    pub path: PathBuf,
    pub bytes: u64,
}

/// Stale top-level /tmp entries owned by us and not in use.
pub fn stale_tmp() -> Vec<Stale> {
    if !is_tmpfs("/tmp") {
        return Vec::new();
    }
    let uid = current_uid();
    let Ok(tmp_dev) = fs::metadata("/tmp").map(|m| m.dev()) else {
        return Vec::new();
    };
    let busy = paths_in_use("/tmp/");
    let now = SystemTime::now();
    let mut out = Vec::new();
    let Ok(rd) = fs::read_dir("/tmp") else {
        return out;
    };
    for e in rd.flatten() {
        let p = e.path();
        let Ok(md) = fs::symlink_metadata(&p) else {
            continue;
        };
        // Sockets/lock dirs of live tools (X11, ssh-agent, tmux...) are
        // root- or recent-owned; only plain files/dirs of ours qualify.
        if md.uid() != uid || !(md.is_dir() || md.is_file()) || md.dev() != tmp_dev {
            continue;
        }
        // Display-server locks and pid/lock files mean "someone owns this"
        // even when nothing holds them open.
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with(".X") || name.starts_with(".ICE") || name.ends_with("lock") || name.ends_with(".pid") {
            continue;
        }
        if busy.iter().any(|b| b.starts_with(&p)) {
            continue;
        }
        let Some((bytes, newest, _)) = tree_stat(&p) else {
            continue;
        };
        let age = now.duration_since(newest).unwrap_or_default();
        if age >= STALE_AFTER && bytes >= MIN_ENTRY_BYTES {
            out.push(Stale { path: p, bytes });
        }
    }
    out.sort_by_key(|s| std::cmp::Reverse(s.bytes));
    out
}

/// Delete logs of quickshell instances that are no longer running.
/// Returns bytes freed.
pub fn clean_quickshell_logs() -> u64 {
    let root = PathBuf::from(format!("{}/quickshell", runtime_dir()));
    let by_pid = root.join("by-pid");
    let by_id = root.join("by-id");
    let mut live: BTreeSet<String> = BTreeSet::new();
    if let Ok(rd) = fs::read_dir(&by_pid) {
        for e in rd.flatten() {
            let pid = e.file_name().to_string_lossy().into_owned();
            // Pids get reused (a Chrome thread inherits a dead shell's pid),
            // so a live entry must still BE quickshell.
            let c = fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
            if matches!(c.trim(), "quickshell" | "qs") {
                if let Ok(t) = fs::read_link(e.path()) {
                    if let Some(id) = t.file_name() {
                        live.insert(id.to_string_lossy().into_owned());
                    }
                }
            } else {
                let _ = fs::remove_file(e.path());
            }
        }
    }
    // Any instance holding its dir open (instance.lock, log.log) is alive,
    // whatever its process is called (wrappers, renamed binaries).
    let by_id_s = format!("{}/", by_id.display());
    for held in paths_in_use(&by_id_s) {
        if let Ok(rest) = held.strip_prefix(&by_id) {
            if let Some(first) = rest.components().next() {
                live.insert(first.as_os_str().to_string_lossy().into_owned());
            }
        }
    }
    // No live instance recorded at all would mean we misread the layout:
    // never wipe everything on that basis.
    if live.is_empty() {
        return 0;
    }
    let now = SystemTime::now();
    let mut freed = 0;
    if let Ok(rd) = fs::read_dir(&by_id) {
        for e in rd.flatten() {
            let id = e.file_name().to_string_lossy().into_owned();
            if live.contains(&id) {
                continue;
            }
            let Some((bytes, newest, _)) = tree_stat(&e.path()) else {
                continue;
            };
            if now.duration_since(newest).unwrap_or_default() < QS_KEEP {
                continue;
            }
            if fs::remove_dir_all(e.path()).is_ok() {
                freed += bytes;
            }
        }
    }
    freed
}

/// tmpfs (used, size) in bytes for a mount point.
fn tmpfs_usage(mount: &str) -> (u64, u64) {
    let out = std::process::Command::new("df")
        .args(["-B1", "--output=used,size", mount])
        .output();
    let Ok(o) = out else {
        return (0, 0);
    };
    let s = String::from_utf8_lossy(&o.stdout);
    let mut it = s.lines().nth(1).unwrap_or("").split_whitespace();
    let used = it.next().and_then(|v| v.parse().ok()).unwrap_or(0);
    let size = it.next().and_then(|v| v.parse().ok()).unwrap_or(0);
    (used, size)
}

/// Periodic pass from the watch daemon: auto-clean quickshell logs, record
/// stale /tmp for the UI suggestion.
pub fn sweep() {
    let qs = clean_quickshell_logs();
    if qs >= MIB {
        eprintln!("hygiene: removed {} MB of dead quickshell instance logs", qs / MIB);
    }
    let stale = stale_tmp();
    let stale_bytes: u64 = stale.iter().map(|s| s.bytes).sum();
    let (used, size) = if is_tmpfs("/tmp") { tmpfs_usage("/tmp") } else { (0, 0) };
    let top: Vec<Value> = stale
        .iter()
        .take(5)
        .map(|s| serde_json::json!({"path": s.path.to_string_lossy(), "mb": s.bytes / MIB}))
        .collect();
    let v = serde_json::json!({
        "tmp_used_mb": used / MIB,
        "tmp_size_mb": size / MIB,
        "tmp_stale_mb": stale_bytes / MIB,
        "tmp_stale_count": stale.len(),
        "tmp_stale_top": top,
        // clean-tmp deletes only from this list (what the user was shown).
        "tmp_stale_paths": stale.iter().map(|s| s.path.to_string_lossy().into_owned()).collect::<Vec<_>>(),
        "qs_freed_mb": qs / MIB,
    });
    let _ = fs::create_dir_all(format!("{}/omarchy-task-manager", runtime_dir()));
    let tmp = format!("{}.tmp", report_path());
    if fs::write(&tmp, v.to_string()).is_ok() {
        let _ = fs::rename(&tmp, report_path());
    }
}

pub fn report() -> Value {
    fs::read_to_string(report_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| serde_json::json!({}))
}

/// `task-manager clean-tmp`: delete stale /tmp trees and the dead
/// quickshell logs; print a JSON summary. Only entries that were in the last
/// report (what the suggestion showed) AND are still stale on a fresh scan.
pub fn cmd_clean_tmp(list_only: bool) {
    if list_only {
        for s in stale_tmp() {
            println!("{:>8} MB  {}", s.bytes / MIB, s.path.display());
        }
        return;
    }
    let shown: BTreeSet<String> = report()
        .get("tmp_stale_paths")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|p| p.as_str().map(String::from)).collect())
        .unwrap_or_default();
    let mut removed = Vec::new();
    let mut freed = 0u64;
    for s in stale_tmp() {
        if !shown.contains(s.path.to_string_lossy().as_ref()) {
            continue;
        }
        let ok = if s.path.is_dir() {
            fs::remove_dir_all(&s.path).is_ok()
        } else {
            fs::remove_file(&s.path).is_ok()
        };
        if ok {
            freed += s.bytes;
            removed.push(s.path.to_string_lossy().into_owned());
        }
    }
    let qs = clean_quickshell_logs();
    sweep();
    println!(
        "{}",
        serde_json::json!({"removed": removed, "tmp_freed_mb": freed / MIB, "qs_freed_mb": qs / MIB})
    );
    let _ = std::process::Command::new("notify-send")
        .args([
            "-a",
            "Task Manager",
            &format!("{} MB liberados de /tmp", (freed + qs) / MIB),
            &format!("{} elementos sin uso eliminados", removed.len()),
        ])
        .spawn();
}
