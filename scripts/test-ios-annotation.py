#!/usr/bin/env python3
"""CI-only real iOS sandbox consumer, loopback uploads, no paid calls/models/operator app.
Creates/deletes ONLY its own ephemeral Simulator; never run on an operator device.
"""
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import uuid

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "examples/annotation-sandbox"
state = dict(scoped=0, started=0, closedA=0, closedB=0, reflected=0, oversize=0)
lock = threading.Lock()
release = threading.Event()
failures = []
SCRIBE = json.dumps(dict(text="Hello world", language_code="eng", audio_duration_secs=0.1,
    words=[dict(text="Hello", start=0, end=0.04, type="word", speaker_id="speaker_0", logprob=-0.2),
           dict(text="world", start=0.04, end=0.08, type="word", speaker_id="speaker_1"),
           dict(text="[laugh]", start=0.08, end=0.1, type="audio_event", speaker_id="speaker_1")])).encode()

class Vendor(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def reply(self, body, status=200):
        self.send_response(status); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == "/release": release.set()
        with lock: body = json.dumps(state).encode()
        self.reply(body)
    def do_POST(self):
        key = None
        try:
            assert self.path == "/scribe"
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                body = bytearray()
                while True:
                    size = int(self.rfile.readline(100).split(b";", 1)[0], 16)
                    assert 0 <= size < 100_000 and len(body) + size < 100_000
                    if size == 0:
                        assert self.rfile.readline(100) == b"\r\n"
                        break
                    body.extend(self.rfile.read(size)); assert self.rfile.read(2) == b"\r\n"
                body = bytes(body)
            else:
                length = int(self.headers["Content-Length"])
                assert 0 < length < 100_000
                body = self.rfile.read(length)
            key = self.headers.get("xi-api-key")
            assert key in ["fixture-one", "fixture-two", "fixture-reflect", "fixture-hold-a", "fixture-hold-b"]
            assert b'filename="audio.wav"' in body and b"RIFF" in body
            assert b"private-recording-" not in body and key.encode() not in body
            for text in [b"scribe_v2", b"timestamps_granularity", b"word", b"diarize", b"tag_audio_events", b"num_speakers", b"eng"]:
                assert text in body
            if key in ["fixture-one", "fixture-two"]:
                with lock: state["scoped"] += 1
            if key == "fixture-reflect":
                with lock: state["reflected"] += 1
                self.reply(json.dumps(dict(error=key)).encode(), status=401); return
            if key.startswith("fixture-hold-"):
                with lock: state["started"] += 1
                if key == "fixture-hold-a":
                    self.connection.settimeout(10)
                    if self.rfile.read(1) == b"":
                        with lock: state["closedA"] += 1
                    return
                assert release.wait(10), "survivor not released"
            self.reply(SCRIBE)
        except (BrokenPipeError, ConnectionResetError):
            if key == "fixture-hold-b":
                with lock: state["closedB"] += 1
        except Exception as error:
            with lock: failures.append(type(error).__name__)  # no request/body/credential reflection
            try: self.reply(b"{}", 500)
            except OSError: pass

def run(args, **kwargs): return subprocess.run(args, check=True, **kwargs)
def capture(args): return subprocess.check_output(args, text=True).strip()

if os.environ.get("CI") != "true":
    raise SystemExit("Refusing operator-runtime changes: this Simulator consumer is CI-only (CI=true).")
if not shutil.which("xcodegen"): raise SystemExit("Install XcodeGen on the CI runner first.")
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Vendor)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
created = None
try:
    generated = EXAMPLE / "Generated"; generated.mkdir(exist_ok=True)
    (generated / "FixtureEndpoint.swift").write_text(
        'enum FixtureEndpoint { static let baseURL = "http://127.0.0.1:%d" }\n' % server.server_port)
    run(["xcodegen", "generate", "--spec", str(EXAMPLE / "project.yml"), "--project", str(EXAMPLE)])
    devices = json.loads(capture(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
    candidate = next(( (runtime, d["deviceTypeIdentifier"]) for runtime, entries in devices.items()
        if ".iOS-" in runtime for d in entries if d.get("isAvailable") and d["name"].startswith("iPhone")), None)
    assert candidate, "No available iOS iPhone Simulator runtime"
    created = capture(["xcrun", "simctl", "create", "VoxAnnotation-" + uuid.uuid4().hex, candidate[1], candidate[0]])
    # Never inherit provider credentials or endpoints into the fixture test host.
    environment = {k: v for k, v in os.environ.items() if not k.startswith("VOX_") and not k.endswith("_API_KEY")}
    with tempfile.TemporaryDirectory(prefix="vox-annotation-ios-") as work:
        run(["xcodebuild", "test", "-project", str(EXAMPLE / "AnnotationSandbox.xcodeproj"),
             "-scheme", "AnnotationSandbox", "-destination", "platform=iOS Simulator,id=" + created,
             "-derivedDataPath", work + "/build", "-resultBundlePath", work + "/result.xcresult",
             "-parallel-testing-enabled", "NO"], env=environment)
    assert not failures, "Loopback vendor fixture rejected the upload contract: " + ",".join(failures)
    with lock: final = dict(state)
    assert final == dict(scoped=2, started=2, closedA=1, closedB=0, reflected=1, oversize=0), final
    print("PASS: real iOS app sandbox, scoped multipart uploads, private modes/cleanup, HTTP401 privacy and per-request HTTP cancellation")
finally:
    release.set()
    server.shutdown(); server.server_close()
    if created:
        subprocess.run(["xcrun", "simctl", "shutdown", created], capture_output=True)
        subprocess.run(["xcrun", "simctl", "delete", created], check=True)
