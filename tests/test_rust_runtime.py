"""Clean-install build/launch regression: Cargo must never write to the plugin."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('runtime', ROOT / 'bin/task-manager-runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RustRuntime(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'plugins/task-manager'
        self.bin = self.source / 'bin'
        self.bin.mkdir(parents=True)
        for name in ['task-manager-runtime.py', 'task-manager-build.sh', 'task-manager-launch.sh']:
            shutil.copy2(ROOT / 'bin' / name, self.bin / name)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        (self.tools / "dirname").symlink_to("/usr/bin/dirname")
        cargo = self.tools / 'cargo'
        cargo.write_text('''#!/usr/bin/python3
import json, os, pathlib, sys
assert '--offline' in sys.argv and '--locked' in sys.argv
p = pathlib.Path(sys.argv[sys.argv.index('--target-dir') + 1]) / 'release/task-manager'
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text('#!/usr/bin/python3\\nimport json, os, sys\\nprint(json.dumps({"args":sys.argv[1:],"source":os.environ["TM_PLUGIN_BIN_DIR"]}))\\n')
p.chmod(0o700)
''')
        cargo.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.root / 'home'),
                        XDG_CACHE_HOME=str(self.root / 'cache'), PATH=str(self.tools))

    def call(self, action, *args, env=None):
        return subprocess.run(['/bin/sh', str(self.bin / ('task-manager-' + action + '.sh')), *args],
                              env=env or self.env, capture_output=True, text=True, timeout=5)

    def snapshot(self):
        return {str(p.relative_to(self.source)): (p.stat().st_mtime_ns, p.read_bytes())
                for p in self.source.rglob('*') if p.is_file()}

    def test_fresh_and_warm_builds_leave_plugin_untouched_and_launch_cached_engine(self):
        # A stale in-tree engine must neither be run nor modified.
        old = self.bin / 'task-manager-rs/target/release/task-manager'
        old.parent.mkdir(parents=True)
        old.write_text('stale engine')
        before = self.snapshot()
        for _ in range(2):
            result = self.call('build')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.snapshot(), before)
            result = self.call('launch', 'state', '--brief')
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(result.stdout)
            self.assertEqual(payload['args'], ['state', '--brief'])
            self.assertEqual(payload['source'], str(self.bin))
        outputs = list((self.root / 'cache').glob('omarchy-task-manager/rust/*'))
        self.assertEqual(len(outputs), 1)
        self.assertEqual(outputs[0].stat().st_mode & 0o777, 0o700)

    def test_missing_build_returns_127_without_using_old_target(self):
        result = self.call('launch', 'state')
        self.assertEqual(result.returncode, 127)
        self.assertIn('engine not built', result.stderr)

    def test_missing_cargo_preserves_python_fallback_exit(self):
        tools = self.root / 'no-cargo'
        tools.mkdir()
        (tools / 'dirname').symlink_to('/usr/bin/dirname')
        result = self.call('build', env=dict(self.env, PATH=str(tools)))
        self.assertEqual(result.returncode, 127)
        self.assertIn('cargo not found', result.stdout)

    def test_cache_inside_plugin_falls_back_outside_watched_source(self):
        before = self.snapshot()
        result = self.call('build', env=dict(self.env, XDG_CACHE_HOME=str(self.source / 'cache')))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertFalse((self.source / 'cache').exists())
        self.assertTrue(list((self.root / 'home/.cache').glob('omarchy-task-manager/rust/*/release/task-manager')))

    def test_cargo_target_override_cannot_redirect_output_into_plugin(self):
        before = self.snapshot()
        result = self.call('build', env=dict(self.env, CARGO_TARGET_DIR=str(self.source / 'target')))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.source / 'target').exists())
        self.assertEqual(self.snapshot(), before)

    def test_symlink_cache_is_refused(self):
        cache = self.root / 'cache'
        cache.mkdir()
        outside = self.root / 'outside'
        outside.mkdir()
        (cache / 'omarchy-task-manager').symlink_to(outside, target_is_directory=True)
        result = self.call('build')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])

    def test_copies_have_independent_output_directories(self):
        self.assertEqual(self.call('build').returncode, 0)
        other = self.root / 'other-plugin'
        shutil.copytree(self.source, other)
        result = subprocess.run(['/bin/sh', str(other / 'bin/task-manager-build.sh')], env=self.env,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list((self.root / 'cache/omarchy-task-manager/rust').iterdir())), 2)


if __name__ == '__main__':
    unittest.main()
