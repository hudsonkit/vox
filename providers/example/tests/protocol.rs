use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

struct Server {
    child: Child,
    lines: Receiver<Result<Value, String>>,
    reader: Option<JoinHandle<()>>,
    diagnostics: Option<JoinHandle<String>>,
}

impl Server {
    fn spawn(binary: &str, release: Option<&std::path::Path>) -> Self {
        let mut command = Command::new(binary);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(release) = release {
            command.env("VOX_TEST_RELEASE_FILE", release);
        }
        let mut child = command.spawn().unwrap();
        let stdout = child.stdout.take().unwrap();
        let mut stderr = child.stderr.take().unwrap();
        let (sender, lines) = mpsc::channel();
        let reader = thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let frame = line.map_err(|error| error.to_string()).and_then(|line| {
                    serde_json::from_str(&line)
                        .map_err(|error| format!("Non-protocol stdout: {line:?}: {error}"))
                });
                if sender.send(frame).is_err() {
                    break;
                }
            }
        });
        let diagnostics = thread::spawn(move || {
            let mut text = String::new();
            stderr.read_to_string(&mut text).unwrap();
            text
        });
        Self {
            child,
            lines,
            reader: Some(reader),
            diagnostics: Some(diagnostics),
        }
    }

    fn fixture(release: Option<&std::path::Path>) -> Self {
        Self::spawn(env!("CARGO_BIN_EXE_vox-provider-test-fixture"), release)
    }

    fn send(&mut self, value: Value) {
        self.raw(&format!("{value}\n"));
    }

    fn raw(&mut self, text: &str) {
        let stdin = self.child.stdin.as_mut().unwrap();
        stdin.write_all(text.as_bytes()).unwrap();
        stdin.flush().unwrap();
    }

    fn next(&self) -> Value {
        self.lines
            .recv_timeout(Duration::from_secs(5))
            .expect("provider response before timeout")
            .unwrap()
    }

    fn response(&self, id: Value) -> Value {
        loop {
            let frame = self.next();
            if frame.get("id").is_some() {
                assert_eq!(frame["id"], id);
                return frame;
            }
            assert_eq!(frame["method"], "progress");
            assert!(frame["params"]["progress"].as_f64().unwrap() <= 1.0);
        }
    }

    fn finish(mut self) -> String {
        self.child.stdin.take();
        let start = Instant::now();
        let status = loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                break status;
            }
            assert!(
                start.elapsed() < Duration::from_secs(5),
                "provider failed to exit after EOF"
            );
            thread::sleep(Duration::from_millis(5));
        };
        self.reader.take().unwrap().join().unwrap();
        if let Some(frame) = self.lines.try_iter().next() {
            panic!(
                "Unexpected stdout after final response: {:?}",
                frame.unwrap()
            );
        }
        let diagnostics = self.diagnostics.take().unwrap().join().unwrap();
        assert!(status.success(), "provider exited {status}: {diagnostics}");
        diagnostics
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }
}

fn request(id: u64, method: &str, params: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})
}

#[test]
fn malformed_requests_recover_and_native_logs_never_enter_stdout() {
    let mut server = Server::fixture(None);
    for raw in [
        "{broken\n",
        "{\"jsonrpc\":\"2.0\",\"id\":1e999,\"method\":\"models\"}\n",
        "{\"jsonrpc\":\"2.0\",\"id\":\"\\ud800\",\"method\":\"models\"}\n",
    ] {
        server.raw(raw);
        let response = server.response(Value::Null);
        assert_eq!(response["error"]["code"], -32700);
    }
    server.send(json!({"jsonrpc":"2.0","id":true,"method":"models"}));
    assert_eq!(server.response(Value::Null)["error"]["code"], -32600);
    server.send(json!({"jsonrpc":"2.0","id":"unknown","method":"unknown"}));
    assert_eq!(server.response(json!("unknown"))["error"]["code"], -32601);
    server.send(request(1, "transcribe", json!({"path":"x"})));
    assert_eq!(server.response(json!(1))["error"]["code"], -32602);
    // Unknown notifications have no response and do not take admission.
    server.send(json!({"jsonrpc":"2.0","method":"unknown"}));
    server.send(request(2, "models", json!({})));
    assert_eq!(
        server.response(json!(2))["result"]["models"][0]["id"],
        "fixture"
    );
    let logs = server.finish();
    for message in [
        "rust diagnostic",
        "native diagnostic",
        "buffered native diagnostic",
        "fixture shutdown",
    ] {
        assert!(
            logs.contains(message),
            "missing stderr message {message:?}: {logs}"
        );
    }
}

#[test]
fn overlapping_request_is_busy_and_eof_drains_the_accepted_operation() {
    let directory = tempfile::tempdir().unwrap();
    let release = directory.path().join("release");
    let mut server = Server::fixture(Some(&release));
    server.send(request(1, "preload", json!({"modelId":"fixture"})));
    let progress = server.next();
    assert_eq!(progress["method"], "progress");
    assert_eq!(progress["params"]["progress"], 0.25);
    server.send(request(2, "models", json!({})));
    // The worker cannot complete until the test writes the release file.
    assert_eq!(server.response(json!(2))["error"]["code"], -32001);
    server.child.stdin.take();
    std::fs::write(&release, b"ready").unwrap();
    assert_eq!(
        server.response(json!(1))["result"]["model"]["preloaded"],
        true
    );
    assert!(server.finish().contains("fixture shutdown"));
}

#[test]
fn broken_stdout_stops_the_host_while_stdin_remains_open() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_vox-provider-test-fixture"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    // Keep stdin open for the entire wait. Nothing can unblock its read except
    // the worker failure after trying to write to the closed protocol pipe.
    drop(child.stdout.take());
    let mut input = child.stdin.take().unwrap();
    writeln!(input, "{}", request(1, "models", json!({}))).unwrap();
    input.flush().unwrap();
    let start = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if start.elapsed() >= Duration::from_secs(5) {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("provider waited for stdin after its output pipe broke");
        }
        thread::sleep(Duration::from_millis(5));
    };
    assert!(!status.success());
    let mut diagnostics = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut diagnostics)
        .unwrap();
    assert!(diagnostics.contains("fixture shutdown"), "{diagnostics}");
    assert!(diagnostics.contains("BrokenPipe"), "{diagnostics}");
    drop(input);
}

#[test]
fn provider_errors_panics_and_invalid_results_leave_host_responsive() {
    let mut server = Server::fixture(None);
    for (id, path, code) in [
        (1, "error", 6),
        (2, "panic", -32603),
        (3, "nonfinite", -32603),
    ] {
        server.send(request(
            id,
            "transcribe",
            json!({"modelId":"fixture","path":path}),
        ));
        assert_eq!(server.response(json!(id))["error"]["code"], code);
    }
    server.send(request(4, "install", json!({"modelId":"fixture"})));
    assert_eq!(server.response(json!(4))["error"]["code"], 12);
    server.send(request(5, "models", json!({})));
    assert_eq!(
        server.response(json!(5))["result"]["models"][0]["id"],
        "fixture"
    );
    assert!(server.finish().contains("fixture panic"));
}

#[test]
fn example_requires_explicit_lifecycle_and_reuses_warm_state() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("audio.wav");
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: 16000,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut wav = hound::WavWriter::create(&path, spec).unwrap();
    for _ in 0..16000 {
        wav.write_sample(0_i16).unwrap();
    }
    wav.finalize().unwrap();
    let mut server = Server::spawn(env!("CARGO_BIN_EXE_vox-provider-example"), None);
    server.send(request(1, "models", json!({})));
    let model = server.response(json!(1))["result"]["models"][0].clone();
    assert_eq!(model["installed"], false);
    assert_eq!(model["preloaded"], false);
    server.send(request(2, "preload", json!({"modelId":"template:echo"})));
    assert_eq!(server.response(json!(2))["error"]["code"], 12);
    server.send(request(
        3,
        "transcribe",
        json!({"modelId":"template:echo","path":path}),
    ));
    assert_eq!(server.response(json!(3))["error"]["code"], 12);
    server.send(request(4, "install", json!({"modelId":"template:echo"})));
    assert_eq!(
        server.response(json!(4))["result"]["model"]["installed"],
        true
    );
    server.send(request(5, "preload", json!({"modelId":"template:echo"})));
    assert_eq!(
        server.response(json!(5))["result"]["model"]["preloaded"],
        true
    );
    server.send(request(
        6,
        "transcribe",
        json!({"modelId":"unknown","path":path}),
    ));
    assert_eq!(server.response(json!(6))["error"]["code"], -32602);
    let invalid = directory.path().join("invalid.wav");
    std::fs::write(&invalid, b"not a wav").unwrap();
    for (id, bad_path) in [
        (7, invalid),
        (8, directory.path().join("missing.wav")),
        (9, directory.path().to_path_buf()),
    ] {
        server.send(request(
            id,
            "transcribe",
            json!({"modelId":"template:echo","path":bad_path}),
        ));
        assert_eq!(server.response(json!(id))["error"]["code"], 6);
    }
    let mut trace_ids = Vec::new();
    for id in 10..12 {
        server.send(request(
            id,
            "transcribe",
            json!({"modelId":"template:echo","path":path}),
        ));
        let result = server.response(json!(id))["result"].clone();
        assert!(result["text"].as_str().unwrap().starts_with("[echo] "));
        assert_eq!(result["metrics"]["audioDurationMs"], 1000);
        assert_eq!(result["metrics"]["wasPreloaded"], true);
        assert_eq!(result["metrics"]["modelLoadMs"], 0);
        assert_eq!(
            result["metrics"]["inputBytes"],
            std::fs::metadata(&path).unwrap().len()
        );
        assert!(result["elapsedMs"].is_u64());
        trace_ids.push(result["metrics"]["traceId"].clone());
    }
    assert_ne!(trace_ids[0], trace_ids[1]);
    server.send(request(12, "models", json!({})));
    assert_eq!(
        server.response(json!(12))["result"]["models"][0]["preloaded"],
        true
    );
    server.finish();
}
