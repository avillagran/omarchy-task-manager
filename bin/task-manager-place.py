"""Place the native panel inside the monitor work area, without config changes."""
import importlib.util
import json
import math
from pathlib import Path
import re
import sys

MARGIN = 24


def number(value, fallback=0):
    try:
        n = float(value)
        return n if math.isfinite(n) else fallback
    except (ValueError, TypeError):
        return fallback


def bounds(monitor, width, height):
    scale = max(.25, number(monitor.get('scale'), 1))
    mw, mh = number(monitor.get('width'), 1920), number(monitor.get('height'), 1080)
    if int(number(monitor.get('transform'))) % 2:
        mw, mh = mh, mw
    mw, mh = max(1, round(mw / scale)), max(1, round(mh / scale))
    reserved = monitor.get('reserved', [])
    if not isinstance(reserved, list) or len(reserved) != 4:
        reserved = [0, 0, 0, 0]
    left, top, right, bottom = [max(0, number(v)) for v in reserved]
    available_w = max(1, int(mw - left - right - 2 * MARGIN))
    available_h = max(1, int(mh - top - bottom - 2 * MARGIN))
    w = min(available_w, max(440, round(number(width, 560))))
    h = min(available_h, max(360, round(number(height, 640))))
    return {'x': round(number(monitor.get('x')) + left + MARGIN + (available_w - w) / 2),
            'y': round(number(monitor.get('y')) + top + MARGIN + (available_h - h) / 2),
            'w': w, 'h': h}


def choose_monitor(monitors, cursor, window):
    for m in monitors:
        scale = max(.25, number(m.get('scale'), 1))
        w, h = number(m.get('width')), number(m.get('height'))
        if int(number(m.get('transform'))) % 2:
            w, h = h, w
        if (number(m.get('x')) <= number(cursor.get('x'), -1e9) < number(m.get('x')) + w / scale
                and number(m.get('y')) <= number(cursor.get('y'), -1e9) < number(m.get('y')) + h / scale):
            return m
    return next((m for m in monitors if m.get('id') == window.get('monitor')), monitors[0])


def place(ipc, width, height):
    clients = ipc.hypr_query('clients') or []
    window = next((w for w in clients[:1024] if w.get('initialTitle') == 'Omarchy Task Manager'), None)
    monitors = (ipc.hypr_query('monitors') or [])[:64]
    if not window or not monitors or not ipc.valid_address(window.get('address')):
        return 75
    monitor = choose_monitor(monitors, ipc.hypr_query('cursorpos') or {}, window)
    name = monitor.get('name', '')
    if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,128}', name):
        return 75
    rect = bounds(monitor, width, height)
    # Let QML clamp its minimum size too, before the next bounded retry.
    print(json.dumps(rect), flush=True)
    selector = 'address:' + window['address']
    commands = [
        'hl.dsp.window.move({ monitor = "%s", window = "%s" })' % (name, selector),
        'hl.dsp.window.resize({ x = %d, y = %d, window = "%s" })' % (rect['w'], rect['h'], selector),
        'hl.dsp.window.move({ x = %d, y = %d, window = "%s" })' % (rect['x'], rect['y'], selector),
    ]
    if not window.get("floating"):
        commands.insert(0, 'hl.dsp.window.float({ action = "toggle", window = "%s" })' % selector)
    for cmd in commands:
        if not ipc.hypr_dispatch(cmd):
            return 75
    after = next((w for w in (ipc.hypr_query('clients') or [])[:1024]
                  if w.get('address') == window['address']), {})
    actual = after.get('at', []) + after.get('size', [])
    expected = [rect[k] for k in ['x', 'y', 'w', 'h']]
    return 0 if (after.get('floating') and len(actual) == 4
                 and all(abs(number(a, -1e9) - b) <= 4 for a, b in zip(actual, expected))) else 75


def main():
    if len(sys.argv) != 3:
        return 2
    # Reuse the engine's byte-capped/deadlined native IPC; no Cargo or source
    # writes. Explicitly prevent import bytecode inside the watched plugin.
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('tm_ipc', Path(__file__).with_name('task_manager_light.py'))
    ipc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ipc)
    ipc.HYPR_TIMEOUT = .5
    return place(ipc, sys.argv[1], sys.argv[2])


if __name__ == '__main__':
    sys.exit(main())
