//! The few libc calls std does not expose: dirfd-relative file operations,
//! flock, pidfd signalling, setsid. Declared by hand (no libc crate: the
//! engine builds offline with zero dependencies).

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::raw::{c_char, c_int, c_long, c_uint, c_ulong, c_void};

extern "C" {
    fn openat(dirfd: c_int, path: *const c_char, flags: c_int, ...) -> c_int;
    fn mkdirat(dirfd: c_int, path: *const c_char, mode: c_uint) -> c_int;
    fn renameat(olddirfd: c_int, old: *const c_char, newdirfd: c_int, new: *const c_char) -> c_int;
    fn unlinkat(dirfd: c_int, path: *const c_char, flags: c_int) -> c_int;
    fn flock(fd: c_int, op: c_int) -> c_int;
    fn getuid() -> c_uint;
    fn setsid() -> c_int;
    fn syscall(n: c_long, ...) -> c_long;
    fn poll(fds: *mut PollFd, nfds: c_ulong, timeout: c_int) -> c_int;
    fn getrandom(buf: *mut c_void, len: usize, flags: c_uint) -> isize;
}

#[repr(C)]
struct PollFd {
    fd: c_int,
    events: i16,
    revents: i16,
}

pub const O_RDONLY: c_int = 0;
pub const O_WRONLY: c_int = 1;
#[allow(dead_code)]
pub const O_RDWR: c_int = 2;
pub const O_CREAT: c_int = 0o100;
pub const O_EXCL: c_int = 0o200;
pub const O_NONBLOCK: c_int = 0o4000;
pub const O_CLOEXEC: c_int = 0o2000000;
#[cfg(target_arch = "aarch64")]
pub const O_DIRECTORY: c_int = 0o40000;
#[cfg(target_arch = "aarch64")]
pub const O_NOFOLLOW: c_int = 0o100000;
#[cfg(not(target_arch = "aarch64"))]
pub const O_DIRECTORY: c_int = 0o200000;
#[cfg(not(target_arch = "aarch64"))]
pub const O_NOFOLLOW: c_int = 0o400000;
pub const AT_FDCWD: c_int = -100;

const LOCK_EX: c_int = 2;
const LOCK_NB: c_int = 4;
const EWOULDBLOCK: i32 = 11;
const EEXIST: i32 = 17;

// Same numbers on x86_64 and aarch64 (asm-generic table).
const SYS_PIDFD_SEND_SIGNAL: c_long = 424;
const SYS_PIDFD_OPEN: c_long = 434;

pub const SIGKILL: i32 = 9;
pub const SIGTERM: i32 = 15;
pub const SIGCONT: i32 = 18;
pub const SIGSTOP: i32 = 19;

fn cstr(name: &str) -> io::Result<std::ffi::CString> {
    std::ffi::CString::new(name).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}

fn check(rc: c_int) -> io::Result<c_int> {
    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(rc)
    }
}

pub fn open_at(dir: RawFd, name: &str, flags: c_int, mode: c_uint) -> io::Result<OwnedFd> {
    let c = cstr(name)?;
    let fd = check(unsafe { openat(dir, c.as_ptr(), flags | O_CLOEXEC, mode) })?;
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// mkdirat; an existing entry is fine (the caller verifies what it opens).
pub fn mkdir_at(dir: RawFd, name: &str, mode: c_uint) -> io::Result<()> {
    let c = cstr(name)?;
    match check(unsafe { mkdirat(dir, c.as_ptr(), mode) }) {
        Ok(_) => Ok(()),
        Err(e) if e.raw_os_error() == Some(EEXIST) => Ok(()),
        Err(e) => Err(e),
    }
}

pub fn rename_at(dir: RawFd, old: &str, new: &str) -> io::Result<()> {
    let (o, n) = (cstr(old)?, cstr(new)?);
    check(unsafe { renameat(dir, o.as_ptr(), dir, n.as_ptr()) }).map(|_| ())
}

pub fn unlink_at(dir: RawFd, name: &str) -> io::Result<()> {
    let c = cstr(name)?;
    check(unsafe { unlinkat(dir, c.as_ptr(), 0) }).map(|_| ())
}

/// Non-blocking exclusive flock: Ok(false) when another holder has it.
pub fn try_lock(fd: &OwnedFd) -> io::Result<bool> {
    match check(unsafe { flock(fd.as_raw_fd(), LOCK_EX | LOCK_NB) }) {
        Ok(_) => Ok(true),
        Err(e) if e.raw_os_error() == Some(EWOULDBLOCK) => Ok(false),
        Err(e) => Err(e),
    }
}

pub fn uid() -> u32 {
    unsafe { getuid() }
}

/// New session (for the detached shell reset). Call in the child only.
pub fn new_session() -> io::Result<()> {
    check(unsafe { setsid() }).map(|_| ())
}

pub fn random_u64() -> u64 {
    let mut b = [0u8; 8];
    let n = unsafe { getrandom(b.as_mut_ptr() as *mut c_void, 8, 0) };
    if n != 8 {
        // getrandom cannot fail on a booted Linux; a unique fallback still
        // keeps O_EXCL temp names from colliding.
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0);
        return t ^ ((std::process::id() as u64) << 32);
    }
    u64::from_ne_bytes(b)
}

/// A process handle that cannot be confused with a later process reusing
/// the same pid: every signal goes through it.
pub struct Pidfd(OwnedFd);

impl Pidfd {
    pub fn open(pid: u64) -> io::Result<Pidfd> {
        let pid = i32::try_from(pid).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
        if pid <= 0 {
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
        let fd = unsafe { syscall(SYS_PIDFD_OPEN, pid as c_long, 0 as c_long) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Pidfd(unsafe { OwnedFd::from_raw_fd(fd as c_int) }))
    }

    pub fn signal(&self, sig: i32) -> bool {
        let rc = unsafe {
            syscall(
                SYS_PIDFD_SEND_SIGNAL,
                self.0.as_raw_fd() as c_long,
                sig as c_long,
                std::ptr::null::<c_void>(),
                0 as c_long,
            )
        };
        rc == 0
    }

    /// True once the process has exited (pidfd turns readable).
    pub fn exited(&self, timeout_ms: i32) -> bool {
        let mut p = PollFd {
            fd: self.0.as_raw_fd(),
            events: 1, // POLLIN
            revents: 0,
        };
        let rc = unsafe { poll(&mut p, 1, timeout_ms) };
        rc > 0 && p.revents != 0
    }
}
