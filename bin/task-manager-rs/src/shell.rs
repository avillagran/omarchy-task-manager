//! Shell recovery: bring the Omarchy shell (quickshell) back when it hangs.
//!
//! `shell-reset` runs `omarchy-restart-shell`, the stock restart (IPC kill,
//! relaunch, re-lock). `shell-reset force` is for a shell too wedged to
//! answer that IPC: it SIGKILLs the shell's supervisor (omarchy-launch-shell,
//! which would otherwise relaunch a shell of its own), every quickshell
//! process of the Omarchy shell config (instances and hung IPC clients), the
//! helpers the shell spawned, and any stuck restart, then starts a fresh one.
//! `shell-reset list` prints what `force` would kill, killing nothing.
//!
//! Helpers are the shell's descendants IN ITS OWN CGROUP: apps started from
//! the launcher live in their own scopes and are never touched. Other
//! quickshell configs (anything not under the Omarchy shell dir) are spared.
//!
//! Both modes re-exec themselves detached first (new session, parent exits
//! at once, so the worker is re-parented away from the shell): the button
//! that asks for the reset lives in the shell that is about to die. One
//! reset at a time per mode, by flock in the private runtime dir.

use crate::{safefs, sys};
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

const DETACHED_ENV: &str = "TASK_MANAGER_SHELL_RESET_DETACHED";
const CAP_PROC: u64 = 256 * 1024;

/// Dry run of the force mode: what it would kill, one `role pid argv` per line.
pub fn cmd_shell_reset_list() {
    let (supervisors, shells, helpers) = targets();
    for (role, pids) in [
        ("supervisor", supervisors),
        ("shell", shells),
        ("helper", helpers),
    ] {
        for p in pids {
            let argv: Vec<String> = cmdline(p).iter().map(|a| crate::cap_str(a)).collect();
            println!("{role}\t{p}\t{}", argv.join(" "));
        }
    }
}

pub fn cmd_shell_reset(force: bool) {
    if env::var_os(DETACHED_ENV).is_none() {
        if detach(force) {
            return;
        }
        eprintln!("shell-reset: could not detach; running inline");
    }
    let rt = match safefs::runtime() {
        Ok(d) => d,
        Err(e) => {
            eprintln!("shell-reset: {e}");
            std::process::exit(1);
        }
    };
    let name = if force { "shell-reset-force.lock" } else { "shell-reset.lock" };
    let _lock = match rt.try_lock(name) {
        Ok(Some(fd)) => fd,
        Ok(None) => {
            eprintln!("shell-reset: already running");
            return;
        }
        Err(e) => {
            eprintln!("shell-reset: lock: {e}");
            std::process::exit(1);
        }
    };
    if force {
        let n = force_kill();
        eprintln!("shell-reset: killed {n} processes");
    }
    restart();
}

/// Re-run ourselves in a new session, stdio detached; the parent returns
/// at once so the worker no longer descends from the shell that asked.
fn detach(force: bool) -> bool {
    let Ok(exe) = env::current_exe() else {
        return false;
    };
    let mut c = Command::new(exe);
    c.arg("shell-reset");
    if force {
        c.arg("force");
    }
    c.env(DETACHED_ENV, "1")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: setsid is async-signal-safe; nothing else runs before exec.
    unsafe {
        c.pre_exec(sys::new_session);
    }
    c.spawn().is_ok()
}

/// OMARCHY_PATH as the running shell sees it (a dev link may point it at a
/// checkout), else ours, else the packaged default.
fn session_omarchy_path() -> String {
    let from_env = |raw: &[u8]| -> Option<String> {
        raw.split(|c| *c == 0)
            .filter_map(|kv| kv.strip_prefix(b"OMARCHY_PATH="))
            .map(|v| String::from_utf8_lossy(v).into_owned())
            .find(|v| v.starts_with('/'))
    };
    for pid in own_pids() {
        let argv = cmdline(pid);
        if argv.iter().take(2).any(|a| base(a) == "omarchy-launch-shell") {
            if let Some(p) = safefs::read_kernel(&format!("/proc/{pid}/environ"), CAP_PROC)
                .and_then(|b| from_env(&b))
            {
                return p;
            }
        }
    }
    env::var("OMARCHY_PATH")
        .ok()
        .filter(|s| s.starts_with('/'))
        .unwrap_or_else(|| "/usr/share/omarchy".into())
}

fn canon(p: &str) -> PathBuf {
    fs::canonicalize(p).unwrap_or_else(|_| PathBuf::from(p))
}

fn cmdline(pid: u64) -> Vec<String> {
    safefs::read_kernel(&format!("/proc/{pid}/cmdline"), CAP_PROC)
        .map(|b| {
            b.split(|c| *c == 0)
                .filter(|s| !s.is_empty())
                .map(|s| String::from_utf8_lossy(s).into_owned())
                .collect()
        })
        .unwrap_or_default()
}

fn base(s: &str) -> &str {
    s.rsplit('/').next().unwrap_or(s)
}

/// (ppid, state) from /proc/PID/stat; comm may hold spaces and parens.
fn stat(pid: u64) -> Option<(u64, char)> {
    let b = safefs::read_kernel(&format!("/proc/{pid}/stat"), 64 * 1024)?;
    let s = String::from_utf8_lossy(&b);
    let rest = s.get(s.rfind(')')? + 1..)?;
    let mut f = rest.split_whitespace();
    let state = f.next()?.chars().next()?;
    let ppid = f.next()?.parse().ok()?;
    Some((ppid, state))
}

fn alive(pid: u64) -> bool {
    matches!(stat(pid), Some((_, st)) if st != 'Z' && st != 'X')
}

fn cgroup(pid: u64) -> String {
    safefs::read_kernel(&format!("/proc/{pid}/cgroup"), 64 * 1024)
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default()
}

fn own_pids() -> Vec<u64> {
    use std::os::unix::fs::MetadataExt;
    let uid = Some(sys::uid());
    let mut v = Vec::new();
    if let Ok(rd) = fs::read_dir("/proc") {
        for e in rd.flatten() {
            let Some(pid) = e.file_name().to_str().and_then(|s| s.parse::<u64>().ok()) else {
                continue;
            };
            if e.metadata().map(|m| Some(m.uid()) == uid).unwrap_or(false) {
                v.push(pid);
            }
        }
    }
    v
}

fn is_quickshell(pid: u64, argv: &[String]) -> bool {
    let a0 = argv.first().map(|s| base(s)).unwrap_or("");
    if a0 == "quickshell" || a0 == "qs" {
        return true;
    }
    fs::read_link(format!("/proc/{pid}/exe"))
        .map(|p| {
            matches!(
                p.file_name().and_then(|n| n.to_str()),
                Some("quickshell" | "qs")
            )
        })
        .unwrap_or(false)
}

/// Does this quickshell argv point at the Omarchy shell config?
fn targets_config(argv: &[String], config: &Path) -> bool {
    argv.iter().skip(1).any(|a| {
        let p = canon(a);
        p == config || p.parent() == Some(config)
    })
}

/// The shell's instances: quickshell for the config with no subcommand
/// (`ipc`, `kill`, `log`... are clients, killed too but not walked).
fn is_instance(argv: &[String]) -> bool {
    argv.get(1).map(|a| a.starts_with('-')).unwrap_or(true)
}

/// Everything to kill, in kill order: supervisors, then shells and clients,
/// then the helpers the shells spawned.
fn targets() -> (Vec<u64>, Vec<u64>, Vec<u64>) {
    let me = std::process::id() as u64;
    let mine = ancestors(me);
    let config = canon(&format!("{}/shell", session_omarchy_path()));
    let pids = own_pids();
    let mut supervisors = Vec::new();
    let mut shells = Vec::new();
    let mut instances = Vec::new();
    let mut children: BTreeMap<u64, Vec<u64>> = BTreeMap::new();
    for &pid in &pids {
        if let Some((ppid, _)) = stat(pid) {
            children.entry(ppid).or_default().push(pid);
        }
        if pid == me || mine.contains(&pid) {
            continue;
        }
        let argv = cmdline(pid);
        if argv.is_empty() {
            continue;
        }
        if is_quickshell(pid, &argv) {
            if targets_config(&argv, &config) {
                shells.push(pid);
                if is_instance(&argv) {
                    instances.push(pid);
                }
            }
        } else if argv
            .iter()
            .take(2)
            .any(|a| matches!(base(a), "omarchy-launch-shell" | "omarchy-restart-shell"))
            || is_normal_reset(&argv)
        {
            // A normal reset stuck behind the hung shell must not race us.
            supervisors.push(pid);
        }
    }
    let mut helpers = Vec::new();
    for &shell in &instances {
        let cg = cgroup(shell);
        let mut stack = children.get(&shell).cloned().unwrap_or_default();
        while let Some(p) = stack.pop() {
            if p == me || mine.contains(&p) || shells.contains(&p) || helpers.contains(&p) {
                continue;
            }
            if cgroup(p) == cg {
                helpers.push(p);
                if let Some(c) = children.get(&p) {
                    stack.extend(c);
                }
            }
        }
    }
    (supervisors, shells, helpers)
}

/// Our own ancestry (a reset run inline from a shell helper must not kill
/// the processes it runs under before it is done).
fn ancestors(me: u64) -> Vec<u64> {
    let mut out = Vec::new();
    let mut p = me;
    while let Some((ppid, _)) = stat(p) {
        if ppid <= 1 || out.contains(&ppid) || out.len() > 64 {
            break;
        }
        out.push(ppid);
        p = ppid;
    }
    out
}

/// Another `task-manager shell-reset` (normal mode) worker.
fn is_normal_reset(argv: &[String]) -> bool {
    argv.len() == 2 && argv[1] == "shell-reset" && base(&argv[0]).starts_with("task-manager")
}

fn sigkill(pids: &[u64]) {
    // Pin each target, re-check it is still ours and alive, then signal.
    // CONT first: SIGKILL reaches stopped tasks, but a stopped parent never
    // reaps its dead children.
    for &p in pids {
        let Ok(fd) = sys::Pidfd::open(p) else { continue };
        if !alive(p) {
            continue;
        }
        fd.signal(sys::SIGCONT);
        fd.signal(sys::SIGKILL);
    }
}

fn force_kill() -> usize {
    let mut total = 0;
    // Two passes: a supervisor caught mid-relaunch may have spawned a shell
    // after the first scan.
    for _ in 0..2 {
        let (supervisors, shells, helpers) = targets();
        if supervisors.is_empty() && shells.is_empty() && helpers.is_empty() {
            break;
        }
        sigkill(&supervisors);
        sigkill(&shells);
        sigkill(&helpers);
        let all: Vec<u64> = supervisors
            .into_iter()
            .chain(shells)
            .chain(helpers)
            .collect();
        total += all.len();
        let deadline = Instant::now() + Duration::from_secs(3);
        while all.iter().any(|&p| alive(p)) && Instant::now() < deadline {
            sleep(Duration::from_millis(50));
        }
    }
    total
}

fn shell_running() -> bool {
    let (_, shells, _) = targets();
    shells.iter().any(|&p| is_instance(&cmdline(p)))
}

fn restart() {
    // omarchy-restart-shell bounds its own waits; the outer timeout is a
    // backstop against a wedged IPC client.
    let ok = crate::run_bounded("omarchy-restart-shell", &[], 90);
    if ok || shell_running() {
        return;
    }
    // Restart failed and no shell is up: launch one from the compositor so it
    // inherits the session environment.
    crate::hypr::dispatch(r#"hl.dsp.exec_cmd("omarchy-launch-shell")"#);
}
