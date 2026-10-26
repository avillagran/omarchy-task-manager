"""Notification protocol tests; never contact the desktop notification bus."""
import importlib.util
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('notice', ROOT / 'bin/pause-notification.py')
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)
spec = importlib.util.spec_from_file_location('engine', ROOT / 'bin/task_manager_light.py')
tm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tm)


class Notification(unittest.TestCase):
    def test_closes_exact_id_after_eof_and_keeps_icon_alive(self):
        calls = []
        class Stream:
            def read(self, *args):
                self_outer.assertEqual(len(calls), 1)
                return b''
        self_outer = self
        def run(args):
            calls.append(args)
            return b'42\n'
        with patch.object(n, 'app_icon', return_value=('google-chrome', None)), patch.object(n, 'run', side_effect=run):
            n.serve('chrome', 'Paused', 'stable', Stream())
        self.assertEqual(calls[0][calls[0].index('-i') + 1], 'google-chrome')
        self.assertEqual(calls[1][-2:], ['org.freedesktop.Notifications.CloseNotification', '42'])

    def test_bad_id_and_notify_failure_never_close_an_unrelated_notice(self):
        for reply in [b'', b'0\n', b'42 bad', b'4294967296', OSError()]:
            with patch.object(n, 'app_icon', return_value=('app', None)), patch.object(n, 'run', side_effect=[reply]) as run:
                n.serve('app', 'Paused', '', io.BytesIO())
                self.assertEqual(run.call_count, 1)

    def test_real_badge_render_is_private_and_has_pause_bars(self):
        # Use real renderer, but mock both D-Bus clients.
        source = Path('/usr/share/icons/hicolor/128x128/apps/google-chrome.png')
        if not source.exists():
            self.skipTest('Chrome icon not installed')
        actual_run = n.run
        def run(args):
            if args[0] == 'magick':
                return actual_run(args)
            if args[0] == 'notify-send':
                image = Path(args[args.index('-i') + 1])
                self.assertTrue(image.is_file())
                self.assertEqual(image.parent.stat().st_mode & 0o777, 0o700)
                pixel = actual_run(['magick', str(image), '-format', '%[pixel:p{64,70}]', 'info:'])
                self.assertIn(b'26,27,38', pixel.replace(b' ', b''))
                return b'123\n'
            return b''
        with patch.object(n, 'app_icon', return_value=('google-chrome', source)), patch.object(n, 'run', side_effect=run):
            n.serve('chrome', 'Paused', '', io.BytesIO())

    def test_real_helper_lives_until_owner_closes_pipe(self):
        import os
        import sys
        import time
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            for executable, text in {
                'notify-send': '#!/bin/sh\nprintf "issued" > "$NOTICE_LOG"\nprintf "789\\n"\n',
                'gdbus': '#!/bin/sh\nprintf "%s" "$*" > "$NOTICE_LOG"\n',
            }.items():
                file = path / executable
                file.write_text(text)
                file.chmod(0o700)
            log = path / 'calls'
            env = dict(os.environ, PATH=directory, NOTICE_LOG=str(log))
            child = subprocess.Popen([sys.executable, '-I', '-S', str(ROOT / 'bin/pause-notification.py'),
                                      'nonexistent-test-app', 'Paused', 'Waiting'],
                                     stdin=subprocess.PIPE, env=env)
            try:
                deadline = time.monotonic() + 3
                while not log.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertEqual(log.read_text(), 'issued')
                self.assertIsNone(child.poll())
                child.stdin.close()
                self.assertEqual(child.wait(timeout=3), 0)
                self.assertIn('CloseNotification 789', log.read_text())
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()

    def test_partial_resume_retains_notice_until_final_stop_clears(self):
        paused = tm.AutoPause('app', 100, ([], []), ([(12, 1)], []))
        paused.notification = unittest.mock.Mock()
        process = paused.notification
        with patch.object(tm, 'signal_pid', return_value=False):
            self.assertFalse(paused.resume())
            process.stdin.close.assert_not_called()
        with patch.object(tm, 'signal_pid', return_value=True), patch.object(tm, 'marker_remove'):
            self.assertTrue(paused.resume())
            process.stdin.close.assert_called_once()
        tm._children.clear()

    def test_manual_resume_prune_closes_notice(self):
        paused = tm.AutoPause('app', 100, ([], []), ([(12, 1)], []))
        paused.notification = unittest.mock.Mock()
        process = paused.notification
        with patch.object(tm, 'marker_read', return_value=([], [])):
            self.assertFalse(paused.prune())
        process.stdin.close.assert_called_once()
        tm._children.clear()


if __name__ == '__main__':
    unittest.main()
