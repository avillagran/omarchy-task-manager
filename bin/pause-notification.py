"""Notification lifetime belongs to the engine's stdin pipe, never a PID file.

All external calls are bounded. EOF closes exactly the ID returned by Notify,
including when the watchdog exits. Rendering is optional; missing tools/icons
fall back to a fixed pause icon and the explicit paused summary.
"""
import configparser
import os
import resource
import select
import signal
import time
import stat
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def limit_image():
    os.umask(0o077)
    for kind, ceiling in [(resource.RLIMIT_AS, 256 * 1024 * 1024),
                          (resource.RLIMIT_FSIZE, 4 * 1024 * 1024), (resource.RLIMIT_CPU, 2)]:
        _, hard = resource.getrlimit(kind)
        if hard != resource.RLIM_INFINITY:
            ceiling = min(ceiling, hard)
        resource.setrlimit(kind, (ceiling, ceiling))


def run(args, timeout=2):
    child = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True,
                             preexec_fn=limit_image if args[0] == "magick" else None)
    deadline = time.monotonic() + timeout
    output = bytearray()
    try:
        while True:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([child.stdout], [], [], left)[0]:
                raise subprocess.TimeoutExpired(args, timeout)
            chunk = os.read(child.stdout.fileno(), min(4096, 4097 - len(output)))
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > 4096:
                raise OSError("notification helper output exceeds limit")
        child.wait(timeout=max(.001, deadline - time.monotonic()))
        if child.returncode:
            raise subprocess.CalledProcessError(child.returncode, args)
        return bytes(output)
    except BaseException:
        # Include ImageMagick delegates and any descendant holding a pipe.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        raise
    finally:
        child.stdout.close()


def desktop_text(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.getuid()):
            raise ValueError("not a trusted regular desktop file")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(65537)
        if len(data) > 65536:
            raise ValueError("desktop file too large")
        return data.decode("utf-8")
    finally:
        os.close(fd)


def app_icon(name):
    safe = re.sub(r'[^a-zA-Z0-9._-]', '', name)[:128]
    aliases = {'chrome': 'google-chrome', 'chromium-browser': 'chromium'}
    icon = aliases.get(safe, safe) or 'application-x-executable'
    roots = [Path.home() / '.local/share', Path('/usr/local/share'), Path('/usr/share')]
    for root in roots:
        for desktop in [icon, safe]:
            p = root / 'applications' / (desktop + '.desktop')
            try:
                c = configparser.ConfigParser(interpolation=None)
                c.read_string(desktop_text(p))
                value = c.get('Desktop Entry', 'Icon', fallback='')
                if re.fullmatch(r'[a-zA-Z0-9._-]{1,128}', value):
                    icon = value
            except (OSError, ValueError, configparser.Error):
                pass
    for root in roots:
        for theme in ['hicolor', 'Yaru', 'Adwaita', 'breeze']:
            for size in ['128x128', '64x64', '48x48', 'scalable']:
                for ext in ['png', 'svg', 'xpm']:
                    p = root / 'icons' / theme / size / 'apps' / (icon + '.' + ext)
                    if p.is_file():
                        return icon, p
        for ext in ['png', 'svg', 'xpm']:
            p = root / 'pixmaps' / (icon + '.' + ext)
            if p.is_file():
                return icon, p
    return icon, None


def serve(name, title, body, stream):
    notification = None
    # Private, unpredictable directory; files survive until CloseNotification.
    with tempfile.TemporaryDirectory(prefix='task-manager-notice-') as directory:
        _, source = app_icon(name)
        icon = "media-playback-pause"
        if source:
            try:
                if source.stat().st_size <= 2 * 1024 * 1024:
                    image = Path(directory) / 'paused.png'
                    # App artwork plus a visible pause badge, rendered locally.
                    run(['magick', '-limit', 'memory', '32MiB', '-limit', 'map', '32MiB',
                         '-limit', 'disk', '32MiB', '-limit', 'thread', '1',
                         '-background', 'none', str(source), '-resize', '96x96',
                         '-gravity', 'center', '-extent', '96x96',
                         '-fill', '#e0af68', '-stroke', '#1a1b26', '-strokewidth', '2',
                         '-draw', 'roundrectangle 48,48 94,94 10,10',
                         '-fill', '#1a1b26', '-stroke', 'none',
                         '-draw', 'rectangle 61,59 67,83 rectangle 76,59 82,83', '-strip', str(image)])
                    icon = str(image)
            except (OSError, subprocess.SubprocessError):
                pass
        try:
            args = ['notify-send', '--print-id', '-a', 'Task Manager', '-u', 'critical', '-i', icon]
            # Quickshell turns file icons into process-local image:// URLs.
            # The local notification service uses this optional hint to copy
            # the original before persisting a toast across a shell reload.
            if icon.startswith('/'):
                args += ['-h', 'string:x-omarchy-app-icon-path:' + icon]
            reply = run(args + ['--', title[:256], body[:1024]])
            if re.fullmatch(rb'[0-9]{1,10}\s*', reply) and 0 < int(reply) <= 0xffffffff:
                notification = str(int(reply))
            stream.read(1)  # Owner closes stdin only after all owned stops clear.
        except (OSError, subprocess.SubprocessError):
            pass
        finally:
            if notification:
                try:
                    run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.Notifications',
                         '--object-path', '/org/freedesktop/Notifications', '--method',
                         'org.freedesktop.Notifications.CloseNotification', notification])
                except (OSError, subprocess.SubprocessError):
                    pass


if __name__ == '__main__' and len(sys.argv) == 4:
    serve(*sys.argv[1:], sys.stdin.buffer)
