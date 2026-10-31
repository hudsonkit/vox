#!/usr/bin/env python3
"""Opt-in private offline library probe. Never launches a daemon/app or downloads models.
Run only with an existing pinned v3 bundle. Core ML's system compiler/cache is OS-owned.
"""
import argparse
from datetime import datetime, timezone
import json
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
GIB = 1024 ** 3
REQUIRED = ['Encoder.mlmodelc', 'Preprocessor.mlmodelc', 'Decoder.mlmodelc', 'JointDecisionv3.mlmodelc', 'parakeet_vocab.json']

def capture(args):
    return subprocess.check_output(args, text=True).strip()

def resources():
    processes = []
    for line in capture(['/bin/ps', '-axo', 'pid,pcpu,rss,comm']).splitlines()[1:]:
        parts = line.split(None, 3)
        if len(parts) == 4 and Path(parts[3]).name in ['ANECompilerService', 'TalkieAgent', 'voxd']:
            processes.append(dict(pid=int(parts[0]), cpuPercent=float(parts[1]), rssKiB=int(parts[2]), name=Path(parts[3]).name))
    return dict(utc=datetime.now(timezone.utc).isoformat(),
        freeTempDiskBytes=shutil.disk_usage(tempfile.gettempdir()).free,
        memoryPressureLevel=int(capture(['/usr/sbin/sysctl', '-n', 'kern.memorystatus_vm_pressure_level'])),
        swap=capture(['/usr/sbin/sysctl', '-n', 'vm.swapusage']), processes=processes)

def write_private(path, value):
    fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
    with os.fdopen(fd, 'w') as out: json.dump(value, out, indent=2); out.write('\n')

def owned_helper(pid, parent_pid):
    """SwiftPM puts its testing helper in a SEPARATE process group.

    Verify the direct parent and mapped checkout bundle, not the helper name alone.
    A failed check means no profiling or signalling of that PID.
    """
    try:
        if int(capture(['/bin/ps', '-p', str(pid), '-o', 'ppid='])) != parent_pid:
            return False
        bundle_root = str((ROOT/'swift/.build').resolve()) + '/'
        mapped = capture(['/usr/sbin/lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'])
        return any(line.startswith('n' + bundle_root) and
            line.endswith('/VoxEngineTests.xctest/Contents/MacOS/VoxEngineTests')
            for line in mapped.splitlines())
    except (OSError, ValueError, subprocess.SubprocessError):
        return False

def stop_owned_processes(process, helper_pid):
    # The helper is not in SwiftPM's process group. Stop only a reverified helper,
    # then the isolated SwiftPM group; never signal the system compiler.
    helper_owned = helper_pid is not None and owned_helper(helper_pid, process.pid)
    if helper_owned:
        try: os.kill(helper_pid, signal.SIGTERM)
        except ProcessLookupError: pass
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and owned_helper(helper_pid, process.pid):
            time.sleep(0.1)
        if owned_helper(helper_pid, process.pid):
            try: os.kill(helper_pid, signal.SIGKILL)
            except ProcessLookupError: pass
    if process.poll() is None:
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try: process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait()

def main():
    args = argparse.ArgumentParser()
    args.add_argument('--model-directory', required=True, type=Path)
    args.add_argument('--output', required=True, type=Path)
    args.add_argument('--deadline-seconds', type=float, default=900)
    parsed = args.parse_args()
    model = parsed.model_directory.resolve(strict=True)
    assert all((model / name).exists() for name in REQUIRED), 'Missing existing v3 artifacts; no installation is attempted'
    output = parsed.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.chmod(output, 0o700)
    initial = resources()
    manifest = dict(status='preflight', sourceSHA=capture(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']),
        engineTree=capture(['git', '-C', str(ROOT), 'rev-parse', 'HEAD:swift/Sources/HudsonSpeechEngine']),
        platform=dict(productVersion=capture(['/usr/bin/sw_vers', '-productVersion']),
            build=capture(['/usr/bin/sw_vers', '-buildVersion']), machine=os.uname().machine),
        modelRevision='7dd20fe6b1797d35f5e3307e8b1732d9a178edfe', initial=initial,
        sourceStatus=capture(['git', '-C', str(ROOT), 'status', '--porcelain']),
        probeSHA256={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in [
            'scripts/probe-parakeet-reload.py', 'swift/Tests/VoxEngineTests/ASR/Parakeet/ParakeetReloadHardwareProbe.swift']},
        policy=dict(minimumStartDiskBytes=5*GIB, abortDiskBytes=GIB, abortKernelPressureLevel=4,
            note='Conservative experiment budget, not a documented Core ML minimum; no cache deletion.'),
        modelDirectory=str(model), modelFileStats={name:dict(mtimeNs=(model/name).stat().st_mtime_ns) for name in REQUIRED})
    write_private(output/'manifest.json', manifest)
    if initial['freeTempDiskBytes'] < 5*GIB or initial['memoryPressureLevel'] != 1:
        manifest['status'] = 'blocked-preflight'; write_private(output/'manifest.json', manifest)
        print('BLOCKED before model load: insufficient disk reserve or kernel pressure not normal'); return 2
    (output/'private-home').mkdir(mode=0o700)
    env = dict(os.environ, VOX_RELOAD_PROBE='1', VOX_RELOAD_MODEL_DIRECTORY=str(model),
        VOX_RELOAD_RESULT=str(output/'metrics.json'), VOX_HOME=str(output/'private-home'))
    command = ['xcrun','swift','test','--package-path',str(ROOT/'swift'),'--skip-build','--filter','ParakeetReloadHardwareProbe']
    manifest['command'] = command; manifest['status'] = 'running'
    write_private(output/'manifest.json', manifest)
    sampled = False; map_phases = set(); started = time.monotonic(); aborted = None; helper_pid = None
    fd = os.open(output/'probe.log', os.O_CREAT|os.O_EXCL|os.O_WRONLY, 0o600)
    with os.fdopen(fd,'wb') as log, (output/'resources.jsonl').open('w') as history:
        os.chmod(output/'resources.jsonl',0o600)
        process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            while process.poll() is None:
                state = resources(); history.write(json.dumps(state)+'\n'); history.flush()
                try:
                    metrics=json.loads((output/'metrics.json').read_text())
                    candidate=metrics['pid']
                    if helper_pid is None and owned_helper(candidate, process.pid): helper_pid=candidate
                except (OSError, ValueError, KeyError): pass
                if state['freeTempDiskBytes'] < GIB or state['memoryPressureLevel'] >= 4:
                    aborted = 'resource-watchdog'; break
                if time.monotonic()-started > parsed.deadline_seconds:
                    aborted = 'deadline'; break
                try:
                    metrics=json.loads((output/'metrics.json').read_text()); pid=metrics['pid']; last=metrics['records'][-1]['phase']
                    owned=helper_pid==pid and owned_helper(pid, process.pid)
                    if owned and (last.endswith('-ready') or last.endswith('-after-unload')) and last not in map_phases:
                        with (output/(last+'.vmmap.txt')).open('w') as out:
                            subprocess.run(['/usr/bin/vmmap','-summary',str(pid)],stdout=out,stderr=subprocess.STDOUT,timeout=12)
                        map_phases.add(last)
                    if owned and not sampled and time.monotonic()-started > 30:
                        subprocess.run(['/usr/bin/sample',str(pid),'2','-file',str(output/'probe.sample.txt')],
                            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=8)
                        sampled=True
                except (OSError, ValueError, KeyError, subprocess.SubprocessError): pass
                time.sleep(1)
            if aborted:
                stop_owned_processes(process, helper_pid)
            else: process.wait()
        finally:
            if process.poll() is None:
                stop_owned_processes(process, helper_pid)
    manifest['final']=resources(); manifest['exitCode']=process.returncode
    manifest['status']=aborted or ('completed' if process.returncode==0 else 'failed')
    if not aborted and (output/'metrics.json').exists():
        records=json.loads((output/'metrics.json').read_text())['records']
        if any(record['phase']=='blocked-headroom' for record in records): manifest['status']='blocked-phase-headroom'
    manifest['warning']='Stopping our caller does not guarantee the OS compiler has stopped; no automatic replay.'
    write_private(output/'manifest.json',manifest)
    print(json.dumps(dict(status=manifest['status'],exitCode=process.returncode)))
    return 0 if manifest['status']=='completed' else 1

if __name__=='__main__': raise SystemExit(main())
