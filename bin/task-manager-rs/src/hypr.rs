//! Hyprland IPC over its sockets, with deadlines and byte caps: a hung or
//! flooding compositor must never stall or bloat the engine.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::{Duration, Instant};

const TIMEOUT: Duration = Duration::from_secs(2);
/// Largest reply accepted (clients/binds on a busy desktop stay far below).
pub const REPLY_CAP: usize = 4 * 1024 * 1024;
/// Longest socket2 event line forwarded.
pub const EVENT_LINE_CAP: usize = 4096;

fn instance_dir(rt: &str) -> Option<String> {
    let cur = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").unwrap_or_default();
    let ok = |sig: &str| {
        !sig.is_empty()
            && !sig.contains('/')
            && sig != ".."
            && Path::new(&format!("{rt}/hypr/{sig}/.socket.sock")).exists()
    };
    if ok(&cur) {
        return Some(format!("{rt}/hypr/{cur}"));
    }
    // Stale signature (compositor restarted under us): first live instance.
    let mut names: Vec<String> = std::fs::read_dir(format!("{rt}/hypr"))
        .ok()?
        .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
        .collect();
    names.sort();
    names.into_iter().find(|n| ok(n)).map(|n| format!("{rt}/hypr/{n}"))
}

fn socket(name: &str) -> Option<UnixStream> {
    let rt = crate::safefs::xdg_runtime().ok()?;
    let dir = instance_dir(&rt)?;
    UnixStream::connect(format!("{dir}/{name}")).ok()
}

/// One request on the command socket ("j/clients", "dispatch ...").
/// None on timeout, error or a reply over `cap`.
pub fn request_capped(req: &str, cap: usize) -> Option<String> {
    let mut s = socket(".socket.sock")?;
    s.set_write_timeout(Some(TIMEOUT)).ok()?;
    s.write_all(req.as_bytes()).ok()?;
    let deadline = Instant::now() + TIMEOUT;
    let mut out = Vec::new();
    let mut buf = [0u8; 65536];
    loop {
        let left = deadline.checked_duration_since(Instant::now())?;
        s.set_read_timeout(Some(left.max(Duration::from_millis(1)))).ok()?;
        let n = s.read(&mut buf).ok()?;
        if n == 0 {
            break;
        }
        if out.len() + n > cap {
            return None;
        }
        out.extend_from_slice(&buf[..n]);
    }
    String::from_utf8(out).ok()
}

pub fn request(req: &str) -> Option<String> {
    request_capped(req, REPLY_CAP)
}

/// Parsed JSON reply of a `j/...` query.
pub fn query(what: &str) -> Option<crate::json::Value> {
    crate::json::from_str(&request(&format!("j/{what}"))?).ok()
}

/// A window address as Hyprland prints it ("0x" + hex): the only shape
/// ever interpolated into a dispatch.
pub fn valid_address(a: &str) -> bool {
    a.len() > 2
        && a.len() <= 34
        && a.starts_with("0x")
        && a[2..].bytes().all(|c| c.is_ascii_hexdigit())
}

pub fn dispatch(lua: &str) -> bool {
    request_capped(&format!("dispatch {lua}"), 4096)
        .map(|r| r.trim() == "ok")
        .unwrap_or(false)
}

/// Event stream (socket2), read line by line with a per-line cap: longer
/// lines are dropped whole and reading continues at the next newline.
pub fn events(mut on_line: impl FnMut(&str) -> bool) {
    let Some(mut s) = socket(".socket2.sock") else {
        eprintln!("follow: cannot connect to the Hyprland event socket");
        std::process::exit(1);
    };
    let mut buf = [0u8; 8192];
    let mut line: Vec<u8> = Vec::with_capacity(EVENT_LINE_CAP);
    let mut overflow = false;
    loop {
        let n = match s.read(&mut buf) {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        for &b in &buf[..n] {
            if b == b'\n' {
                if !overflow {
                    if let Ok(l) = std::str::from_utf8(&line) {
                        if !on_line(l) {
                            return;
                        }
                    }
                }
                line.clear();
                overflow = false;
            } else if !overflow {
                if line.len() >= EVENT_LINE_CAP {
                    overflow = true;
                    line.clear();
                } else {
                    line.push(b);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::valid_address;

    #[test]
    fn addresses() {
        assert!(valid_address("0xaaab0a3c8500"));
        assert!(!valid_address("0x"));
        assert!(!valid_address("0xzz"));
        assert!(!valid_address("0x1\" }) os.exit() --"));
    }
}
