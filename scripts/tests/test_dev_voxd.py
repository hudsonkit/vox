import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT=Path(__file__).resolve().parents[1]/'dev-voxd.py'

class DevHostTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.home=Path(self.temp.name)
        self.env=dict(os.environ,HOME=str(self.home),VOX_AUTH_TOKEN='must-not-inherit',VOX_HOME='/must-not-use')
        self.bins=self.home/'build';self.bins.mkdir();self.models=self.home/'models';self.models.mkdir()
        (self.models/'keep').write_text('existing-model')
        fixture='#!'+sys.executable+'\n'+'''import os,json,signal,time
from pathlib import Path
p=Path(os.environ['VOX_RUNTIME_PATH']);s=Path(os.environ['VOX_SOCKET_PATH'])
s.touch()
Path(os.environ['VOX_HOME'],'env.json').write_text(json.dumps({k:v for k,v in os.environ.items() if k.startswith('VOX_')}))
t=p.with_suffix('.new');t.write_text(json.dumps({'pid':os.getpid(),'authToken':'fixture-only'}));t.chmod(0o600);t.replace(p)
stop=False
def end(*_):
 global stop
 stop=True
signal.signal(signal.SIGTERM,end)
while not stop:time.sleep(.01)
p.unlink();s.unlink()
'''
        for name in ['voxd','voxttsd']:
            p=self.bins/name;p.write_text(fixture);p.chmod(0o700)
        bundle=self.bins/'HudsonSpeechEngine_HudsonSpeechEngine.bundle';bundle.mkdir();(bundle/'models.json').write_text('{}')
        self.process=None
    def tearDown(self):
        if self.process and self.process.poll() is None:
            self.process.terminate();self.process.wait(timeout=5)
        self.temp.cleanup()
    def call(self,*args,ok=True):
        p=subprocess.run([sys.executable,str(SCRIPT),*args],env=self.env,capture_output=True,text=True,timeout=5)
        self.assertEqual(p.returncode==0,ok,p.stderr)
        return p
    def install(self):self.call('install','test','--bin-dir',str(self.bins),'--models-path',str(self.models.resolve()))
    def start(self):
        self.process=subprocess.Popen([sys.executable,str(SCRIPT),'run','test'],env=self.env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        deadline=time.monotonic()+5
        while not (self.home/'.vox-dev/test/runtime.json').exists():
            self.assertIsNone(self.process.poll());self.assertLess(time.monotonic(),deadline);time.sleep(.02)
    def test_install_run_stop_remove_preserves_installed_and_models(self):
        old=self.home/'.vox';old.mkdir();(old/'runtime.json').write_text('installed-marker')
        self.install();self.start()
        root=self.home/'.vox-dev/test'
        env=json.loads((root/'home/env.json').read_text())
        self.assertNotIn('VOX_AUTH_TOKEN',env)
        self.assertEqual(env['VOX_MODELS_PATH'],str(self.models.resolve()))
        self.assertEqual(env['VOX_RUNTIME_PATH'],str(root/'runtime.json'))
        status=self.call('status','test').stdout
        self.assertTrue(json.loads(status)['running']);self.assertNotIn('fixture-only',status)
        self.call('remove','test',ok=False)
        self.call('run','test',ok=False)
        self.call('stop','test');self.process.wait(timeout=5)
        self.assertFalse((root/'runtime.json').exists())
        self.call('remove','test')
        self.assertFalse(root.exists());self.assertEqual((self.models/'keep').read_text(),'existing-model')
        self.assertEqual((old/'runtime.json').read_text(),'installed-marker')
    def test_reject_missing_resources_before_creating_install(self):
        (self.bins/'HudsonSpeechEngine_HudsonSpeechEngine.bundle/models.json').unlink()
        self.call('install','test','--bin-dir',str(self.bins),'--models-path',str(self.models),ok=False)
        self.assertFalse((self.home/'.vox-dev/test').exists())
    def test_reject_changed_resources(self):
        self.install();(self.home/'.vox-dev/test/bin/HudsonSpeechEngine_HudsonSpeechEngine.bundle/models.json').write_text('changed')
        self.call('run','test',ok=False)
    def test_reject_existing_installation(self):
        self.install();self.call('install','test','--bin-dir',str(self.bins),'--models-path',str(self.models),ok=False)
    def test_reject_path_traversal_name(self):self.call('install','../bad',ok=False)
    def test_reject_symlink_root(self):
        base=self.home/'.vox-dev';base.mkdir(mode=0o700);(base/'test').symlink_to(self.models,target_is_directory=True)
        self.call('remove','test',ok=False);self.assertTrue((self.models/'keep').exists())
    def test_reject_public_base_directory(self):
        (self.home/'.vox-dev').mkdir(mode=0o755)
        self.call('install','test','--bin-dir',str(self.bins),'--models-path',str(self.models),ok=False)
    def test_reject_changed_binary(self):
        self.install();(self.home/'.vox-dev/test/bin/voxd').write_text('changed')
        self.call('run','test',ok=False)
    def test_refuse_stale_supervisor_pid(self):
        self.install();p=self.home/'.vox-dev/test/process.json'
        p.write_text(json.dumps(dict(supervisorPID=999999,supervisorIdentity='stale')));p.chmod(0o600)
        self.call('stop','test',ok=False)
    def test_refuse_remove_existing_capability(self):
        self.install();(self.home/'.vox-dev/test/runtime.json').write_text('leftover-evidence')
        self.call('remove','test',ok=False)

if __name__=='__main__':unittest.main()
