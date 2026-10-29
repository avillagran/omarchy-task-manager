"""Real concurrent preference writers in isolated state; no desktop changes."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
identity = hashlib.sha256(os.fsencode(str((ROOT/'bin').resolve()))).hexdigest()[:32]
RUST = Path(os.environ.get('XDG_CACHE_HOME',str(Path.home()/'.cache'))) / 'omarchy-task-manager/rust' / identity / 'release/task-manager'


class PreferenceConcurrency(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        base=Path(self.temp.name);self.state=base/'state/omarchy-task-manager'
        self.state.mkdir(parents=True,mode=0o700)
        self.env=dict(os.environ,XDG_STATE_HOME=str(base/'state'),XDG_CACHE_HOME=str(base/'cache'))
        self.writers=[[str(ROOT/'bin/task-manager-light.sh')]]
        if RUST.is_file():self.writers.append([str(RUST)])

    def spawn(self,key,value,index):
        return subprocess.Popen(self.writers[index%len(self.writers)]+['pref',key,value],env=self.env,
                                stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)

    def finish(self,children):
        for child in children:
            _,err=child.communicate(timeout=5)
            self.assertEqual(child.returncode,0,err)
        return json.loads((self.state/'prefs.json').read_text())

    def test_shared_lock_blocks_entire_read_modify_write(self):
        lock=os.open(self.state/'prefs.lock',os.O_CREAT|os.O_RDWR,0o600)
        fcntl.flock(lock,fcntl.LOCK_EX)
        children=[self.spawn('cardW','560',0),self.spawn('cardH','640',1)]
        try:
            time.sleep(.15)
            self.assertFalse((self.state/'prefs.json').exists())
            self.assertTrue(all(c.poll() is None for c in children))
        finally:
            os.close(lock)
            result=self.finish(children)
        self.assertEqual((result['cardW'],result['cardH']),('560','640'))

    def test_concurrent_updates_preserve_every_setting(self):
        values={'cardW':'720','cardH':'680','barMode':'numbers','sortBy':'cpu',
                'engine':'auto','watchdog':'1','watchMaxRam':'92','watchMaxCpu':'80'}
        result=self.finish([self.spawn(k,v,i) for i,(k,v) in enumerate(values.items())])
        for k in values:self.assertIn(k,result)
        self.assertEqual(result['cardW'],'720');self.assertEqual(result['cardH'],'680')

    def test_symlink_lock_is_refused_without_touching_target(self):
        target=Path(self.temp.name)/'untouched';target.write_text('keep')
        (self.state/'prefs.lock').symlink_to(target)
        children=[self.spawn('cardW','560',i) for i in range(len(self.writers))]
        for c in children:c.communicate(timeout=5)
        self.assertFalse((self.state/'prefs.json').exists())
        self.assertEqual(target.read_text(),'keep')


if __name__=='__main__':unittest.main()
