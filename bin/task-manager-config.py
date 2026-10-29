#!/usr/bin/env python3
"""Opt-in Hyprland snippets. Preserve unrelated bytes and retain modules on failure."""
import os
import stat
import sys
import tempfile
from pathlib import Path

CAP = 262144
MODULES = {"task-manager-bindings", "task-manager-reset-bindings", "task-manager-veil"}
HEADER = b"-- Added by the Task Manager plugin (bin/task-manager-configure.sh) at your request."


def read_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():
            raise ValueError('not an owned regular file')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            data = stream.read(CAP + 1)
        if len(data) > CAP:
            raise ValueError('config exceeds read limit')
        return data, stat.S_IMODE(st.st_mode)
    finally:
        os.close(fd)


def rewritten(data, enabled, name):
    OLD = ('require("' + name + '")').encode()
    NEW = ('require("hypr.' + name + '")').encode()
    out = []
    inserted = False
    for line in data.splitlines(keepends=True):
        if line.rstrip(b'\r\n') in (OLD, NEW):
            if enabled and not inserted:
                ending = b'\r\n' if line.endswith(b'\r\n') else b'\n'
                out.append(NEW + ending)
                inserted = True
        else:
            out.append(line)
    if enabled and not inserted:
        if data and not data.endswith(b'\n'):
            out.append(b'\n')
        out.append(NEW + b'\n')
    return b''.join(out)


def atomic_write(path, data, mode):
    fd, tmp = tempfile.mkstemp(prefix='.task-manager-write-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), mode)
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def update(action, name, directory, content):
    if action not in ("apply", "remove") or name not in MODULES:
        raise ValueError("unsupported operation")
    if len(content) > 16384 or not content.startswith(HEADER + b"\n"):
        raise ValueError("invalid generated content")
    directory = Path(directory)
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError("unsafe Hyprland directory")
    main = directory / "hyprland.lua"
    module = directory / (name + ".lua")
    original, mode = read_regular(main)
    existing = None
    try:
        existing, _ = read_regular(module)
        # Do not overwrite or delete a hand-written or edited module.
        if existing != content:
            raise ValueError("module differs from generated content")
    except FileNotFoundError:
        pass
    without_generated = rewritten(original, False, name)
    if name.encode() in without_generated:
        raise ValueError("edited reference remains; remove it manually first")
    target = rewritten(original, action == "apply", name)
    if action == "apply":
        atomic_write(module, content, 0o600)
    if target != original:
        fd, backup = tempfile.mkstemp(prefix=".task-manager-backup-", dir=directory)
        with os.fdopen(fd, "wb") as stream:
            stream.write(original)
            stream.flush()
            os.fsync(stream.fileno())
        atomic_write(main, target, mode)
        print("Backup: " + backup)
    if action == "remove":
        # Only after complete config read and successful reference removal.
        try:
            module.unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise ValueError("expected action, module name, config directory")
        update(*sys.argv[1:], sys.stdin.buffer.read(16385))
    except (OSError, ValueError):
        print("Task Manager: configuration update failed; module retained. Check access or edited content.", file=sys.stderr)
        sys.exit(1)
