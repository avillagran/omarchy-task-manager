"""Optional Hyprland edits tested only in temporary configs, never the desktop."""
import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('cfg',ROOT/'bin/task-manager-config.py')
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)


class Snippets(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.main=self.root/'hyprland.lua'
        self.original=b'-- keep bytes\r\nlocal custom = 3\r\n-- tail without newline'
        self.main.write_bytes(self.original);self.main.chmod(0o640)
        self.name='task-manager-bindings'
        self.module=self.root/(self.name+'.lua')
        self.content=c.HEADER+b'\n-- generated body\n'

    def test_round_trip_preserves_bytes_and_modes_with_private_backups(self):
        c.update('apply',self.name,self.root,self.content)
        self.assertIn(b'require("hypr.task-manager-bindings")',self.main.read_bytes())
        self.assertEqual(stat.S_IMODE(self.main.stat().st_mode),0o640)
        self.assertEqual(stat.S_IMODE(self.module.stat().st_mode),0o600)
        backups=list(self.root.glob('.task-manager-backup-*'))
        self.assertTrue(backups)
        self.assertEqual(backups[0].read_bytes(),self.original)
        self.assertTrue(all(stat.S_IMODE(p.stat().st_mode)==0o600 for p in backups))
        c.update('remove',self.name,self.root,self.content)
        # Appending a require adds a separating newline; unrelated bytes stay exact.
        self.assertEqual(self.main.read_bytes(),self.original+b'\n')
        self.assertFalse(self.module.exists())

    def test_legacy_duplicate_lines_and_empty_output(self):
        for name in c.MODULES:
            data=('require("'+name+'")\nrequire("hypr.'+name+'")\n').encode()
            self.assertEqual(c.rewritten(data,True,name),('require("hypr.'+name+'")\n').encode())
            self.assertEqual(c.rewritten(data,False,name),b'')
        self.main.write_bytes(b'require("task-manager-bindings")\n')
        self.module.write_bytes(self.content)
        c.update('remove',self.name,self.root,self.content)
        self.assertEqual(self.main.read_bytes(),b'')
        self.assertFalse(self.module.exists())

    def test_read_or_replace_failure_retains_module_and_config(self):
        self.original += b'\nrequire("hypr.task-manager-bindings")\n'
        self.main.write_bytes(self.original)
        self.module.write_bytes(self.content)
        for failing in ['read_regular','atomic_write']:
            with patch.object(c,failing,side_effect=OSError('injected')):
                with self.assertRaises(OSError):c.update('remove',self.name,self.root,self.content)
            self.assertEqual(self.module.read_bytes(),self.content)
            self.assertEqual(self.main.read_bytes(),self.original)

    def test_missing_oversized_symlink_and_fifo_config_retain_module(self):
        self.module.write_bytes(self.content)
        for kind in ['missing','oversized','symlink','fifo']:
            self.main.unlink(missing_ok=True)
            if kind=='oversized':self.main.write_bytes(b'x'*(c.CAP+1))
            if kind=='symlink':self.main.symlink_to(self.module)
            if kind=='fifo':os.mkfifo(self.main)
            with self.assertRaises((OSError,ValueError)):c.update('remove',self.name,self.root,self.content)
            self.assertEqual(self.module.read_bytes(),self.content)

    def test_hand_edited_module_is_never_overwritten_or_deleted(self):
        self.module.write_bytes(self.content+b'-- personal edit\n')
        for action in ['apply','remove']:
            with self.assertRaises(ValueError):c.update(action,self.name,self.root,self.content)
            self.assertEqual(self.module.read_bytes(),self.content+b'-- personal edit\n')

    def test_modified_reference_keeps_module_and_main_unchanged(self):
        original=b'require("hypr.task-manager-bindings") -- personal comment\n'
        self.main.write_bytes(original);self.module.write_bytes(self.content)
        for action in ['apply','remove']:
            with self.assertRaises(ValueError):c.update(action,self.name,self.root,self.content)
            self.assertEqual(self.main.read_bytes(),original)
            self.assertEqual(self.module.read_bytes(),self.content)

    def test_real_shell_wrapper_all_three_snippets(self):
        config=self.root/'config/hypr';config.mkdir(parents=True)
        main=config/'hyprland.lua';main.write_bytes(self.original)
        tools=self.root/'tools';tools.mkdir()
        for cmd in ['gum','hyprctl']:
            p=tools/cmd;p.write_text('#!/bin/sh\nexit 0\n');p.chmod(0o700)
        env=dict(os.environ,XDG_CONFIG_HOME=str(self.root/'config'),PATH=str(tools)+':'+os.environ['PATH'])
        for snippet in ['show','reset','veil']:
            for action in ['apply','remove']:
                r=subprocess.run(['bash',str(ROOT/'bin/task-manager-configure.sh'),snippet,action],env=env,
                                 capture_output=True,text=True,timeout=4)
                self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(main.read_bytes(),self.original+b'\n')
        self.assertEqual(list(config.glob('task-manager-*.lua')),[])


if __name__=='__main__':unittest.main()
