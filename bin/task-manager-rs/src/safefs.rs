//! Private state directories and the only way the engine touches its own
//! files.
//!
//! * runtime: $XDG_RUNTIME_DIR/omarchy-task-manager (XDG_RUNTIME_DIR must be
//!   absolute, ours and 0700; there is no shared /tmp fallback);
//! * state:   ${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-task-manager.
//!
//! Each directory is opened once with O_DIRECTORY|O_NOFOLLOW and verified on
//! the open descriptor (a directory, owned by us, no group/other access).
//! Every file operation is then relative to that descriptor: reads refuse
//! symlinks, FIFOs and devices and are size-capped; writes go to a fresh
//! O_EXCL temp file that is fsynced and renamed over the target.

use crate::sys;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, OwnedFd};
use std::os::unix::fs::{MetadataExt, PermissionsExt};

pub const DIR_NAME: &str = "omarchy-task-manager";
/// Default read cap for our own files.
pub const READ_CAP: u64 = 1024 * 1024;

pub struct Dir {
    fd: OwnedFd,
}

fn err(msg: &str) -> io::Error {
    io::Error::other(msg.to_string())
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.contains('/')
        && !name.contains('\0')
}

/// Open `dir` (already validated base) / DIR_NAME, creating it 0700.
fn open_child(base: &OwnedFd) -> io::Result<Dir> {
    sys::mkdir_at(base.as_raw_fd(), DIR_NAME, 0o700)?;
    let fd = sys::open_at(
        base.as_raw_fd(),
        DIR_NAME,
        sys::O_RDONLY | sys::O_DIRECTORY | sys::O_NOFOLLOW,
        0,
    )?;
    let f = File::from(fd);
    let md = f.metadata()?;
    if !md.is_dir() || md.uid() != sys::uid() {
        return Err(err("state directory is not ours"));
    }
    if md.mode() & 0o077 != 0 {
        // Ours but too open (older versions created it 0755): tighten it on
        // the verified descriptor itself.
        f.set_permissions(std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(Dir { fd: f.into() })
}

/// Open an absolute base directory by path and check it is ours.
fn open_base(path: &str, require_private: bool) -> io::Result<OwnedFd> {
    if !path.starts_with('/') {
        return Err(err("base directory must be absolute"));
    }
    let fd = sys::open_at(sys::AT_FDCWD, path, sys::O_RDONLY | sys::O_DIRECTORY, 0)?;
    let f = File::from(fd);
    let md = f.metadata()?;
    if !md.is_dir() || md.uid() != sys::uid() {
        return Err(err("base directory is not owned by this user"));
    }
    if require_private && md.mode() & 0o077 != 0 {
        return Err(err("XDG_RUNTIME_DIR is not private (0700)"));
    }
    Ok(f.into())
}

/// $XDG_RUNTIME_DIR, validated. Fails closed when unset or unsafe.
pub fn xdg_runtime() -> io::Result<String> {
    let rt = std::env::var("XDG_RUNTIME_DIR").map_err(|_| err("XDG_RUNTIME_DIR is not set"))?;
    open_base(&rt, true)?;
    Ok(rt)
}

pub fn runtime() -> io::Result<Dir> {
    let rt = std::env::var("XDG_RUNTIME_DIR").map_err(|_| err("XDG_RUNTIME_DIR is not set"))?;
    open_child(&open_base(&rt, true)?)
}

pub fn state() -> io::Result<Dir> {
    let base = match std::env::var("XDG_STATE_HOME") {
        Ok(s) if s.starts_with('/') => s,
        _ => {
            let home = std::env::var("HOME").map_err(|_| err("HOME is not set"))?;
            if !home.starts_with('/') {
                return Err(err("HOME must be absolute"));
            }
            format!("{home}/.local/state")
        }
    };
    if std::fs::symlink_metadata(&base).is_err() {
        // First run: ~/.local/state may not exist yet (0700 like XDG says).
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&base)?;
    }
    open_child(&open_base(&base, false)?)
}

use std::os::unix::fs::DirBuilderExt;

impl Dir {
    /// Read a regular file we own, at most `cap` bytes (larger = error).
    pub fn read_capped(&self, name: &str, cap: u64) -> io::Result<Vec<u8>> {
        if !valid_name(name) {
            return Err(err("bad file name"));
        }
        let fd = sys::open_at(
            self.fd.as_raw_fd(),
            name,
            sys::O_RDONLY | sys::O_NOFOLLOW | sys::O_NONBLOCK,
            0,
        )?;
        let f = File::from(fd);
        let md = f.metadata()?;
        if !md.is_file() || md.uid() != sys::uid() {
            return Err(err("not a regular file we own"));
        }
        if md.len() > cap {
            return Err(err("file too large"));
        }
        let mut buf = Vec::with_capacity(md.len() as usize);
        f.take(cap + 1).read_to_end(&mut buf)?;
        if buf.len() as u64 > cap {
            return Err(err("file too large"));
        }
        Ok(buf)
    }

    pub fn read_string(&self, name: &str) -> Option<String> {
        self.read_capped(name, READ_CAP)
            .ok()
            .and_then(|b| String::from_utf8(b).ok())
    }

    /// Atomic replace: O_EXCL temp (0600) + fsync + renameat.
    pub fn write_atomic(&self, name: &str, data: &[u8]) -> io::Result<()> {
        if !valid_name(name) {
            return Err(err("bad file name"));
        }
        let tmp = format!(".{name}.{:016x}", sys::random_u64());
        let fd = sys::open_at(
            self.fd.as_raw_fd(),
            &tmp,
            sys::O_WRONLY | sys::O_CREAT | sys::O_EXCL | sys::O_NOFOLLOW,
            0o600,
        )?;
        let mut f = File::from(fd);
        let res = f
            .write_all(data)
            .and_then(|_| f.sync_all())
            .and_then(|_| sys::rename_at(self.fd.as_raw_fd(), &tmp, name));
        if res.is_err() {
            let _ = sys::unlink_at(self.fd.as_raw_fd(), &tmp);
        }
        res
    }

    /// Open (creating 0600) a lock file and try to take it. Ok(None) = busy.
    /// The lock lives as long as the returned descriptor.
    pub fn try_lock(&self, name: &str) -> io::Result<Option<OwnedFd>> {
        if !valid_name(name) {
            return Err(err("bad file name"));
        }
        let fd = sys::open_at(
            self.fd.as_raw_fd(),
            name,
            sys::O_RDONLY | sys::O_CREAT | sys::O_NOFOLLOW | sys::O_NONBLOCK,
            0o600,
        )?;
        let f = File::from(fd);
        let md = f.metadata()?;
        if !md.is_file() || md.uid() != sys::uid() {
            return Err(err("lock is not a regular file we own"));
        }
        let fd: OwnedFd = f.into();
        Ok(if sys::try_lock(&fd)? { Some(fd) } else { None })
    }
}

/// Bounded read of a kernel file (/proc, /sys): at most `cap` bytes, no
/// symlink following on the final component, never blocks on a FIFO.
pub fn read_kernel(path: &str, cap: u64) -> Option<Vec<u8>> {
    let fd = sys::open_at(
        sys::AT_FDCWD,
        path,
        sys::O_RDONLY | sys::O_NOFOLLOW | sys::O_NONBLOCK,
        0,
    )
    .ok()?;
    let mut buf = Vec::new();
    File::from(fd).take(cap).read_to_end(&mut buf).ok()?;
    Some(buf)
}

/// Write a cgroup control file (no symlink following).
pub fn write_kernel(path: &str, value: &str) -> bool {
    let Ok(fd) = sys::open_at(sys::AT_FDCWD, path, sys::O_WRONLY | sys::O_NOFOLLOW, 0) else {
        return false;
    };
    File::from(fd).write_all(value.as_bytes()).is_ok()
}

#[cfg(test)]
mod tests {
    use super::valid_name;

    #[test]
    fn names() {
        assert!(valid_name("prefs.json"));
        assert!(!valid_name("../x"));
        assert!(!valid_name("a/b"));
        assert!(!valid_name(".."));
        assert!(!valid_name(""));
    }
}
