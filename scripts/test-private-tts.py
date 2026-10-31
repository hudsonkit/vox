#!/usr/bin/env python3
"""Real private voxd + bundled voxttsd + two model-free clients, loopback TTS only.
Build with xcrun swift build --package-path swift first. No paid vendor calls,
real credentials, playback, installed runtime or launchd changes.
"""
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import wave

ROOT = Path(__file__).resolve().parents[1]
KEYS = [b"tts-loan-a", b"tts-loan-b", b"tts-loan-rejected"]
state = {"aStarted": False, "bStarted": False, "aClosed": False}
release = threading.Event()
failures, seen, first_children = [], [], []
daemon = None
stream = io.BytesIO()
with wave.open(stream, "wb") as wav:
    wav.setparams((1, 2, 44100, 0, "NONE", "not compressed")); wav.writeframes(bytes(8820))
AUDIO = stream.getvalue()

def children():
    result = subprocess.run(["pgrep", "-P", str(daemon.pid)], capture_output=True, text=True)
    return sorted(result.stdout.split())

class Vendor(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def reply(self, status, data, mime="application/json"):
        self.send_response(status); self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path == "/state": self.reply(200, json.dumps(state).encode()); return
        self.vendor(None)
    def do_POST(self):
        if self.path == "/release": release.set(); self.reply(200, b"{}"); return
        self.vendor(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
    def vendor(self, body):
        try:
            if not first_children: first_children.extend(children())
            openai = self.path == "/v1/audio/speech"
            key = self.headers.get("Authorization", "").removeprefix("Bearer ") if openai else self.headers.get("xi-api-key", "")
            seen.append((self.path, key))
            assert self.headers.get("Cache-Control") == "no-store"
            text = (body or {}).get("input" if openai else "text", "")
            if key == "tts-loan-rejected": self.reply(401, json.dumps({"detail": key + " " + text}).encode()); return
            assert key in ["tts-loan-a", "tts-loan-b"]
            account = key[-1]
            if self.path.startswith("/v2/voices"):
                self.reply(200, json.dumps({"voices": [{"voice_id": "fixture-" + account, "name": "Fixture"}]}).encode()); return
            if openai:
                assert body["model"] == "gpt-4o-mini-tts" and body["voice"] == "alloy" and body["response_format"] == "wav"
            else:
                assert self.path.startswith("/v1/text-to-speech/fixture-" + account)
                assert body["model_id"] == "eleven_flash_v2_5" and "output_format=wav_44100" in self.path
            if text == "fixture-slow-a":
                state["aStarted"] = True; self.connection.settimeout(5)
                if self.rfile.read(1) == b"": state["aClosed"] = True
                assert state["aClosed"], "cancelled HTTP request stayed open"; return
            if text == "fixture-slow-b":
                state["bStarted"] = True; assert release.wait(6), "other client never released"
            self.reply(200, AUDIO, "audio/wav")
        except Exception as error:
            # No request/key/body content in diagnostics, including assertion context.
            failures.append(type(error).__name__); self.close_connection = True

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Vendor)
threading.Thread(target=server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix="vox-tts-", dir="/private/tmp") as temporary:
    work = Path(temporary); client = work / "client"
    (client / "Sources/Smoke").mkdir(parents=True)
    (client / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "TTSFixture", platforms: [.macOS(.v14)],
 dependencies: [.package(path: %s)],
 targets: [.executableTarget(name: "Smoke", dependencies: [.product(name: "VoxClient", package: "vox")])])
''' % json.dumps(str(ROOT)))
    shutil.copyfile(ROOT / "scripts/fixtures/tts/client.swift", client / "Sources/Smoke/main.swift")
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(client), "--jobs", "3"], check=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("VOX_") and not k.endswith("_API_KEY")}
    home = work / "home"; home.mkdir(mode=0o700)
    base = f"http://127.0.0.1:{server.server_port}"
    # Empty provider keys fence ambient/keychain fallback; no global account key.
    env.update(VOX_HOME=str(home), OPENAI_API_KEY="", ELEVENLABS_API_KEY="", OPENAI_BASE_URL=base + "/v1", ELEVENLABS_BASE_URL=base)
    log = work / "daemon.log"
    try:
        with log.open("wb") as output:
            daemon = subprocess.Popen([str(ROOT / "swift/.build/debug/voxd"), "--private"], env=env, stdout=output, stderr=output)
            for _ in range(200):
                if (home / "runtime.json").exists(): break
                assert daemon.poll() is None, "isolated daemon exited"; time.sleep(.05)
            assert (home / "runtime.json").stat().st_mode & 0o777 == 0o600
            consumer_env = dict(env, TTS_FIXTURE_URL=base)
            result = subprocess.run([str(client / ".build/debug/Smoke")], env=consumer_env, capture_output=True, check=True, timeout=30)
            assert not failures, failures
            assert state["aClosed"] and state["bStarted"]
            assert first_children and children() == first_children, "shared helper restarted or died"
            assert len(seen) == 9, "unexpected vendor request count"
            for path in home.rglob("*"):
                if path.is_file(): assert not any(key in path.read_bytes() for key in KEYS), "loan key persisted"
            for data in [log.read_bytes(), result.stdout, result.stderr]:
                assert not any(key in data for key in KEYS), "loan key logged"
            print(result.stdout.decode().strip())
    finally:
        release.set()
        if daemon is not None:
            owned = children(); daemon.send_signal(signal.SIGTERM); daemon.wait(timeout=10)
            for _ in range(100):
                if not any(subprocess.run(["kill", "-0", pid], capture_output=True).returncode == 0 for pid in owned): break
                time.sleep(.02)
            else: raise AssertionError("owned helper did not exit on parent EOF")
            assert not (home / "runtime.json").exists() and not (home / "voxd.sock").exists()
        server.shutdown()
print("PASS: stock private daemon/helper, request-key/error privacy, scoped cancellation, other in-flight client survives, helper PID unchanged and clean EOF")
