#!/usr/bin/env python3
"""macOS fixture integration: real private voxd + model-free VoxClient, loopback only.
No vendor/account/external network calls. Does not touch installed runtime or launchd.
Run after: xcrun swift build --package-path swift --product voxd
"""
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tempfile
import threading
import time
import urllib.parse
import wave

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "scripts/fixtures/annotation"
KEYS = [b"fixture-eleven-a", b"fixture-eleven-c", b"fixture-eleven-d", b"fixture-rejected", b"fixture-slow", b"fixture-deepgram-b"]
uploads_before = set(Path(tempfile.gettempdir()).resolve().glob("vox-annotation-*"))
seen = []
failures = []
slow_started = threading.Event()
slow_disconnected = threading.Event()

class Vendor(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass  # Never log credentials or uploaded media.
    def do_POST(self):
        try:
            length = int(self.headers["Content-Length"])
            body = self.rfile.read(length)
            eleven = self.path == "/scribe"
            key = self.headers.get("xi-api-key") if eleven else self.headers.get("Authorization")
            seen.append((eleven, key))
            if eleven:
                assert key in ["fixture-eleven-a", "fixture-eleven-c", "fixture-eleven-d", "fixture-rejected", "fixture-slow"]
                assert b'name="model_id"\r\n\r\nscribe_v2' in body
                assert b'name="timestamps_granularity"\r\n\r\nword' in body
                assert b'name="diarize"\r\n\r\ntrue' in body
                assert b'name="tag_audio_events"\r\n\r\ntrue' in body
                assert b'name="webhook"\r\n\r\nfalse' in body
                assert b'filename="audio.wav"' in body and b"private-recording" not in body
                assert key.encode() not in body and audio_bytes in body
                if key == "fixture-eleven-a":
                    assert b'name="num_speakers"\r\n\r\n2' in body
                    assert b'name="language_code"\r\n\r\neng' in body
            else:
                assert key == "Token fixture-deepgram-b" and body == audio_bytes
                query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
                assert query["model"] == ["nova-3"] and query["diarize_model"] == ["v2"]
                assert query["utterances"] == ["true"] and query["detect_language"] == ["true"]
            if key == "fixture-slow":
                slow_started.set()
                # Peer disconnect is observable without attempting a vendor completion.
                self.connection.settimeout(5)
                if self.rfile.read(1) == b"": slow_disconnected.set()
                return
            data = (key.encode() if key == "fixture-rejected" else
                    (FIXTURES / ("scribe.json" if eleven else "deepgram.json")).read_bytes())
            self.send_response(401 if key == "fixture-rejected" else 200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as error:
            failures.append(type(error).__name__ + ": " + str(error))
            self.close_connection = True

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Vendor)
threading.Thread(target=server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix="vox-ann-", dir="/private/tmp") as temporary:
    work = Path(temporary)
    audio = work / "private-recording.wav"
    with wave.open(str(audio), "wb") as wav:
        wav.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        wav.writeframes(bytes(64000))
    audio_bytes = audio.read_bytes()
    client = work / "client"
    (client / "Sources/Smoke").mkdir(parents=True)
    (client / "Package.swift").write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "AnnotationFixture", platforms: [.macOS(.v14)],
 dependencies: [.package(path: %s)],
 targets: [.executableTarget(name: "Smoke", dependencies: [.product(name: "VoxClient", package: "vox")])])
''' % json.dumps(str(ROOT)))
    shutil.copyfile(FIXTURES / "client.swift", client / "Sources/Smoke/main.swift")
    subprocess.run(["xcrun", "swift", "build", "--package-path", str(client), "--jobs", "3"], check=True)
    environment = {k: v for k, v in os.environ.items() if not k.startswith("VOX_") and not k.endswith("_API_KEY")}
    home = work / "home"
    home.mkdir(mode=0o700)
    environment["VOX_HOME"] = str(home)
    environment["VOX_ANNOTATION_ELEVENLABS_URL"] = f"http://127.0.0.1:{server.server_port}/scribe"
    environment["VOX_ANNOTATION_DEEPGRAM_URL"] = f"http://127.0.0.1:{server.server_port}/listen"
    log = work / "daemon.log"
    daemon = None
    try:
        with log.open("wb") as output:
            daemon = subprocess.Popen([str(ROOT / "swift/.build/debug/voxd"), "--private"], env=environment, stdout=output, stderr=output)
            runtime = home / "runtime.json"
            for _ in range(200):
                if runtime.exists(): break
                assert daemon.poll() is None, log.read_text()
                time.sleep(.05)
            assert stat.S_IMODE(runtime.stat().st_mode) == 0o600
            metadata = json.loads(runtime.read_text())
            assert metadata["port"] == 0 and len(metadata["authToken"]) == 43
            subprocess.run([str(client / ".build/debug/Smoke"), str(audio)], env=environment, check=True, timeout=30)
            assert slow_started.wait(2) and slow_disconnected.wait(5), "HTTP upload not cancelled on private disconnect"
            for _ in range(100):
                remaining = set(Path(tempfile.gettempdir()).resolve().glob("vox-annotation-*")) - uploads_before
                if not remaining: break
                time.sleep(.02)
            assert not remaining, "temporary annotation upload not removed"
            assert not failures, failures
            assert len(seen) == 7, f"unexpected uploads: {len(seen)}"
            for path in home.rglob("*"):
                if path.is_file(): assert not any(key in path.read_bytes() for key in KEYS), "request credential persisted"
            assert not any(key in log.read_bytes() for key in KEYS), "request credential logged"
    finally:
        if daemon is not None:
            daemon.send_signal(signal.SIGTERM)
            daemon.wait(timeout=10)
            assert not (home / "runtime.json").exists() and not (home / "voxd.sock").exists()
        server.shutdown()
print("PASS: loopback HTTP contract and upload cancellation; seven expected uploads; no request-key persistence; private capability/socket removed")
