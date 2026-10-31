#!/usr/bin/env python3
"""Real copied voxd/resource bundle + model-free client. Never prepares a model.
Uses a short private temporary HOME; verifies install/run/discovery/stop/remove
without touching the real installed capability or external model-store marker.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--bin-dir',required=True,type=Path);p.add_argument('--client',required=True,type=Path);a=p.parse_args()
installed=Path.home()/'.vox/runtime.json'
def old_hash():return hashlib.sha256(installed.read_bytes()).hexdigest() if installed.exists() else None
before=old_hash()
with tempfile.TemporaryDirectory(prefix='vxd-',dir='/private/tmp') as directory:
    home=Path(directory);models=home/'models';models.mkdir(mode=0o700);(models/'keep').write_text('external-model-store-marker')
    env={k:v for k,v in os.environ.items() if not k.startswith('VOX_') and not k.endswith('_API_KEY')}
    env.update(HOME=str(home),OPENAI_API_KEY='',ELEVENLABS_API_KEY='')
    command=[sys.executable,str(ROOT/'scripts/dev-voxd.py')]
    subprocess.run(command+['install','smoke','--bin-dir',str(a.bin_dir.resolve()),'--models-path',str(models)],env=env,check=True)
    log=home/'supervisor.log'
    with log.open('wb') as out:
        host=subprocess.Popen(command+['run','smoke'],env=env,stdout=out,stderr=subprocess.STDOUT)
        root=home/'.vox-dev/smoke';capability=root/'runtime.json'
        try:
            deadline=time.monotonic()+15
            while not capability.exists():
                assert host.poll() is None,'dev host exited before publishing capability'
                assert time.monotonic()<deadline,'no dev capability';time.sleep(.05)
            assert capability.stat().st_mode&0o777==0o600
            capability_data=json.loads(capability.read_text())
            client_env=dict(env,VOX_RUNTIME_PATH=str(capability))
            result=subprocess.run([str(a.client.resolve()),'health'],env=client_env,capture_output=True,check=True,timeout=15)
            health=json.loads(result.stdout);assert health['pid']==capability_data['pid']
            inventory=subprocess.run([str(a.client.resolve()),'models'],env=client_env,capture_output=True,check=True,timeout=15)
            assert all(not m['preloaded'] for m in json.loads(inventory.stdout)['models'])
            assert capability_data['authToken'].encode() not in result.stdout+inventory.stdout+log.read_bytes()
            native_log=root/'home/logs/voxd.log'
            assert 'CoreML load stage' not in native_log.read_text(),'metadata smoke must not prepare models'
        finally:
            if host.poll() is None:
                subprocess.run(command+['stop','smoke'],env=env,check=True);host.wait(timeout=20)
        assert host.returncode==0,log.read_text()
        assert not capability.exists() and not (root/'voxd.sock').exists()
    subprocess.run(command+['remove','smoke'],env=env,check=True)
    assert not root.exists() and (models/'keep').read_text()=='external-model-store-marker'
assert old_hash()==before,'installed runtime capability changed'
print('PASS: real copied daemon/resources, owner-only capability, model-free health/inventory, no native warmup, clean stop/remove, installed capability/model store unchanged')
