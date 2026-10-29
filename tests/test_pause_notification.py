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
        self.assertEqual(calls[0][calls[0].index('-i') + 1], 'media-playback-pause')
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
            source = ROOT / 'preview.png'
        actual_run = n.run
        def run(args):
            if args[0] == 'magick':
                self.assertIn('-strip', args)
                return actual_run(args)
            if args[0] == 'notify-send':
                image = Path(args[args.index('-i') + 1])
                self.assertTrue(image.is_file())
                self.assertIn('string:x-omarchy-app-icon-path:' + str(image), args)
                self.assertEqual(image.parent.stat().st_mode & 0o777, 0o700)
                self.assertEqual(image.stat().st_mode & 0o777, 0o600)
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

    def test_desktop_metadata_reads_are_bounded_and_reject_special_files(self):
        import os
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'app.desktop'
            path.write_text('[Desktop Entry]\nIcon=google-chrome\n')
            self.assertIn('google-chrome', n.desktop_text(path))
            path.write_bytes(b'x'*65537)
            with self.assertRaises(ValueError):n.desktop_text(path)
            path.unlink();os.mkfifo(path)
            with self.assertRaises(ValueError):n.desktop_text(path)
            path.unlink();path.symlink_to(Path(directory)/'elsewhere')
            with self.assertRaises(OSError):n.desktop_text(path)

    def test_external_output_is_capped_before_collection(self):
        import sys
        with self.assertRaises(OSError):
            n.run([sys.executable,'-c','print("x"*1000000)'])

    def test_timeout_kills_delegate_process_group(self):
        import os
        import sys
        import signal
        with tempfile.TemporaryDirectory() as directory:
            pidfile=Path(directory)/'child'
            code='import subprocess,sys,time; from pathlib import Path; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(120)"]); Path(sys.argv[1]).write_text(str(p.pid)); time.sleep(120)'
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    n.run([sys.executable,'-c',code,str(pidfile)], timeout=.3)
                if pidfile.exists():
                    pid=int(pidfile.read_text()); status=Path('/proc')/str(pid)/'stat'
                    if status.exists():
                        self.assertEqual(status.read_text().split()[2],'Z')
            finally:
                if pidfile.exists():
                    try:os.kill(int(pidfile.read_text()),signal.SIGKILL)
                    except ProcessLookupError:pass

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
