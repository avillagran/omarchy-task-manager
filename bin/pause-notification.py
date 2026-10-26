"""Notification lifetime belongs to the engine's stdin pipe, never a PID file.

All external calls are bounded. EOF closes exactly the ID returned by Notify,
including when the watchdog exits. Rendering is optional; missing tools/icons
fall back to a themed icon and the explicit paused summary.
"""
import configparser
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def run(args, timeout=2):
    return subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, timeout=timeout, check=True).stdout


def app_icon(name):
    safe = re.sub(r'[^a-zA-Z0-9._-]', '', name)[:128]
    aliases = {'chrome': 'google-chrome', 'chromium-browser': 'chromium'}
    icon = aliases.get(safe, safe) or 'application-x-executable'
    roots = [Path.home() / '.local/share', Path('/usr/local/share'), Path('/usr/share')]
    for root in roots:
        for desktop in [icon, safe]:
            p = root / 'applications' / (desktop + '.desktop')
            try:
                if p.stat().st_size > 65536:
                    continue
                c = configparser.ConfigParser(interpolation=None)
                c.read_string(p.read_text())
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
        icon, source = app_icon(name)
        if source:
            try:
                if source.stat().st_size <= 2 * 1024 * 1024:
                    image = Path(directory) / 'paused.png'
                    # App artwork plus a visible pause badge, rendered locally.
                    run(['magick', '-limit', 'memory', '32MiB', '-limit', 'map', '32MiB',
                         '-background', 'none', str(source), '-resize', '96x96',
                         '-gravity', 'center', '-extent', '96x96',
                         '-fill', '#e0af68', '-stroke', '#1a1b26', '-strokewidth', '2',
                         '-draw', 'roundrectangle 48,48 94,94 10,10',
                         '-fill', '#1a1b26', '-stroke', 'none',
                         '-draw', 'rectangle 61,59 67,83 rectangle 76,59 82,83', str(image)])
                    icon = str(image)
            except (OSError, subprocess.SubprocessError):
                pass
        try:
            reply = run(['notify-send', '--print-id', '-a', 'Task Manager', '-u', 'critical',
                         '-i', icon, '--', title[:256], body[:1024]])
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
