"""omarchy-task-manager light engine: the same commands and JSON as the Rust
engine (bin/task-manager-rs), on the stock Python runtime, nothing to build.

Run by bin/task-manager-light.sh (python3 -I -S: isolated, no user site,
stdlib only), imported as a module so its bytecode is cached in the user's
cache directory instead of being recompiled on every call.

`watch` runs the same pressure safety net and memory governor as the Rust
engine. To stay light it skips work nobody needs: while memory is calm and
nothing is limited the governor only notes which app has the focus (no
cgroup walk), and the per-app CPU series is sampled only while the card is
open.

Same safety rules as the Rust engine: every signal goes through a pidfd,
targets are `PID` or `PID:START` (START = /proc/PID/stat starttime) and a
reused pid is refused; only cgroups inside the user's own delegated subtree
are ever written; private files live in 0700 directories opened once and
used through their descriptor (no symlinks, size caps, atomic replace).
"""

import errno
import fcntl
import json
import os
import select
import signal
import stat as st
import sys
import time

CGROOT = "/sys/fs/cgroup"
DIR_NAME = "omarchy-task-manager"
MIN_BG_RSS_KB = 30 * 1024
MIN_FREEZE_MB = 100
SQUEEZE_MIN = 96 * 1024 * 1024
SQUEEZE_MAX = 512 * 1024 * 1024
FIELD_CAP = 256
MAX_APPS = 256
MAX_CLIENTS = 1024
CAP_DEFAULT = 1024 * 1024
CAP_STATUS = 64 * 1024
CAP_CMDLINE = 256 * 1024
READ_CAP = 1024 * 1024
HYPR_TIMEOUT = 2.0
REPLY_CAP = 4 * 1024 * 1024
EVENT_LINE_CAP = 4096
HIST_LEN = 120
MARKER = "frozen.json"
HISTORY = "history.json"
PREFS = "prefs.json"
GOV_STATE = "governor.json"
EMPTY_HISTORY = '{"ts":[],"cpu":[],"mem":[],"gpu":null,"cores":[],"apps":{}}'
UID = os.getuid()
SELF = os.getpid()

# Never touch the compositor, shell, audio stack, or terminals.
EXCLUDE_COMMS = {
    "Hyprland", "quickshell", "pipewire", "wireplumber", "waybar", "hyprpaper",
    "hypridle", "hyprlock", "uwsm", "dbus-broker", "hermes", "systemd", "foot",
    "alacritty", "kitty", "ghostty", "wezterm", "bash", "zsh", "fish",
    "task-manager",
}

PREF_KEYS = {
    "barStats": "bool", "showGraphs": "bool", "graphDetail": "bool",
    "sparklines": "bool", "veils": "bool", "watchdog": "bool",
    "barMode": "mode", "cardW": "px", "cardH": "px", "sortBy": "sort",
    "watchMaxRam": "ram", "watchMaxCpu": "cpu", "engine": "engine",
}


def warn(msg):
    sys.stderr.write("task-manager: %s\n" % msg)


def out(v):
    sys.stdout.write(json.dumps(v, separators=(",", ":")) + "\n")


def cap_str(s):
    return s[:FIELD_CAP]


# ---------- kernel files ----------

def read_kernel(path, cap=CAP_DEFAULT):
    """Bounded read, no symlink on the last component, never blocks."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError:
        return None
    try:
        chunks, left = [], cap
        while left > 0:
            b = os.read(fd, min(left, 65536))
            if not b:
                break
            chunks.append(b)
            left -= len(b)
        return b"".join(chunks)
    except OSError:
        return None
    finally:
        os.close(fd)


def read_trim(path, cap=CAP_DEFAULT):
    b = read_kernel(path, cap)
    return None if b is None else b.decode("utf-8", "replace").strip()


def write_kernel(path, value):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return False
    try:
        os.write(fd, value.encode())
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


# ---------- private directories ----------

def _valid_name(name):
    return name not in ("", ".", "..") and "/" not in name and "\0" not in name


class Dir:
    def __init__(self, fd):
        self.fd = fd

    def read_capped(self, name, cap=READ_CAP):
        if not _valid_name(name):
            return None
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                         dir_fd=self.fd)
        except OSError:
            return None
        try:
            s = os.fstat(fd)
            if not st.S_ISREG(s.st_mode) or s.st_uid != UID or s.st_size > cap:
                return None
            b = os.read(fd, cap + 1)
            return None if len(b) > cap else b
        except OSError:
            return None
        finally:
            os.close(fd)

    def read_string(self, name):
        b = self.read_capped(name)
        if b is None:
            return None
        try:
            return b.decode("utf-8")
        except UnicodeDecodeError:
            return None

    def write_atomic(self, name, data):
        if not _valid_name(name):
            return False
        tmp = ".%s.%s" % (name, os.urandom(8).hex())
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600, dir_fd=self.fd)
        except OSError:
            return False
        try:
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
            os.fsync(fd)
            os.close(fd)
            fd = -1
            os.rename(tmp, name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
            return True
        except OSError:
            if fd >= 0:
                os.close(fd)
            try:
                os.unlink(tmp, dir_fd=self.fd)
            except OSError:
                pass
            return False

    def try_lock(self, name):
        """Lock fd, None when busy; raises OSError when unusable."""
        if not _valid_name(name):
            raise OSError("bad file name")
        fd = os.open(name, os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
                     0o600, dir_fd=self.fd)
        s = os.fstat(fd)
        if not st.S_ISREG(s.st_mode) or s.st_uid != UID:
            os.close(fd)
            raise OSError("lock is not a regular file we own")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return None
        return fd


def _open_base(path, private):
    if not path.startswith("/"):
        raise OSError("base directory must be absolute")
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    s = os.fstat(fd)
    if not st.S_ISDIR(s.st_mode) or s.st_uid != UID or (private and s.st_mode & 0o077):
        os.close(fd)
        raise OSError("base directory is not ours (or not 0700)")
    return fd


def _open_child(base):
    try:
        try:
            os.mkdir(DIR_NAME, 0o700, dir_fd=base)
        except FileExistsError:
            pass
        fd = os.open(DIR_NAME, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                     dir_fd=base)
    finally:
        os.close(base)
    s = os.fstat(fd)
    if not st.S_ISDIR(s.st_mode) or s.st_uid != UID:
        os.close(fd)
        raise OSError("state directory is not ours")
    if s.st_mode & 0o077:
        os.fchmod(fd, 0o700)
    return Dir(fd)


def xdg_runtime():
    rt = os.environ.get("XDG_RUNTIME_DIR", "")
    os.close(_open_base(rt, True))
    return rt


_dirs = {}


def runtime():
    if "rt" not in _dirs:
        try:
            _dirs["rt"] = _open_child(_open_base(os.environ.get("XDG_RUNTIME_DIR", ""), True))
        except OSError as e:
            warn("runtime dir unavailable: %s" % e)
            _dirs["rt"] = None
    return _dirs["rt"]


def state_dir():
    if "st" not in _dirs:
        try:
            base = os.environ.get("XDG_STATE_HOME", "")
            if not base.startswith("/"):
                home = os.environ.get("HOME", "")
                if not home.startswith("/"):
                    raise OSError("HOME must be absolute")
                base = home + "/.local/state"
            os.makedirs(base, 0o700, exist_ok=True)
            _dirs["st"] = _open_child(_open_base(base, False))
        except OSError as e:
            warn("state dir unavailable: %s" % e)
            _dirs["st"] = None
    return _dirs["st"]


def read_json(d, name):
    text = d.read_string(name) if d else None
    try:
        return json.loads(text) if text else None
    except ValueError:
        return None


# ---------- processes ----------

class Pidfd:
    """A process handle a reused pid cannot be confused with."""

    def __init__(self, pid):
        if not 0 < pid <= 0x7FFFFFFF:
            raise OSError(errno.EINVAL, "bad pid")
        self.fd = os.pidfd_open(pid)

    def signal(self, sig):
        try:
            signal.pidfd_send_signal(self.fd, sig)
            return True
        except OSError:
            return False

    def exited(self):
        try:
            return bool(select.select([self.fd], [], [], 0)[0])
        except OSError:
            return True

    def close(self):
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1

    def __del__(self):
        self.close()


def pin(pid):
    try:
        return Pidfd(pid)
    except OSError:
        return None


# Per-pid memo: one /proc read per pid per command (per tick in `watch`).
_memo = {}


def memo_reset():
    _memo.clear()


def _memo_get(kind, pid, fn):
    key = (kind, pid)
    if key not in _memo:
        _memo[key] = fn(pid)
    return _memo[key]


def comm(pid):
    return _memo_get("comm", pid, lambda p: read_trim("/proc/%d/comm" % p) or "?")


def _status(pid):
    s = read_trim("/proc/%d/status" % pid, CAP_STATUS)
    rss = swap = 0
    if s:
        for line in s.splitlines():
            if line.startswith("VmRSS:"):
                rss = _first_int(line[6:])
            elif line.startswith("VmSwap:"):
                swap = _first_int(line[7:])
    return rss, swap


def _first_int(s):
    try:
        return int(s.split()[0])
    except (IndexError, ValueError):
        return 0


def rss_kb(pid):
    return _memo_get("status", pid, _status)[0]


def swap_kb(pid):
    return _memo_get("status", pid, _status)[1]


def _stat_fields(pid):
    s = read_trim("/proc/%d/stat" % pid, CAP_STATUS)
    if not s:
        return None
    i = s.rfind(")")
    return s[i + 1:].split() if i >= 0 else None


def stat_fields(pid):
    return _memo_get("stat", pid, _stat_fields)


def parse_starttime(stat):
    i = stat.rfind(")")
    if i < 0:
        return None
    f = stat[i + 1:].split()
    if not f or f[0] in ("Z", "X"):
        return None
    try:
        return int(f[19])
    except (IndexError, ValueError):
        return None


def start_time(pid):
    """Uncached: identity checks must see the kernel's current answer."""
    s = read_trim("/proc/%d/stat" % pid, CAP_STATUS)
    return parse_starttime(s) if s else None


def pid_state(pid):
    f = stat_fields(pid)
    return f[0][:1] if f and f[0][:1].isalpha() else "?"


def pid_stopped(pid):
    f = _stat_fields(pid)
    return bool(f) and f[0] == "T"


def proc_jiffies(pid):
    f = stat_fields(pid)
    try:
        return int(f[11]) + int(f[12])
    except (TypeError, IndexError, ValueError):
        return 0


def pid_uid(pid):
    try:
        return os.stat("/proc/%d" % pid).st_uid
    except OSError:
        return -1


def owned_by_us(pid):
    return pid_uid(pid) == UID


def all_pids():
    """[(pid, uid)] for every process but us, one /proc pass per memo."""
    if "all" not in _memo:
        rows = []
        for name in os.listdir("/proc"):
            if name.isdigit():
                pid = int(name)
                if pid != SELF:
                    u = pid_uid(pid)
                    if u >= 0:
                        rows.append((pid, u))
        _memo["all"] = rows
    return _memo["all"]


def user_comms():
    if "families" not in _memo:
        m = {}
        for pid, u in all_pids():
            if u == UID:
                m.setdefault(comm(pid), []).append(pid)
        _memo["families"] = m
    return _memo["families"]


def comm_family(pid):
    return list(user_comms().get(comm(pid), [])) or [pid]


def proc_cgroup(pid):
    raw = read_trim("/proc/%d/cgroup" % pid)
    if not raw or "::" not in raw:
        return None
    path = raw.split("::", 1)[1].splitlines()[0]
    return path, unit_of(path)


def unit_of(cgpath):
    return cgpath.rstrip("/").rsplit("/", 1)[-1]


def is_app_scope(unit):
    return unit.startswith("app-") and unit.endswith(".scope")


def unit_procs(cgpath):
    raw = read_trim("%s%s/cgroup.procs" % (CGROOT, cgpath)) or ""
    return [int(x) for x in raw.split() if x.isdigit()]


def family_scopes(family):
    seen = []
    for p in family:
        cg = proc_cgroup(p)
        if cg and is_app_scope(cg[1]) and all(u != cg[1] for _, u in seen):
            seen.append(cg)
    return seen


def scope_frozen(cgpath):
    return read_trim("%s%s/cgroup.freeze" % (CGROOT, cgpath)) == "1"


def mem_current(cgpath):
    try:
        return int(read_trim("%s%s/memory.current" % (CGROOT, cgpath)) or 0)
    except ValueError:
        return 0


def user_root():
    return "/user.slice/user-%d.slice/user@%d.service" % (UID, UID)


def cg_path_ok(cgpath):
    return (isinstance(cgpath, str) and cgpath.startswith(user_root() + "/")
            and not any(c in (".", "..") for c in cgpath.split("/")) and "\0" not in cgpath)


def cg_write(cgpath, name, value):
    return cg_path_ok(cgpath) and write_kernel("%s%s/%s" % (CGROOT, cgpath, name), value)


def signal_member(pid, family_comm, sig):
    """Pin first, then re-check comm and owner, then signal."""
    fd = pin(pid)
    if not fd:
        return False
    if read_trim("/proc/%d/comm" % pid) != family_comm or not owned_by_us(pid):
        return False
    return fd.signal(sig)


def signal_pid(pid, start, sig):
    fd = pin(pid)
    if not fd:
        return False
    now = start_time(pid)
    if now is None or (start is not None and start != now):
        return False
    return fd.signal(sig)


# ---------- marker: what WE froze ----------

def marker_read():
    v = read_json(runtime(), MARKER)
    pids, scopes = [], []
    if isinstance(v, dict):
        for x in (v.get("pids") or [])[:4096]:
            if (isinstance(x, list) and len(x) == 2 and all(isinstance(n, int) for n in x)):
                pids.append((x[0], x[1]))
        scopes = [s for s in (v.get("scopes") or [])[:4096] if cg_path_ok(s)]
    return pids, scopes


def marker_write(pids, scopes):
    d = runtime()
    if d:
        d.write_atomic(MARKER, json.dumps({"pids": [list(p) for p in pids], "scopes": scopes},
                                          separators=(",", ":")).encode())


def marker_pids():
    return [p for p, s in marker_read()[0] if start_time(p) == s]


def marker_units():
    return [unit_of(s) for s in marker_read()[1]]


def marker_add(pid):
    s = start_time(pid)
    if s is None:
        return
    pids, scopes = marker_read()
    marker_write([p for p in pids if p[0] != pid] + [(pid, s)], scopes)


def marker_remove(pid):
    pids, scopes = marker_read()
    marker_write([p for p in pids if p[0] != pid], scopes)


def marker_add_scope(cgpath):
    pids, scopes = marker_read()
    if cgpath not in scopes:
        scopes.append(cgpath)
    marker_write(pids, scopes)


def marker_remove_scope(cgpath):
    pids, scopes = marker_read()
    marker_write(pids, [s for s in scopes if s != cgpath])


# ---------- Hyprland ----------

def _instance_dir(rt):
    def ok(sig):
        return (sig and "/" not in sig and sig != ".."
                and os.path.exists("%s/hypr/%s/.socket.sock" % (rt, sig)))
    cur = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    if ok(cur):
        return "%s/hypr/%s" % (rt, cur)
    try:
        names = sorted(os.listdir(rt + "/hypr"))
    except OSError:
        return None
    for n in names:
        if ok(n):
            return "%s/hypr/%s" % (rt, n)
    return None


def _socket(name):
    import socket
    try:
        d = _instance_dir(xdg_runtime())
    except OSError:
        return None
    if not d:
        return None
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM | socket.SOCK_CLOEXEC)
    try:
        s.settimeout(HYPR_TIMEOUT)
        s.connect("%s/%s" % (d, name))
        return s
    except OSError:
        s.close()
        return None


def hypr_request(req, cap=REPLY_CAP):
    s = _socket(".socket.sock")
    if not s:
        return None
    try:
        s.sendall(req.encode())
        deadline = time.monotonic() + HYPR_TIMEOUT
        buf = bytearray()
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return None
            s.settimeout(left)
            b = s.recv(65536)
            if not b:
                break
            if len(buf) + len(b) > cap:
                return None
            buf += b
        return buf.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    finally:
        s.close()


def hypr_query(what):
    r = hypr_request("j/" + what)
    try:
        return json.loads(r) if r else None
    except ValueError:
        return None


def valid_address(a):
    return (isinstance(a, str) and 2 < len(a) <= 34 and a.startswith("0x")
            and all(c in "0123456789abcdefABCDEF" for c in a[2:]))


def hypr_dispatch(lua):
    r = hypr_request("dispatch " + lua, 4096)
    return bool(r) and r.strip() == "ok"


def _i(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else 0


def monitors():
    arr = hypr_query("monitors")
    mons = []
    for m in (arr if isinstance(arr, list) else [])[:64]:
        if not isinstance(m, dict) or not isinstance(m.get("name"), str):
            continue
        ws = m.get("activeWorkspace")
        mons.append({
            "name": cap_str(m["name"]),
            "active_ws": _i(ws.get("id")) if isinstance(ws, dict) else 0,
            "x": _i(m.get("x")), "y": _i(m.get("y")),
            "focused": m.get("focused") is True,
            "w": _i(m.get("width")), "h": _i(m.get("height")),
        })
    return mons


def clients(mons):
    arr = hypr_query("clients")
    wins = []
    for c in (arr if isinstance(arr, list) else [])[:MAX_CLIENTS]:
        if not isinstance(c, dict) or c.get("mapped") is False:
            continue
        at, size, pid = c.get("at"), c.get("size"), c.get("pid")
        addr = c.get("address")
        if not (isinstance(at, list) and isinstance(size, list) and _i(pid) > 0
                and valid_address(addr)):
            continue
        mi = _i(c.get("monitor")) if c.get("monitor") is not None else -1
        ws = c.get("workspace")
        title = c.get("title") if isinstance(c.get("title"), str) else ""
        cls = c.get("class") if isinstance(c.get("class"), str) else ""
        wins.append({
            "addr": addr,
            "x": _i(at[0]) if at else 0, "y": _i(at[1]) if len(at) > 1 else 0,
            "w": _i(size[0]) if size else 0, "h": _i(size[1]) if len(size) > 1 else 0,
            "ws": _i(ws.get("id")) if isinstance(ws, dict) else 0,
            "mon": mons[mi]["name"] if 0 <= mi < len(mons) else "",
            "pinned": c.get("pinned") is True,
            "title": title[:60], "class": cls[:128], "_pid": pid,
        })
    return wins


def windows_by_pid(mons):
    by = {}
    for w in clients(mons):
        by.setdefault(w.pop("_pid"), []).append(w)
    return by


def focused_pid():
    v = hypr_query("activewindow")
    return v.get("pid") if isinstance(v, dict) and _i(v.get("pid")) > 0 else None


# ---------- memory and pressure ----------

def mem_info():
    """(total_mb, avail_mb, psi_some10, psi_full10, swap_total_mb, swap_used_mb)"""
    vals = {}
    for line in (read_trim("/proc/meminfo") or "").splitlines():
        k, _, rest = line.partition(":")
        if k in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree"):
            vals[k] = _first_int(rest) // 1024
    some = full = 0.0
    for line in (read_trim("/proc/pressure/memory") or "").splitlines():
        for tok in line.split():
            if tok.startswith("avg10="):
                try:
                    n = float(tok[6:])
                except ValueError:
                    n = 0.0
                if line.startswith("some"):
                    some = n
                elif line.startswith("full"):
                    full = n
    st_ = vals.get("SwapTotal", 0)
    return (vals.get("MemTotal", 0), vals.get("MemAvailable", 0), some, full,
            st_, max(0, st_ - vals.get("SwapFree", 0)))


def zswap_status():
    p = "/sys/module/zswap/parameters/enabled"
    zram = any("zram" in l for l in (read_trim("/proc/swaps") or "").splitlines()[1:])
    if not os.path.exists(p):
        return False, False, zram
    return True, read_trim(p) == "Y", zram


def read_prefs():
    v = read_json(state_dir(), PREFS)
    outp = {}
    if not isinstance(v, dict):
        return outp
    for k, kind in PREF_KEYS.items():
        x = v.get(k)
        if x is None:
            continue
        if kind == "bool":
            ok = isinstance(x, bool)
        elif kind in ("mode", "sort", "px", "engine"):
            ok = isinstance(x, str) and pref_value(kind, x) is not None
        else:
            ok = (isinstance(x, int) and not isinstance(x, bool)
                  and pref_value(kind, str(x)) is not None)
        if ok:
            outp[k] = x
    return outp


def pref_value(kind, value):
    if kind == "bool":
        return {"1": True, "true": True, "0": False, "false": False}.get(value)
    if kind == "mode":
        return value if value in ("off", "numbers", "graph") else None
    if kind == "sort":
        return value if value in ("ram", "cpu", "name") else None
    if kind == "engine":
        return value if value in ("auto", "light") else None
    if not value.isdigit() or len(value) > 6:
        return None
    n = int(value)
    if kind == "px":
        return str(n) if 300 <= n <= 3000 else None
    if kind == "ram":
        return n if 50 <= n <= 99 else None
    if kind == "cpu":
        return n if n == 0 or 50 <= n <= 99 else None
    return None


def pref_num(key, dflt):
    v = read_prefs().get(key)
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    return float(v) if isinstance(v, (int, float)) else dflt


def _env_num(name, dflt):
    try:
        return float(os.environ[name])
    except (KeyError, ValueError):
        return dflt


def crit_avail_pct():
    v = _env_num("TM_CRIT_AVAIL_PCT", None)
    return v if v is not None else 100.0 - min(max(pref_num("watchMaxRam", 94.0), 50.0), 99.0)


def crit_cpu_pct():
    v = _env_num("TM_CRIT_CPU_PCT", None)
    if v is not None:
        return v
    n = pref_num("watchMaxCpu", 0.0)
    return 0.0 if n <= 0 else min(max(n, 50.0), 99.0)


def freeze_critical(pct, crit, psi_full, crit_psi):
    """Freezing is the last resort: real scarcity, or close to it with a
    severe stall. PSI alone never freezes (zram reclaim bursts)."""
    return pct < crit or (pct < crit * 1.5 and psi_full >= crit_psi)


def pressure(total, avail, psi_full, crit=None):
    pct = avail * 100.0 / total if total > 0 else 100.0
    if crit is None:
        crit = crit_avail_pct()
    return pct, freeze_critical(pct, crit, psi_full, _env_num("TM_CRIT_PSI", 30.0))


def cpu_times():
    total, cores = (0, 0), []
    for line in (read_trim("/proc/stat") or "").splitlines():
        if not line.startswith("cpu"):
            break
        is_total = line.startswith("cpu ")
        try:
            v = [int(x) for x in line.split()[1:]]
        except ValueError:
            continue
        if len(v) < 7:
            continue
        busy = v[0] + v[1] + v[2] + v[5] + v[6] + (v[7] if len(v) > 7 else 0)
        rec = (busy, busy + v[3] + v[4])
        if is_total:
            total = rec
        else:
            cores.append(rec)
    return total[0], total[1], cores


def now_from_history():
    v = read_json(runtime(), HISTORY)
    try:
        if time.time() - v["ts"][-1] > 15:
            return None
        return {"cpu": round(float(v["cpu"][-1]), 1), "mem": round(float(v["mem"][-1]), 1)}
    except (TypeError, KeyError, IndexError, ValueError):
        return None


# ---------- state ----------

def collect_background(by_pid, marks):
    windowed = {comm(p) for p in by_pid} - EXCLUDE_COMMS
    groups = {}
    for pid, u in all_pids():
        if u != UID or pid in by_pid:
            continue
        c = comm(pid)
        if c in EXCLUDE_COMMS or c in windowed:
            continue
        g = groups.setdefault(c, [0, 0, []])
        g[0] += rss_kb(pid)
        g[1] += swap_kb(pid)
        g[2].append(pid)
    units = marker_units()
    rows = []
    for name, (rkb, skb, pids) in groups.items():
        biggest = max(pids, key=rss_kb)
        cg = proc_cgroup(biggest)
        if cg and is_app_scope(cg[1]):
            mech, unit, frozen = "scope", cg[1], scope_frozen(cg[0]) or cg[1] in units
        else:
            mech, unit, frozen = "signal", "", biggest in marks and pid_stopped(biggest)
        if rkb + skb < MIN_BG_RSS_KB and not frozen:
            continue
        rows.append({"pid": biggest, "name": name, "rss_mb": rkb // 1024,
                     "swap_mb": skb // 1024, "procs": len(pids), "unit": unit,
                     "mechanism": mech, "frozen": frozen})
    rows.sort(key=lambda r: -(r["rss_mb"] + r["swap_mb"]))
    return rows[:40]


def collect_system(by_pid):
    return [row for row, _ in system_groups(by_pid)]


def system_groups(by_pid):
    """The top system groups with every pid of each: the history sums their
    CPU (comm_family only knows the user's own pids)."""
    windowed = {comm(p) for p in by_pid} - EXCLUDE_COMMS
    groups = {}
    for pid, u in all_pids():
        if u == UID or pid in by_pid:
            continue
        c = comm(pid)
        if c in EXCLUDE_COMMS or c in windowed:
            continue
        r = rss_kb(pid)
        if r == 0:
            continue
        g = groups.setdefault(c, [0, []])
        g[0] += r
        g[1].append(pid)
    rows = [({"pid": max(pids), "name": n, "rss_mb": kb // 1024, "procs": len(pids)}, pids)
            for n, (kb, pids) in groups.items()]
    rows.sort(key=lambda r: -r[0]["rss_mb"])
    return rows[:6]


def app_rows(by_pid, brief=False):
    """One row per windowed app. `brief` (card closed: only the frozen state
    for the veils and the badge matters) looks at the window's own process
    instead of walking /proc for its whole family."""
    marks, units = marker_pids(), marker_units()
    apps = []
    for pid, wins in by_pid.items():
        c = comm(pid)
        if c in EXCLUDE_COMMS:
            continue
        family = [pid] if brief else comm_family(pid)
        scopes = family_scopes(family)
        rss = sum(rss_kb(p) for p in family)
        if scopes:
            frozen = any(scope_frozen(cg) for cg, _ in scopes) or any(u in units for _, u in scopes)
            mech, unit = "scope", scopes[0][1]
        else:
            frozen = pid in marks and pid_stopped(pid)
            cg = proc_cgroup(pid)
            mech, unit = "signal", cg[1] if cg else ""
        apps.append({"pid": pid, "name": cap_str(c), "title": cap_str(wins[0]["title"]),
                     "class": wins[0]["class"],
                     "rss_mb": rss // 1024, "unit": cap_str(unit), "mechanism": mech,
                     "frozen": frozen, "windows": len(wins), "procs": len(family),
                     "wins": wins[:64]})
    apps.sort(key=lambda a: -a["rss_mb"])
    return apps[:MAX_APPS], marks


def cmd_state(brief=False):
    """`state --brief`: what the bar and the veils need while the card is
    closed (windowed apps and their frozen state), without walking /proc."""
    mons = monitors()
    by_pid = windows_by_pid(mons)
    apps, marks = app_rows(by_pid, brief)
    background = [] if brief else collect_background(by_pid, marks)
    system = [] if brief else collect_system(by_pid)
    for row in apps + background + system:
        row["start"] = start_time(row["pid"]) or 0
        row["name"] = cap_str(row["name"])
    total, avail, psi, psi_full, swap_total, swap_used = mem_info()
    zs_avail, zs_on, zram = zswap_status()
    avail_pct, critical = pressure(total, avail, psi_full)
    sug = []
    for b in background:
        if not b["frozen"] and b["swap_mb"] >= 200 and b["rss_mb"] <= 100 and b["start"]:
            sug.append({"kind": "sleeper", "name": b["name"], "swap_mb": b["swap_mb"],
                        "text": "%s has %d MB asleep in swap; closing it frees that memory"
                                % (b["name"], b["swap_mb"]),
                        "action": "kill", "pid": b["pid"], "start": b["start"]})
    gov = governor_status()
    lim = gov["limited"] if gov else []
    if lim:
        names = ", ".join("%s ≤%d MB" % (cap_str(e["name"]), e["high_mb"]) for e in lim[:3])
        sug.append({"kind": "governor", "action": "none", "pid": 0,
                    "count": len(lim), "names": names,
                    "text": "Holding back %d background process(es) to keep the desktop smooth: %s"
                            % (len(lim), names)})
    if avail_pct < 25.0:
        sug.append({"kind": "pressure", "action": "none", "pid": 0,
                    "text": "Memory pressure is high: pause the apps you are not using"})
    out({
        "engine": "python",
        "mem": {"total_mb": total, "avail_mb": avail, "psi_some10": round(psi, 2),
                "swap_total_mb": swap_total, "swap_used_mb": swap_used},
        "pressure": {"avail_pct": round(avail_pct, 1), "critical": critical},
        "zswap": {"available": zs_avail, "enabled": zs_on, "zram": zram},
        "governor": gov,
        "now": now_from_history(),
        "prefs": read_prefs(),
        "monitors": mons,
        "apps": apps,
        "background": background,
        "system": system,
        "suggestions": sug,
    })


# ---------- actions ----------

def parse_target(arg):
    p, sep, s = arg.partition(":")
    if not p.isdigit() or not p.isascii():
        return None
    pid = int(p)
    if not 1 < pid <= 0x7FFFFFFF:
        return None
    if not sep:
        return pid, None
    if not s or not s.isdigit() or not s.isascii() or len(s) > 20:
        return None
    return pid, int(s)


def verify(t):
    pid, start = t
    fd = pin(pid)
    now = start_time(pid)
    if fd is None or now is None or (start is not None and start != now):
        warn("pid %d is gone or was reused; nothing done" % pid)
        sys.exit(3)
    fd.close()
    return now


def freeze_family(pid):
    c = comm(pid)
    family = comm_family(pid)
    scopes = family_scopes(family)
    stopped_pids, stopped_scopes = [], []
    for cgpath, _ in scopes:
        if cg_write(cgpath, "cgroup.freeze", "1"):
            marker_add_scope(cgpath)
            stopped_scopes.append(cgpath)
        cur = mem_current(cgpath)
        if cur > 0:
            cg_write(cgpath, "memory.high", str(min(max(cur // 4, SQUEEZE_MIN), SQUEEZE_MAX)))
    scoped = {p for cg, _ in scopes for p in unit_procs(cg)}
    for p in family:
        if p not in scoped and signal_member(p, c, signal.SIGSTOP):
            marker_add(p)
            st = start_time(p)
            if st is not None:
                stopped_pids.append((p, st))
    return stopped_pids, stopped_scopes


def thaw_family(pid):
    c = comm(pid)
    family = comm_family(pid)
    scopes = family_scopes(family)
    for cgpath, _ in scopes:
        cg_write(cgpath, "memory.high", "max")
        cg_write(cgpath, "cgroup.freeze", "0")
        marker_remove_scope(cgpath)
    for p in family:
        if not scopes or pid_stopped(p):
            signal_member(p, c, signal.SIGCONT)
        marker_remove(p)


def kill_survivors(pinned):
    deadline = time.monotonic() + 2.5
    while any(not fd.exited() for fd in pinned) and time.monotonic() < deadline:
        time.sleep(0.1)
    for fd in pinned:
        if not fd.exited():
            fd.signal(signal.SIGKILL)


def cmd_kill(t):
    verify(t)
    c = comm(t[0])
    pinned = []
    for p in comm_family(t[0]):
        fd = pin(p)
        if fd and read_trim("/proc/%d/comm" % p) == c and owned_by_us(p):
            pinned.append(fd)
    thaw_family(t[0])
    for fd in pinned:
        fd.signal(signal.SIGTERM)
    kill_survivors(pinned)


def cmd_focus(t):
    verify(t)
    cg = proc_cgroup(t[0])
    members = set(unit_procs(cg[0])) if cg and is_app_scope(cg[1]) else {t[0]}
    for w in clients(monitors()):
        if w["_pid"] in members:
            hypr_dispatch('hl.dsp.focus({ window = "address:%s" })' % w["addr"])
            return


def cmd_freeze_pid(t):
    s = verify(t)
    if not pid_stopped(t[0]) and signal_pid(t[0], s, signal.SIGSTOP):
        marker_add(t[0])


def cmd_thaw_pid(t):
    s = verify(t)
    signal_pid(t[0], s, signal.SIGCONT)
    marker_remove(t[0])


def cmd_kill_pid(t):
    fd = pin(t[0])
    s = verify(t)
    if fd is None or start_time(t[0]) != s:
        return
    fd.signal(signal.SIGCONT)
    marker_remove(t[0])
    fd.signal(signal.SIGTERM)
    kill_survivors([fd])


def proc_role(pid):
    raw = read_kernel("/proc/%d/cmdline" % pid, CAP_CMDLINE)
    if not raw:
        return ""
    s = raw.decode("utf-8", "replace").replace("\0", " ")
    i = s.find("--type=")
    if i >= 0:
        t = s[i + 7:].split(" ", 1)[0]
        if t == "utility":
            j = s.find("--utility-sub-type=")
            return s[j + 19:].split(" ", 1)[0].split(".")[0] if j >= 0 else "utility"
        return {"renderer": "renderer", "gpu-process": "gpu", "zygote": "zygote",
                "crashpad-handler": "crashpad"}.get(t, t)
    return "crashpad" if "crashpad" in s else ""


ROLE_RANK = {"browser": 0, "renderer": 1, "gpu": 2, "network": 3, "audio": 4,
             "utility": 5, "storage": 5, "zygote": 6, "crashpad": 7}


def cmd_procs(t):
    verify(t)
    rows = []
    for p in comm_family(t[0]):
        rows.append({"pid": p, "start": 0, "comm": cap_str(comm(p)),
                     "role": cap_str("browser" if p == t[0] else proc_role(p)),
                     "rss_mb": rss_kb(p) // 1024, "state": pid_state(p)})
    rows.sort(key=lambda r: (ROLE_RANK.get(r["role"], 1), -r["rss_mb"]))
    rows = rows[:40]
    for r in rows:
        r["start"] = start_time(r["pid"]) or 0
    out(rows)


def cmd_pref(key, value):
    kind = PREF_KEYS.get(key)
    val = pref_value(kind, value) if kind else None
    if val is None:
        return
    d = state_dir()
    if not d:
        return
    fd = None
    try:
        deadline = time.monotonic() + 2.0
        while fd is None:
            fd = d.try_lock("prefs.lock")
            if fd is None:
                if time.monotonic() >= deadline:
                    warn("preferences lock timed out")
                    return
                time.sleep(.01)
        # Serialize the whole read/modify/replace, across both engines.
        v = read_prefs()
        v[key] = val
        d.write_atomic(PREFS, json.dumps(v, separators=(",", ":")).encode())
    except OSError:
        warn("preferences lock unavailable")
    finally:
        if fd is not None:
            os.close(fd)


def cmd_history():
    v = read_json(runtime(), HISTORY)
    sys.stdout.write((json.dumps(v, separators=(",", ":")) if isinstance(v, dict)
                      else EMPTY_HISTORY) + "\n")


def cmd_popup(arg):
    d = runtime()
    if not d:
        sys.exit(1)
    if arg is None:
        b = d.read_capped("popup", 16)
        print(1 if b and b[:1] == b"1" else 0)
    elif arg in ("0", "1"):
        if not d.write_atomic("popup", arg.encode()):
            sys.exit(1)
    else:
        usage()


def cmd_binds():
    r = hypr_request("j/binds", 2 * 1024 * 1024)
    try:
        arr = json.loads(r) if r else []
    except ValueError:
        arr = []
    descs = {b.get("description") for b in arr if isinstance(b, dict)} if isinstance(arr, list) else set()
    out({"show": "Task Manager" in descs, "reset": "Force reset shell" in descs})


def cmd_follow():
    s = _socket(".socket2.sock")
    if not s:
        warn("follow: cannot connect to the Hyprland event socket")
        sys.exit(1)
    s.settimeout(None)
    keep = ("activewindowv2>>", "movewindowv2>>", "closewindow>>", "openwindow>>",
            "workspace>>", "changefloatingmode>>")
    line, overflow = bytearray(), False
    while True:
        try:
            b = s.recv(8192)
        except OSError:
            return
        if not b:
            return
        for ch in b:
            if ch == 10:
                if not overflow:
                    try:
                        l = line.decode("utf-8")
                    except UnicodeDecodeError:
                        l = ""
                    if l.startswith(keep):
                        try:
                            sys.stdout.write(l + "\n")
                            sys.stdout.flush()
                        except OSError:
                            return
                line.clear()
                overflow = False
            elif not overflow:
                if len(line) >= EVENT_LINE_CAP:
                    overflow = True
                    line.clear()
                else:
                    line.append(ch)


def wait_stdin_eof():
    while True:
        try:
            if not os.read(0, 256):
                return
        except OSError:
            return


def cmd_veil_lock():
    d = runtime()
    try:
        fd = d.try_lock("veil.lock") if d else -1
    except OSError:
        fd = -1
    if fd is None:
        print("busy")
        return
    if fd < 0:
        print("error")
        sys.exit(1)
    print("owned", flush=True)
    wait_stdin_eof()


# ---------- memory governor ----------
# Same policy as bin/task-manager-rs/src/governor.rs (kept in step with it):
# squeeze windowless batch work early with memory.high so the desktop stays
# fluid, hand cold pages of long-idle windowed apps to zram in small
# memory.reclaim chunks, never touch the session, the focused app or
# anything we froze. Every limit is recorded in governor.json with the value
# it replaced and restored when pressure clears, at start, on
# `governor-release` and when the shell goes away. One difference: while
# memory is calm and nothing is limited it does not walk the cgroup tree at
# all, only notes which app has the focus.

MIB = 1024 * 1024
GOV_FLOOR = 256 * MIB
GOV_MIN_LEAF = 256 * MIB
IDLE_AFTER = 120.0
RECLAIM_CHUNK_MAX = 64 * MIB
RECLAIM_BUDGET = {"calm": 0, "elevated": 192 * MIB, "critical": 384 * MIB}
SELF_PSI_HOLD = 25.0
SELF_PSI_NO_RECLAIM = 10.0
RECLAIM_PER_IDLE_MAX = 512 * MIB
PEAK_WINDOW = 120.0
GENERIC_COMMS = {"bash", "sh", "dash", "zsh", "fish", "env", "nice", "timeout", "make",
                 "python", "python3", "node", "bun", "deno", "perl", "ruby", "java", "uwsm"}
PROTECT_COMMS = {"Hyprland", "quickshell", "pipewire", "pipewire-pulse", "wireplumber",
                 "hyprlock", "hypridle", "uwsm", "dbus-broker", "dbus-daemon", "hermes",
                 "task-manager"}


def gov_level(avail_pct, psi_some, prev):
    """Pressure level with hysteresis: elevated under 25% available (or
    stalls under 33%), critical under 12%."""
    if avail_pct < (15.0 if prev == "critical" else 12.0):
        return "critical"
    if prev == "calm":
        elevated = avail_pct < 25.0 or (avail_pct < 33.0 and psi_some >= 20.0)
    else:
        elevated = avail_pct < 30.0 or psi_some >= 10.0
    return "elevated" if elevated else "calm"


def gov_classify(path, comms, focused, windowed):
    if ("/session.slice/" in path or path.endswith("/init.scope")
            or "omarchy-task-manager" in path or any(c in PROTECT_COMMS for c in comms)):
        return "protected"
    if focused:
        return "foreground"
    if windowed:
        return "interactive"
    return "service" if path.endswith(".service") else "batch"


def gov_next_high(cur, high, level, squeeze, self_psi, peak):
    """("keep",) | ("set", bytes) | ("release",). high None = unlimited."""
    if not squeeze:
        if high is None:
            return ("keep",)
        nxt = high + max(high // 4, 64 * MIB)
        return ("release",) if nxt >= cur + 512 * MIB else ("set", nxt)
    if high is None and cur < GOV_MIN_LEAF:
        return ("keep",)
    if self_psi >= SELF_PSI_HOLD:
        return ("set", high + high // 16) if high is not None else ("keep",)
    if high is not None and cur < high // 10 * 9:
        return ("keep",)
    factor = 0.92 if level == "critical" else 0.97
    base = high if high is not None else cur
    target = max(int(base * factor), max(GOV_FLOOR, max(peak, cur) // 2))
    if high is not None and target >= high:
        return ("keep",)
    if high is None and target >= cur:
        return ("keep",)
    return ("set", target)


def gov_reclaim_chunk(cur, self_psi, budget_left):
    if cur < GOV_MIN_LEAF or self_psi >= SELF_PSI_NO_RECLAIM:
        return 0
    return min(cur // 20, RECLAIM_CHUNK_MAX, budget_left)


def gov_leaves():
    out = []

    def walk(rel, depth):
        if len(out) >= 4096:
            return
        try:
            it = os.scandir(CGROOT + rel)
        except OSError:
            return
        child = False
        with it:
            for e in it:
                try:
                    isdir = e.is_dir(follow_symlinks=False)
                except OSError:
                    isdir = False
                if isdir and depth < 8:
                    child = True
                    walk(rel + "/" + e.name, depth + 1)
        if not child:
            out.append(rel)

    walk(user_root(), 0)
    return out


def cg_int(rel, name):
    try:
        return int(read_trim("%s%s/%s" % (CGROOT, rel, name)) or "")
    except ValueError:
        return None


def cg_self_psi(rel):
    for line in (read_trim(CGROOT + rel + "/memory.pressure") or "").splitlines():
        if line.startswith("some"):
            for tok in line.split():
                if tok.startswith("avg10="):
                    try:
                        return float(tok[6:])
                    except ValueError:
                        return 0.0
    return 0.0


def cg_frozen(rel):
    ev = read_trim(CGROOT + rel + "/cgroup.events") or ""
    return "frozen 1" in ev.splitlines() or read_trim(CGROOT + rel + "/cgroup.freeze") == "1"


def gov_label(rel, pids):
    return comm(max(pids, key=rss_kb)) if pids else unit_of(rel)


def gov_state():
    v = read_json(runtime(), GOV_STATE)
    return v if isinstance(v, dict) else {}


def gov_write_state(v):
    d = runtime()
    if d:
        d.write_atomic(GOV_STATE, json.dumps(v, separators=(",", ":")).encode())


def gov_load_saved():
    saved = gov_state().get("saved")
    out = {}
    if isinstance(saved, dict):
        for rel, rec in list(saved.items())[:4096]:
            if not cg_path_ok(rel) or not isinstance(rec, dict):
                continue
            orig = rec.get("orig")
            if not (orig == "max" or (isinstance(orig, str) and orig.isdigit() and len(orig) <= 20)):
                orig = "max"
            wrote = rec.get("wrote")
            out[rel] = (orig, wrote if isinstance(wrote, int) and not isinstance(wrote, bool) else 0)
    return out


def governor_release():
    """Restore every limit we set that still holds the value we wrote
    (anything else was changed since, by a thaw or the user, and is theirs)."""
    skip = set(marker_units())
    n = 0
    for rel, (orig, wrote) in gov_load_saved().items():
        if unit_of(rel) in skip or cg_int(rel, "memory.high") != wrote:
            continue
        if cg_write(rel, "memory.high", orig):
            n += 1
    gov_write_state({"level": "calm", "enabled": True, "saved": {}, "limited": [], "reclaimed_mb": 0})
    return n


def governor_status():
    """Governor status for `state`, re-validated (only what the UI shows)."""
    v = gov_state()
    if not v:
        return None
    lim = []
    for e in (v.get("limited") if isinstance(v.get("limited"), list) else [])[:64]:
        if isinstance(e, dict):
            lim.append({"unit": cap_str(str(e.get("unit", ""))), "name": cap_str(str(e.get("name", ""))),
                        "cur_mb": _i(e.get("cur_mb")), "high_mb": _i(e.get("high_mb"))})
    level = v.get("level") if v.get("level") in ("calm", "elevated", "critical") else "calm"
    return {"level": level, "enabled": v.get("enabled") is not False, "limited": lim,
            "reclaimed_mb": _i(v.get("reclaimed_mb"))}


class Governor:
    def __init__(self):
        n = governor_release()
        if n:
            sys.stderr.write("governor: restored %d memory.high limit(s) left by a previous run\n" % n)
        self.level = "calm"
        self.saved = {}
        self.last_focus = {}        # leaf -> time it last held the focus
        self.focus_comm = {}        # comm -> time it last held the focus
        self.idle_reclaimed = {}
        self.recent_peak = {}
        self.started = time.monotonic()
        self.reclaimed = 0
        self.status_level = None

    def persist(self):
        v = gov_state()
        v["saved"] = {k: {"orig": o, "wrote": w} for k, (o, w) in self.saved.items()}
        gov_write_state(v)

    def write_status(self, limited, enabled=True):
        gov_write_state({
            "level": self.level, "enabled": enabled,
            "saved": {k: {"orig": o, "wrote": w} for k, (o, w) in self.saved.items()},
            "limited": [{"unit": cap_str(u), "name": cap_str(n), "cur_mb": c // MIB, "high_mb": h // MIB}
                        for u, n, c, h in limited],
            "reclaimed_mb": self.reclaimed // MIB,
        })
        self.status_level = self.level

    def peak(self, rel, cur, now):
        p = self.recent_peak.get(rel)
        if p is None or cur >= p[0] or now - p[1] > PEAK_WINDOW:
            p = self.recent_peak[rel] = (cur, now)
        return p[0]

    def note_focus(self, now):
        """Calm path: remember what has the focus, cheaply (no tree walk)."""
        f = focused_pid()
        if not f:
            return f, None
        c = read_trim("/proc/%d/comm" % f)
        if c and c not in GENERIC_COMMS:
            self.focus_comm[c] = now
        cg = proc_cgroup(f)
        if cg:
            self.last_focus[cg[0]] = now
            self.idle_reclaimed.pop(cg[0], None)
        return f, c

    def tick(self, avail_pct, psi_some):
        if pref_num("governor", 1.0) <= 0:
            if self.saved:
                governor_release()
                self.saved.clear()
            self.write_status([], False)
            return
        forced = os.environ.get("TM_GOV_LEVEL")
        lvl = forced if forced in ("calm", "elevated", "critical") else gov_level(avail_pct, psi_some, self.level)
        if lvl != self.level:
            sys.stderr.write("governor: %s -> %s (%.1f%% avail, psi_some %.1f)\n"
                             % (self.level, lvl, avail_pct, psi_some))
            self.level = lvl
        now = time.monotonic()
        if lvl == "calm" and not self.saved:
            self.note_focus(now)
            if self.status_level != "calm":
                self.write_status([])
            return
        self.full_tick(lvl, now)

    def full_tick(self, lvl, now):
        mons = monitors()
        windowed = {w["_pid"] for w in clients(mons)}
        blind = not mons or not windowed
        windowed_comms = {comm(p) for p in windowed} - GENERIC_COMMS
        focus, fcomm = self.note_focus(now)
        if fcomm in GENERIC_COMMS:
            fcomm = None
        ours_frozen = set(marker_units())
        limited, idle, live = [], [], set()
        budget = RECLAIM_BUDGET[lvl]
        for rel in gov_leaves():
            pids = unit_procs(rel)
            if not pids:
                continue
            live.add(rel)
            comms = [comm(p) for p in pids]
            focused = (focus in pids) or (fcomm is not None and fcomm in comms)
            if focused:
                self.last_focus[rel] = now
                self.idle_reclaimed.pop(rel, None)
            if cg_frozen(rel) or unit_of(rel) in ours_frozen:
                continue
            has_win = any(p in windowed for p in pids) or any(c in windowed_comms for c in comms)
            cls = gov_classify(rel, comms, focused, has_win)
            cur = cg_int(rel, "memory.current") or 0
            high = cg_int(rel, "memory.high")
            psi = cg_self_psi(rel)
            rec = self.saved.get(rel)
            ours = rec is not None and high == rec[1]
            if not ours and self.saved.pop(rel, None) is not None:
                self.persist()
            if high is not None and not ours:
                continue        # a limit someone else set is theirs
            squeeze = not blind and ((cls == "batch" and lvl != "calm")
                                     or (cls == "service" and lvl == "critical"))
            if not squeeze and not ours:
                if cls == "interactive" and lvl != "calm" and not blind:
                    since = max([self.last_focus.get(rel, self.started)]
                                + [self.focus_comm[c] for c in comms if c in self.focus_comm])
                    if now - since >= IDLE_AFTER:
                        idle.append((rel, cur, psi, now - since))
                continue
            if ours and cls in ("foreground", "interactive", "protected"):
                action = ("release",)
            else:
                action = gov_next_high(cur, high, lvl, squeeze, psi, self.peak(rel, cur, now))
            if action[0] == "keep":
                if high is not None:
                    limited.append((unit_of(rel), gov_label(rel, pids), cur, high))
            elif action[0] == "set":
                v = action[1] & ~(64 * 1024 - 1)
                # Ownership is recorded BEFORE the write: a daemon killed in
                # between must still find (and restore) this limit.
                self.saved[rel] = (rec[0] if rec else "max", v)
                self.persist()
                if not ours:
                    sys.stderr.write("governor: limiting %s (%s, %d MB) at %d MB [%s]\n"
                                     % (gov_label(rel, pids), unit_of(rel), cur // MIB, v // MIB, lvl))
                if cg_write(rel, "memory.high", str(v)):
                    limited.append((unit_of(rel), gov_label(rel, pids), cur, v))
            else:
                cg_write(rel, "memory.high", rec[0] if rec else "max")
                self.saved.pop(rel, None)
                self.persist()
                sys.stderr.write("governor: released %s (%s)\n" % (gov_label(rel, pids), unit_of(rel)))
        for d in (self.saved, self.last_focus, self.idle_reclaimed, self.recent_peak):
            for k in [k for k in d if k not in live]:
                del d[k]
        # Proactive reclaim: longest idle first, then biggest.
        idle.sort(key=lambda i: (-(int(i[3]) // 60), -i[1]))
        for rel, cur, psi, _ in idle:
            left = min(max(RECLAIM_PER_IDLE_MAX - self.idle_reclaimed.get(rel, 0), 0), budget)
            chunk = gov_reclaim_chunk(cur, psi, left)
            if not chunk:
                continue
            before = cg_int(rel, "memory.current") or 0
            cg_write(rel, "memory.reclaim", str(chunk))   # EAGAIN is normal
            self.reclaimed += max(before - (cg_int(rel, "memory.current") or 0), 0)
            self.idle_reclaimed[rel] = self.idle_reclaimed.get(rel, 0) + chunk
            budget -= chunk
            if budget <= 0:
                break
        self.write_status(limited)


def cmd_governor_explain():
    mons = monitors()
    windowed = {w["_pid"] for w in clients(mons)}
    windowed_comms = {comm(p) for p in windowed} - GENERIC_COMMS
    focus = focused_pid()
    fcomm = comm(focus) if focus else None
    if fcomm in GENERIC_COMMS:
        fcomm = None
    print("windowed comms: %s  focused: %s %s" % (sorted(windowed_comms), focus, fcomm))
    for rel in gov_leaves():
        pids = unit_procs(rel)
        cur = cg_int(rel, "memory.current") or 0
        if not pids or cur < 64 * MIB:
            continue
        comms = [comm(p) for p in pids]
        focused = focus in pids or (fcomm is not None and fcomm in comms)
        has_win = any(p in windowed for p in pids) or any(c in windowed_comms for c in comms)
        high = read_trim(CGROOT + rel + "/memory.high") or ""
        print("%6d MB  %-11s high=%-10s %s" % (cur // MIB, gov_classify(rel, comms, focused, has_win),
                                               high, unit_of(rel)))


# ---------- watch: the pressure safety net ----------

_children = []


def notify(name, title, body):
    import subprocess
    try:
        return subprocess.Popen(["python3", "-I", "-S",
                                 os.path.join(os.path.dirname(__file__), "pause-notification.py"),
                                 name, title, body], stdin=subprocess.PIPE,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                close_fds=True)
    except OSError:
        return None


def reap():
    for p, deadline in list(_children):
        if p.poll() is not None:
            _children.remove((p, deadline))
        elif time.monotonic() > deadline:
            p.kill()


def notify_text(name, mb):
    lang = os.environ.get("LANGUAGE") or os.environ.get("LANG") or "en"
    if lang.replace(":", ".").replace("_", ".").split(".")[0] == "es":
        return ("%s pausada automáticamente (%d MB)" % (name, mb),
                "Se reanudará automáticamente cuando los recursos estén estables; también puedes reanudarla desde el Administrador de tareas.")
    return ("%s auto-paused (%d MB)" % (name, mb),
            "It will resume automatically once resources are stable; you can also resume it from the Task Manager.")


class Recovery:
    """One app per ten continuously healthy seconds, using monotonic time."""
    def __init__(self):
        self.since = None

    def ready(self, now, healthy):
        if not healthy:
            self.since = None
            return False
        if self.since is None:
            self.since = now
        if now - self.since < 10.0:
            return False
        self.since = now
        return True


def recovery_healthy(total, pct, some, full, cpu, cpu_max, crit_avail, recover):
    return (total > 0 and pct > max(recover, crit_avail * 1.5)
            and some < 10.0 and full < 1.0
            and (cpu_max <= 0 or cpu < max(cpu_max - 10.0, 0.0)))


class AutoPause:
    def __init__(self, name, mb, before, after):
        self.name, self.mb = name, mb
        self.notification = None
        self.pids = [p for p in after[0] if p not in before[0]]
        self.scopes = [s for s in after[1] if s not in before[1]]

    def close_notification(self):
        if self.notification is not None:
            self.notification.stdin.close()
            _children.append((self.notification, time.monotonic() + 6))
            self.notification = None

    def prune(self):
        pids, scopes = marker_read()
        self.pids = [p for p in self.pids if p in pids and start_time(p[0]) == p[1]
                     and pid_stopped(p[0])]
        self.scopes = [s for s in self.scopes if s in scopes and scope_frozen(s)]
        active = bool(self.pids or self.scopes)
        if not active:
            self.close_notification()
        return active

    def resume(self):
        # Only the exact stops this watchdog owns, never the whole comm family.
        for s in list(self.scopes):
            if cg_write(s, "memory.high", "max") and cg_write(s, "cgroup.freeze", "0"):
                marker_remove_scope(s)
                self.scopes.remove(s)
        for p, st in list(self.pids):
            if signal_pid(p, st, signal.SIGCONT):
                marker_remove(p)
                self.pids.remove((p, st))
        done = not (self.pids or self.scopes)
        if done:
            self.close_notification()
        return done


def freeze_biggest(skip):
    by_pid = windows_by_pid(monitors())
    marks = marker_pids()
    marked_scopes = marker_read()[1]
    focus = focused_pid()
    fcg = proc_cgroup(focus) if focus else None
    focus_unit = fcg[1] if fcg else None
    best = None

    def consider(pid, name, kb, unit, frozen):
        nonlocal best
        if frozen or kb < MIN_FREEZE_MB * 1024 or name in skip or pid == focus:
            return
        if unit and unit == focus_unit:
            return
        if best is None or kb // 1024 > best[2]:
            best = (pid, name, kb // 1024)

    for pid in by_pid:
        c = comm(pid)
        if c in EXCLUDE_COMMS:
            continue
        family = comm_family(pid)
        scopes = family_scopes(family)
        frozen = (any(p in marks or pid_stopped(p) for p in family)
                  or any(scope_frozen(cg) or cg in marked_scopes for cg, _ in scopes))
        consider(pid, c, sum(rss_kb(p) for p in family), scopes[0][1] if scopes else "", frozen)
    for bg in collect_background(by_pid, marks):
        if bg["mechanism"] == "scope":
            family = comm_family(bg["pid"])
            paused = (bg["frozen"] or any(p in marks or pid_stopped(p) for p in family)
                      or any(scope_frozen(cg) or cg in marked_scopes
                             for cg, _ in family_scopes(family)))
            consider(bg["pid"], bg["name"], bg["rss_mb"] * 1024, "", paused)
    if not best:
        return None
    pid, name, mb = best
    before = marker_read()
    stopped = freeze_family(pid)
    paused = AutoPause(name, mb, before, stopped)
    if not (paused.pids or paused.scopes):
        return None
    title, body = notify_text(name, mb)
    paused.notification = notify(name, cap_str(title), body)
    return paused


class Hist:
    def __init__(self):
        self.ts, self.cpu, self.mem, self.cores = [], [], [], []
        self.apps, self.seen, self.tick = {}, {}, 0

    def push(self, cpu, mem, cores, apps):
        self.tick += 1
        self.ts.append(int(time.time()))
        self.cpu.append(cpu)
        self.mem.append(mem)
        self.cores.append(cores)
        n = len(self.ts)
        for k, rss, c in apps:
            e = self.apps.setdefault(k, ([0.0] * (n - 1), [0.0] * (n - 1)))
            e[0].append(rss)
            e[1].append(c)
            self.seen[k] = self.tick
        for e in self.apps.values():
            while len(e[0]) < n:
                e[0].append(e[0][-1] if e[0] else 0.0)
                e[1].append(0.0)
        for k in [k for k in self.apps if self.tick - self.seen.get(k, 0) >= 30]:
            del self.apps[k]
            self.seen.pop(k, None)
        drop = n - HIST_LEN
        if drop > 0:
            for lst in (self.ts, self.cpu, self.mem, self.cores):
                del lst[:drop]
            for e in self.apps.values():
                del e[0][:drop]
                del e[1][:drop]

    def write(self):
        r1 = lambda v: [round(x, 1) for x in v]
        d = runtime()
        if d:
            d.write_atomic(HISTORY, json.dumps({
                "ts": self.ts, "cpu": r1(self.cpu), "mem": r1(self.mem), "gpu": None,
                "cores": [r1(c) for c in self.cores],
                "apps": {k: {"rss": r1(e[0]), "cpu": r1(e[1])} for k, e in self.apps.items()},
            }, separators=(",", ":")).encode())


def popup_open():
    d = runtime()
    b = d.read_capped("popup", 16) if d else None
    return bool(b) and b[:1] == b"1"


def sample_history(hist, prev, prev_apps):
    """System CPU/RAM always (two small reads); the per-app series, the one
    part that walks /proc, only while the card is open to show it."""
    cur = cpu_times()
    dt = max(cur[1] - prev[0][1], 1)
    cpu = (cur[0] - prev[0][0]) * 100.0 / dt
    ncores = max(len(cur[2]), 1)
    cores = []
    for i, (b, t) in enumerate(cur[2]):
        pb, pt = prev[0][2][i] if i < len(prev[0][2]) else (b, t)
        cores.append((b - pb) * 100.0 / max(t - pt, 1))
    prev[0] = cur
    total, avail = mem_info()[:2]
    mem = (total - avail) * 100.0 / total if total else 0.0
    seen = {}
    apps = []
    if popup_open():
        # One entry per history key (first RSS, union of pids), so each
        # series gets exactly one sample per tick.
        groups = {}

        def add(key, rss_mb, pids):
            if key in groups:
                groups[key][1].update(pids)
            else:
                groups[key] = [rss_mb, set(pids)]

        by_pid = windows_by_pid(monitors())
        for pid in by_pid:
            if comm(pid) in EXCLUDE_COMMS:
                continue
            family = comm_family(pid)
            scopes = family_scopes(family)
            key = scopes[0][1] if scopes else "pid%d" % pid
            add(key, sum(rss_kb(p) for p in family) / 1024.0, family)
        # Every background group gets its own series, keyed "bg:<comm>" (its
        # biggest pid can change between ticks, the name doesn't). Helpers
        # that share a windowed app's scope (a browser's "Isolated Web Co")
        # also count toward that app's row, so the row shows the whole app.
        for bg in collect_background(by_pid, marker_pids()):
            family = comm_family(bg["pid"])
            if bg["unit"] and bg["unit"] in groups:
                add(bg["unit"], 0.0, family)
            add("bg:" + bg["name"], float(bg["rss_mb"]), family)
        # System daemons: CPU summed over the group's pids (/proc/<pid>/stat
        # is world-readable, nothing is signalled).
        for row, pids in system_groups(by_pid):
            add("sys:" + row["name"], float(row["rss_mb"]), pids)
        # CPU per group = sum of per-pid jiffy deltas since the last tick. A
        # pid first seen this tick adds 0: summing raw totals instead counted
        # a new child's whole lifetime as one tick (false spikes).
        for key, (rss_mb, pids) in groups.items():
            d = 0
            for p in pids:
                j = proc_jiffies(p)
                seen[p] = j
                if p in prev_apps:
                    d += max(j - prev_apps[p], 0)
            # dt spans every core, so d/dt is the share of the whole machine;
            # times ncores gives % of one core, like top (100% = a full core).
            apps.append((key, rss_mb, d * ncores * 100.0 / dt))
        apps.sort(key=lambda a: -a[1])
        apps = apps[:72]
    prev_apps.clear()
    prev_apps.update(seen)
    hist.push(cpu, mem, cores, apps)
    hist.write()


def release_everything():
    n = governor_release()
    pids, scopes = marker_read()
    for cg in scopes:
        cg_write(cg, "memory.high", "max")
        cg_write(cg, "cgroup.freeze", "0")
    for p, s in pids:
        signal_pid(p, s, signal.SIGCONT)
    marker_write([], [])
    sys.stderr.write("task-manager watch: released %d limit(s), thawed %d scope(s) and %d process(es)\n"
                     % (n, len(scopes), len(pids)))


def cmd_watch(lifeline):
    rt = runtime()
    if not rt:
        sys.exit(1)
    try:
        lock = rt.try_lock("watch.lock")
    except OSError as e:
        warn("watch: lock: %s" % e)
        sys.exit(1)
    if lock is None:
        print("busy")
        return
    # Restores limits a previous run (either engine) may have left.
    gov = Governor()
    stopping = [False]
    signal.signal(signal.SIGTERM, lambda *_: stopping.__setitem__(0, True))

    def nap(secs):
        end = time.monotonic() + secs
        while not stopping[0]:
            left = end - time.monotonic()
            if left <= 0:
                return
            if not lifeline:
                time.sleep(left)
                continue
            try:
                r = select.select([0], [], [], left)[0]
                if r and not os.read(0, 256):
                    stopping[0] = True
            except (OSError, InterruptedError):
                pass

    hits = frozen_episode = tick = 0
    no_candidates = False
    last_frozen = {}
    auto_paused = []
    recovery = Recovery()
    hist, prev, prev_apps = Hist(), [cpu_times()], {}
    prev_cpu = cpu_times()
    crit_avail = cpu_max = 0.0
    while True:
        if stopping[0]:
            release_everything()
            return
        memo_reset()
        if tick % 4 == 0:
            # Thresholds are prefs: re-read every 2 s, not every tick.
            crit_avail, cpu_max = crit_avail_pct(), crit_cpu_pct()
        total, avail, some, full = mem_info()[:4]
        pct, crit = pressure(total, avail, full, crit_avail)
        # Governor every 2 s: squeeze background work early so the freeze
        # below stays a last resort.
        if tick % 4 == 0:
            gov.tick(pct, some)
        cpu_now = 0.0
        if cpu_max > 0:
            cur = cpu_times()
            cpu_now = (cur[0] - prev_cpu[0]) * 100.0 / max(cur[1] - prev_cpu[1], 1)
            prev_cpu = cur
            crit = crit or cpu_now >= cpu_max
        if crit:
            hits += 1
        else:
            hits, no_candidates = 0, False
            if pct > _env_num("TM_RECOVER_AVAIL_PCT", 12.0):
                frozen_episode = 0
        auto_paused = [p for p in auto_paused if p.prune()]
        healthy = recovery_healthy(total, pct, some, full, cpu_now, cpu_max,
                                   crit_avail, _env_num("TM_RECOVER_AVAIL_PCT", 12.0))
        if recovery.ready(time.monotonic(), healthy and bool(auto_paused)):
            paused = auto_paused[0]
            # Even a partial resume must remain freezable in an emergency.
            last_frozen.pop(paused.name, None)
            if paused.resume():
                auto_paused.pop(0)
                sys.stderr.write("watch: resources stable — resumed %s\n" % paused.name)
        if hits >= 10 and frozen_episode < _env_num("TM_MAX_FREEZE", 3) and not no_candidates:
            now = time.monotonic()
            skip = {n for n, t in last_frozen.items() if now - t < 600}
            got = freeze_biggest(skip)
            hits = 0
            if got:
                sys.stderr.write("watch: pressure critical (%.1f%% avail, psi_full %.1f) — froze %s (%d MB)\n"
                                 % (pct, full, got.name, got.mb))
                last_frozen[got.name] = now
                auto_paused.append(got)
                frozen_episode += 1
                tick += 1
                nap(2.0)
                continue
            sys.stderr.write("watch: pressure critical but no candidates left\n")
            no_candidates = True
        tick += 1
        if tick % 4 == 0:
            sample_history(hist, prev, prev_apps)
            reap()
        nap(0.5)


# ---------- shell reset ----------

DETACHED_ENV = "TASK_MANAGER_SHELL_RESET_DETACHED"


def cmdline(pid):
    b = read_kernel("/proc/%d/cmdline" % pid, CAP_CMDLINE) or b""
    return [a.decode("utf-8", "replace") for a in b.split(b"\0") if a]


def base(s):
    return s.rsplit("/", 1)[-1]


def ppid_state(pid):
    f = _stat_fields(pid)
    try:
        return int(f[1]), f[0][:1]
    except (TypeError, IndexError, ValueError):
        return None


def alive(pid):
    r = ppid_state(pid)
    return bool(r) and r[1] not in ("Z", "X")


def cgroup_text(pid):
    return read_trim("/proc/%d/cgroup" % pid) or ""


def own_pids():
    memo_reset()
    return [p for p, u in all_pids() if u == UID]


def canon(p):
    try:
        return os.path.realpath(p)
    except (OSError, ValueError):
        return p


def session_omarchy_path():
    for pid in own_pids():
        if any(base(a) == "omarchy-launch-shell" for a in cmdline(pid)[:2]):
            env = read_kernel("/proc/%d/environ" % pid, CAP_CMDLINE) or b""
            for kv in env.split(b"\0"):
                if kv.startswith(b"OMARCHY_PATH=/"):
                    return kv[13:].decode("utf-8", "replace")
    p = os.environ.get("OMARCHY_PATH", "")
    return p if p.startswith("/") else "/usr/share/omarchy"


def is_quickshell(pid, argv):
    if base(argv[0]) in ("quickshell", "qs"):
        return True
    try:
        return base(os.readlink("/proc/%d/exe" % pid)) in ("quickshell", "qs")
    except OSError:
        return False


def is_instance(argv):
    return len(argv) < 2 or argv[1].startswith("-")


def is_normal_reset(argv):
    """Another `task-manager shell-reset` worker (normal mode), either engine."""
    return (len(argv) >= 2 and argv[-1] == "shell-reset"
            and any(base(a).startswith(("task-manager", "task_manager")) for a in argv[:-1]))


def ancestors(me):
    outp, p = [], me
    while True:
        r = ppid_state(p)
        if not r or r[0] <= 1 or r[0] in outp or len(outp) > 64:
            return outp
        outp.append(r[0])
        p = r[0]


def targets():
    mine = ancestors(SELF)
    config = canon(session_omarchy_path() + "/shell")
    pids = own_pids()
    supervisors, shells, instances, children = [], [], [], {}
    for pid in pids:
        r = ppid_state(pid)
        if r:
            children.setdefault(r[0], []).append(pid)
        if pid in mine:
            continue
        argv = cmdline(pid)
        if not argv:
            continue
        if is_quickshell(pid, argv):
            if any(canon(a) == config or os.path.dirname(canon(a)) == config for a in argv[1:]):
                shells.append(pid)
                if is_instance(argv):
                    instances.append(pid)
        elif (any(base(a) in ("omarchy-launch-shell", "omarchy-restart-shell") for a in argv[:2])
              or is_normal_reset(argv)):
            supervisors.append(pid)
    helpers = []
    for sh in instances:
        cg = cgroup_text(sh)
        stack = list(children.get(sh, []))
        while stack:
            p = stack.pop()
            if p == SELF or p in mine or p in shells or p in helpers:
                continue
            if cgroup_text(p) == cg:
                helpers.append(p)
                stack.extend(children.get(p, []))
    return supervisors, shells, helpers


def cmd_shell_reset_list():
    for role, pids in zip(("supervisor", "shell", "helper"), targets()):
        for p in pids:
            print("%s\t%d\t%s" % (role, p, " ".join(cap_str(a) for a in cmdline(p))))


def sigkill(pids):
    for p in pids:
        fd = pin(p)
        if fd and alive(p):
            fd.signal(signal.SIGCONT)
            fd.signal(signal.SIGKILL)


def force_kill():
    total = 0
    for _ in range(2):
        sup, sh, hel = targets()
        allp = sup + sh + hel
        if not allp:
            break
        sigkill(sup)
        sigkill(sh)
        sigkill(hel)
        total += len(allp)
        deadline = time.monotonic() + 3
        while any(alive(p) for p in allp) and time.monotonic() < deadline:
            time.sleep(0.05)
    return total


def run_bounded(argv, secs):
    import subprocess
    try:
        p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, close_fds=True)
    except OSError:
        return False
    try:
        return p.wait(secs) == 0
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        return False


def cmd_shell_reset(force):
    if DETACHED_ENV not in os.environ:
        import subprocess
        env = dict(os.environ, **{DETACHED_ENV: "1"})
        launcher = os.path.join(os.path.dirname(os.path.abspath(__file__)), "task-manager-light.sh")
        argv = [launcher, "shell-reset"]
        try:
            subprocess.Popen(argv + (["force"] if force else []), env=env, start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, close_fds=True)
            return
        except OSError:
            warn("shell-reset: could not detach; running inline")
    rt = runtime()
    try:
        lock = rt.try_lock("shell-reset-force.lock" if force else "shell-reset.lock") if rt else -1
    except OSError:
        lock = -1
    if lock is None:
        warn("shell-reset: already running")
        return
    if lock < 0:
        sys.exit(1)
    if force:
        warn("shell-reset: killed %d processes" % force_kill())
    if run_bounded(["omarchy-restart-shell"], 90):
        return
    if any(is_instance(cmdline(p)) for p in targets()[1]):
        return
    hypr_dispatch('hl.dsp.exec_cmd("omarchy-launch-shell")')


# ---------- main ----------

def usage():
    warn("usage: task-manager <state|freeze T|thaw T|focus T|kill T|freeze-pid T|thaw-pid T|"
         "kill-pid T|procs T|governor-release|pref K V|popup [0|1]|binds|veil-lock|"
         "shell-reset [force|list]|history|watch [--lifeline]|follow>  (T = PID or PID:START)")
    sys.exit(1)


def main(args):
    if not args:
        usage()

    def one():
        if len(args) != 2:
            usage()
        t = parse_target(args[1])
        if t is None:
            usage()
        return t

    cmd = args[0]
    targeted = {
        "freeze": lambda t: (verify(t), freeze_family(t[0])),
        "thaw": lambda t: (verify(t), thaw_family(t[0])),
        "focus": cmd_focus, "kill": cmd_kill, "freeze-pid": cmd_freeze_pid,
        "thaw-pid": cmd_thaw_pid, "kill-pid": cmd_kill_pid, "procs": cmd_procs,
    }
    if cmd == "state" and args[1:] in ([], ["--brief"]):
        cmd_state(args[1:] == ["--brief"])
    elif cmd in targeted:
        targeted[cmd](one())
    elif cmd == "governor-release":
        print("released %d" % governor_release())
    elif cmd == "governor-explain":
        cmd_governor_explain()
    elif cmd == "watch" and len(args) <= 2 and args[1:] in ([], ["--lifeline"]):
        cmd_watch(args[1:] == ["--lifeline"])
    elif cmd == "follow":
        cmd_follow()
    elif cmd == "veil-lock":
        cmd_veil_lock()
    elif cmd == "popup" and len(args) <= 2:
        cmd_popup(args[1] if len(args) == 2 else None)
    elif cmd == "binds":
        cmd_binds()
    elif cmd == "history":
        cmd_history()
    elif cmd == "pref" and len(args) == 3:
        cmd_pref(args[1], args[2])
    elif cmd == "shell-reset" and args[1:] in ([], ["force"], ["list"]):
        if args[1:] == ["list"]:
            cmd_shell_reset_list()
        else:
            cmd_shell_reset(args[1:] == ["force"])
    else:
        usage()


def run():
    # Same process name as the Rust engine: excluded from every list, and
    # recognisable in ps/top.
    write_kernel("/proc/self/comm", "task-manager")
    try:
        main(sys.argv[1:])
        sys.stdout.flush()
    except BrokenPipeError:
        sys.exit(0)
