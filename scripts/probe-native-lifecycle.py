#!/usr/bin/env python3
"""Opt-in public-provider hardware measurement. Existing models and WAV only.
No daemon/service changes, downloads, cache cleanup, CPU fallback or automatic replay.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
GIB = 1024**3

def capture(command):
    return subprocess.check_output(command, text=True).strip()

def resources(pid=None):
    processes = []
    for line in capture(['/bin/ps', '-axo', 'pid,pcpu,rss,comm']).splitlines()[1:]:
        parts = line.split(None, 3)
        if len(parts)==4 and (Path(parts[3]).name in ['ANECompilerService', 'TalkieAgent', 'voxd'] or int(parts[0])==pid):
            processes.append(dict(pid=int(parts[0]),cpuPercent=float(parts[1]),rssKiB=int(parts[2]),name=Path(parts[3]).name))
    return dict(utc=datetime.now(timezone.utc).isoformat(),freeDiskBytes=shutil.disk_usage(tempfile.gettempdir()).free,
                pressure=int(capture(['/usr/sbin/sysctl','-n','kern.memorystatus_vm_pressure_level'])),
                swap=capture(['/usr/sbin/sysctl','-n','vm.swapusage']),processes=processes)

def write(path, value):
    with os.fdopen(os.open(path,os.O_CREAT|os.O_TRUNC|os.O_WRONLY,0o600),'w') as f:
        json.dump(value,f,indent=2);f.write('\n')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--model',required=True,choices=['parakeet:v3','nemotron:unified-560ms'])
    parser.add_argument('--models-path',required=True,type=Path)
    parser.add_argument('--audio',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--deadline-seconds',default=1200,type=float)
    parser.add_argument('--idle-seconds',default=60,type=float)
    args=parser.parse_args()
    binary=(ROOT/'swift/.build/debug/vox-asr-bench').resolve(strict=True)
    models=args.models_path.resolve(strict=True);audio=args.audio.resolve(strict=True)
    output=args.output.absolute();output.mkdir(parents=True,mode=0o700,exist_ok=False);output.chmod(0o700)
    home=output/'home';home.mkdir(mode=0o700)
    initial=resources()
    manifest=dict(status='preflight',sourceSHA=capture(['git','-C',str(ROOT),'rev-parse','HEAD']),
        sourceStatus=capture(['git','-C',str(ROOT),'status','--porcelain']),
        binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),modelsPath=str(models),audioSHA256=hashlib.sha256(audio.read_bytes()).hexdigest(),
        modelId=args.model,initial=initial,platform=capture(['/usr/bin/sw_vers']),
        policy=dict(startReserveBytes=5*GIB,abortDiskBytes=GIB,abortPressure=4,deadlineSeconds=args.deadline_seconds))
    write(output/'manifest.json',manifest)
    if initial['freeDiskBytes']<5*GIB or initial['pressure']!=1:
        manifest['status']='blocked-preflight';write(output/'manifest.json',manifest);print('Blocked before native preparation');return 2
    env={k:v for k,v in os.environ.items() if not k.startswith('VOX_')}
    env.update(VOX_HOME=str(home),VOX_MODELS_PATH=str(models))
    command=[str(binary),'lifecycle',args.model,str(audio),'--report',str(output/'metrics.json'),'--idle-seconds',str(args.idle_seconds)]
    manifest['command']=command;manifest['status']='running';write(output/'manifest.json',manifest)
    log=os.open(output/'probe.log',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    history=os.open(output/'resources.jsonl',os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    start=time.monotonic();sampled=False;aborted=None
    with os.fdopen(log,'wb') as f,os.fdopen(history,'w') as h:
        p=subprocess.Popen(command,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
        manifest['pid']=p.pid;write(output/'manifest.json',manifest)
        try:
            while p.poll() is None:
                state=resources(p.pid);h.write(json.dumps(state)+'\n');h.flush()
                if state['freeDiskBytes']<GIB or state['pressure']>=4:aborted='resource-watchdog';break
                if time.monotonic()-start>args.deadline_seconds:aborted='deadline';break
                if not sampled and time.monotonic()-start>30:
                    try:
                        owned=os.getpgid(p.pid)==p.pid and capture(['/bin/ps','-p',str(p.pid),'-o','comm='])==str(binary)
                        if owned:
                            subprocess.run(['/usr/bin/sample',str(p.pid),'2','-file',str(output/'probe.sample.txt')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=8)
                            with (output/'probe.vmmap.txt').open('w') as v:
                                subprocess.run(['/usr/bin/vmmap','-summary',str(p.pid)],stdout=v,stderr=subprocess.STDOUT,timeout=8)
                        sampled=True
                    except (OSError,subprocess.SubprocessError):pass
                time.sleep(1)
            if aborted:
                # Dedicated process group contains our benchmark, never the OS compiler.
                try:os.killpg(p.pid,signal.SIGTERM)
                except ProcessLookupError:pass
                try:p.wait(timeout=8)
                except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
            else:p.wait()
        finally:
            if p.poll() is None:
                os.killpg(p.pid,signal.SIGTERM);p.wait(timeout=8)
    manifest.update(status=aborted or ('completed' if p.returncode==0 else 'failed'),exitCode=p.returncode,final=resources())
    write(output/'manifest.json',manifest)
    print(json.dumps(dict(status=manifest['status'],exitCode=p.returncode)))
    return 0 if manifest['status']=='completed' else 1

if __name__=='__main__':raise SystemExit(main())
