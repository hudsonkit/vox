#!/usr/bin/env python3
"""Named, owner-only dev voxd copies. Never installs launchd jobs or touches ~/.vox.
Build voxd and voxttsd explicitly first. Run stays in the foreground; stop targets
only its verified supervisor. Removing a stopped dev host never removes models.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import shlex
import stat
import subprocess
import sys
import time

SCHEMA='vox-dev-host-1'
RESOURCE_BUNDLE='HudsonSpeechEngine_HudsonSpeechEngine.bundle'

def fail(message): raise RuntimeError(message)
def private_directory(path, create=False):
    if create:
        try:path.mkdir(mode=0o700)
        except FileExistsError:pass
    info=path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077:
        fail('Dev directory must be a same-user non-symlink directory with mode 0700')

def read_private(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    with os.fdopen(fd) as f:
        info=os.fstat(f.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode&0o077 or info.st_nlink!=1 or info.st_size>65536:
            fail('Unsafe dev metadata file')
        return json.load(f)

def write_private(path, value):
    temporary=path.with_name(path.name+'.new')
    fd=os.open(temporary,os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
    try:
        with os.fdopen(fd,'w') as f:
            json.dump(value,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
        os.replace(temporary,path)
    finally:
        try:temporary.unlink()
        except FileNotFoundError:pass

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def resource_hashes(path):
    if not path.is_dir() or path.is_symlink():fail('Missing SwiftPM engine resource bundle')
    files={}
    for file in path.rglob('*'):
        if file.is_symlink():fail('Resource bundle must not contain symlinks')
        if file.is_file():files[str(file.relative_to(path))]=digest(file)
    if not files:fail('Empty SwiftPM engine resource bundle')
    return files
def start_identity(pid):
    p=subprocess.run(['/bin/ps','-p',str(pid),'-o','uid=,lstart='],text=True,capture_output=True)
    return p.stdout.strip() if p.returncode==0 else None

def locked(root):
    fd=os.open(root/'.run.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    info=os.fstat(fd)
    if info.st_uid!=os.getuid() or info.st_mode&0o077 or not stat.S_ISREG(info.st_mode) or info.st_nlink!=1:
        os.close(fd);fail('Unsafe dev lease')
    try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:os.close(fd);fail('Dev host is running; stop it first')
    return fd

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['install','run','status','stop','remove'])
    parser.add_argument('name')
    parser.add_argument('--bin-dir',type=Path)
    parser.add_argument('--models-path',type=Path)
    parser.add_argument('--revision')
    parser.add_argument('--minimum-free-disk-bytes',type=int)
    parser.add_argument('--idle-seconds',type=float,default=900)
    args=parser.parse_args()
    if not re.fullmatch('[a-zA-Z0-9][a-zA-Z0-9_-]{0,29}',args.name):fail('Use a short alphanumeric dev name')
    base=Path.home()/'.vox-dev';private_directory(base,create=args.action=='install')
    root=base/args.name
    if len(str(root/'voxd.sock').encode())>=104:fail('Dev socket path exceeds the Unix path limit')
    if args.action=='install':
        if root.exists() or root.is_symlink():fail('Dev name already exists; install under a new name or remove the stopped old copy')
        if args.bin_dir is None or args.models_path is None:fail('Install requires --bin-dir and explicit --models-path')
        binaries=args.bin_dir.resolve(strict=True);models=args.models_path.resolve(strict=True)
        if not models.is_dir() or models.stat().st_uid!=os.getuid():fail('Models root must be an existing same-user directory')
        for name in ['voxd','voxttsd']:
            if not (binaries/name).is_file() or not os.access(binaries/name,os.X_OK):fail('Build both voxd and voxttsd explicitly before install')
        resources=resource_hashes(binaries/RESOURCE_BUNDLE)
        root.mkdir(mode=0o700);(root/'bin').mkdir(mode=0o700);(root/'home').mkdir(mode=0o700)
        for name in ['voxd','voxttsd']:
            shutil.copy2(binaries/name,root/'bin'/name);(root/'bin'/name).chmod(0o700)
        shutil.copytree(binaries/RESOURCE_BUNDLE,root/'bin'/RESOURCE_BUNDLE)
        write_private(root/'install.json',dict(schema=SCHEMA,name=args.name,uid=os.getuid(),modelsPath=str(models),revision=args.revision,resources=resources,
            binaries={name:digest(root/'bin'/name) for name in ['voxd','voxttsd']}))
        print('Installed isolated dev copies. Next: python3 '+str(Path(__file__).resolve())+' run '+args.name)
        return
    private_directory(root)
    installed=read_private(root/'install.json')
    if installed.get('schema')!=SCHEMA or installed.get('uid')!=os.getuid() or installed.get('name')!=args.name:fail('Not an owned dev host installation')
    if args.action=='status':
        info=read_private(root/'process.json') if (root/'process.json').exists() else None
        running=bool(info and start_identity(info['supervisorPID'])==info['supervisorIdentity'])
        print(json.dumps(dict(name=args.name,running=running,runtimePath=str(root/'runtime.json'),capabilityPresent=(root/'runtime.json').exists())))
        return
    if args.action=='stop':
        if not (root/'process.json').exists():print('Dev host is not running');return
        info=read_private(root/'process.json')
        if start_identity(info['supervisorPID'])!=info['supervisorIdentity']:fail('Supervisor no longer matches; refusing to signal a reused PID')
        os.kill(info['supervisorPID'],signal.SIGTERM)
        print('Stop requested for the verified dev supervisor only')
        return
    lease=locked(root)
    try:
        if (root/'runtime.json').exists():fail('A runtime capability still exists; refusing overwrite/removal')
        if args.action=='remove':
            shutil.rmtree(root)
            print('Removed owned dev copies/state only; shared model store untouched')
            return
        if args.idle_seconds<0 or not args.idle_seconds<float('inf'):fail('Idle seconds must be finite and nonnegative')
        if set(installed.get('binaries',{}))!={'voxd','voxttsd'}:fail('Invalid owned binary inventory')
        for name,expected in installed['binaries'].items():
            path=root/'bin'/name
            if path.is_symlink() or digest(path)!=expected:fail('Installed dev binary changed; use a new named installation')
        if resource_hashes(root/'bin'/RESOURCE_BUNDLE)!=installed.get('resources'):fail('Installed dev resources changed; use a new named installation')
        env={k:v for k,v in os.environ.items() if not k.startswith('VOX_')}
        env.update(VOX_HOME=str(root/'home'),VOX_MODELS_PATH=installed['modelsPath'],VOX_RUNTIME_PATH=str(root/'runtime.json'),
                   VOX_SOCKET_PATH=str(root/'voxd.sock'),VOX_ASR_IDLE_SECONDS=str(args.idle_seconds))
        if args.minimum_free_disk_bytes is not None:
            if args.minimum_free_disk_bytes<0:fail('Minimum free disk bytes must be nonnegative')
            env['VOX_ASR_MIN_FREE_DISK_BYTES']=str(args.minimum_free_disk_bytes)
        stopping=False
        def stop_handler(*_):
            nonlocal stopping
            stopping=True
        previous={s:signal.signal(s,stop_handler) for s in [signal.SIGTERM,signal.SIGINT]}
        log=os.open(root/'console.log',os.O_CREAT|os.O_APPEND|os.O_WRONLY|os.O_NOFOLLOW,0o600)
        with os.fdopen(log,'ab') as output:
            child=subprocess.Popen([str(root/'bin/voxd'),'--private'],env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
            write_private(root/'process.json',dict(supervisorPID=os.getpid(),supervisorIdentity=start_identity(os.getpid()),daemonPID=child.pid))
            print('Dev host starting; client export: VOX_RUNTIME_PATH='+shlex.quote(str(root/'runtime.json')),flush=True)
            try:
                while child.poll() is None and not stopping:time.sleep(0.1)
            finally:
                if child.poll() is None:
                    child.terminate()
                    try:child.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        child.kill();child.wait()
                for s,handler in previous.items():signal.signal(s,handler)
                (root/'process.json').unlink(missing_ok=True)
            if (root/'runtime.json').exists():fail('Dev daemon did not remove its capability; retain evidence, do not remove state automatically')
            if child.returncode not in [0,-signal.SIGTERM]:fail('Dev daemon exited unsuccessfully; inspect private console.log')
    finally:os.close(lease)

if __name__=='__main__':
    try:main()
    except (RuntimeError,OSError,ValueError) as error:
        print('Dev host: '+str(error),file=sys.stderr);raise SystemExit(1)
