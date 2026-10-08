//! A persistent, typed host for external Vox ASR providers.
//!
//! The host owns protocol framing and bounded admission. A single worker owns
//! every provider call, including shutdown. An overlapping request receives
//! `-32001` immediately; no operations wait in a hidden queue. EOF drains the one
//! accepted operation before shutdown. Installation and preload stay explicit.
//!
//! [`serve`] reserves the original stdout pipe for JSON-RPC and redirects the
//! stdout descriptor to stderr, including native-library writes. Call it before
//! initializing a native runtime; load weights in the provider lifecycle methods.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::fmt;
use std::io::{self, BufRead, Write};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;

pub const BUSY: i64 = -32001;
pub const MAX_REQUEST_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub backend: String,
    pub installed: bool,
    pub preloaded: bool,
    pub available: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptionMetrics {
    pub trace_id: String,
    pub audio_duration_ms: u64,
    pub input_bytes: u64,
    pub was_preloaded: bool,
    pub file_check_ms: u64,
    pub model_check_ms: u64,
    pub model_load_ms: u64,
    pub audio_load_ms: u64,
    pub audio_prepare_ms: u64,
    pub inference_ms: u64,
    pub total_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WordTiming {
    pub word: String,
    pub start: f64,
    pub end: f64,
    pub confidence: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Transcription {
    pub model_id: String,
    pub text: String,
    pub elapsed_ms: u64,
    pub metrics: TranscriptionMetrics,
    pub words: Vec<WordTiming>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ProviderError {
    pub code: i64,
    pub message: String,
}

impl ProviderError {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl fmt::Display for ProviderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{} ({})", self.message, self.code)
    }
}

impl std::error::Error for ProviderError {}

/// Emit a fraction in `[0, 1]` and a status such as `loading` or `ready`.
pub type Progress<'a> = dyn FnMut(f64, &str) -> Result<(), ProviderError> + 'a;

pub trait AsrProvider: Send + 'static {
    fn models(&mut self) -> Result<Vec<ModelInfo>, ProviderError>;
    fn install(
        &mut self,
        model_id: &str,
        progress: &mut Progress<'_>,
    ) -> Result<ModelInfo, ProviderError>;
    fn preload(
        &mut self,
        model_id: &str,
        progress: &mut Progress<'_>,
    ) -> Result<ModelInfo, ProviderError>;
    fn transcribe(&mut self, path: &Path, model_id: &str) -> Result<Transcription, ProviderError>;

    /// Runs on the provider worker after EOF and the accepted operation finish.
    fn shutdown(&mut self) -> Result<(), ProviderError> {
        Ok(())
    }
}

enum Method {
    Models,
    Install(String),
    Preload(String),
    Transcribe { path: PathBuf, model_id: String },
}

struct Request {
    // None is a notification; Some(Null) is a request with an explicit null id.
    id: Option<Value>,
    method: Method,
}

fn error_response(id: Value, code: i64, message: impl Into<String>) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message.into()}})
}

fn write_message<W: Write>(output: &Mutex<W>, message: &Value) -> io::Result<()> {
    let mut frame = serde_json::to_vec(message)?;
    frame.push(b'\n');
    let mut writer = output.lock().unwrap_or_else(|poison| poison.into_inner());
    writer.write_all(&frame)?;
    writer.flush()
}

// An invalid notification has no response; an invalid envelope always does.
fn parse_request(value: Value) -> Result<Request, Option<Value>> {
    let invalid = || {
        Some(error_response(
            Value::Null,
            -32600,
            "Invalid JSON-RPC 2.0 request",
        ))
    };
    let object = value.as_object().ok_or_else(invalid)?;
    let id = object.get("id").cloned();
    if object.get("jsonrpc").and_then(Value::as_str) != Some("2.0")
        || !object.get("method").is_some_and(Value::is_string)
        || id
            .as_ref()
            .is_some_and(|id| !(id.is_null() || id.is_string() || id.is_number()))
    {
        return Err(invalid());
    }
    let reject = |code, message: String| id.clone().map(|id| error_response(id, code, message));
    let method = object["method"].as_str().expect("method validated");
    if !matches!(method, "models" | "install" | "preload" | "transcribe") {
        return Err(reject(-32601, format!("Unknown method: {method}")));
    }
    let empty = Map::new();
    let params = match object.get("params") {
        Some(params) => params
            .as_object()
            .ok_or_else(|| reject(-32602, "params must be an object".into()))?,
        None => &empty,
    };
    let string_param = |key: &str| -> Result<String, Option<Value>> {
        params
            .get(key)
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty() && !value.contains('\0'))
            .map(str::to_owned)
            .ok_or_else(|| reject(-32602, format!("{key} must be a non-empty string")))
    };
    let method = match method {
        "models" => Method::Models,
        "install" => Method::Install(string_param("modelId")?),
        "preload" => Method::Preload(string_param("modelId")?),
        "transcribe" => Method::Transcribe {
            model_id: string_param("modelId")?,
            path: PathBuf::from(string_param("path")?),
        },
        _ => unreachable!(),
    };
    Ok(Request { id, method })
}

fn invoke<P: AsrProvider, W: Write>(
    provider: &mut P,
    method: &Method,
    output: &Mutex<W>,
) -> Result<Value, ProviderError> {
    match method {
        Method::Models => Ok(json!({"models": provider.models()?})),
        Method::Install(model_id) | Method::Preload(model_id) => {
            let mut progress = |fraction: f64, status: &str| {
                if !fraction.is_finite() || !(0.0..=1.0).contains(&fraction) {
                    return Err(ProviderError::new(
                        -32603,
                        "Progress must be a finite fraction in [0, 1]",
                    ));
                }
                write_message(
                    output,
                    &json!({
                        "jsonrpc": "2.0", "method": "progress",
                        "params": {"modelId": model_id, "progress": fraction, "status": status}
                    }),
                )
                .map_err(|error| {
                    ProviderError::new(-32603, format!("Cannot write progress: {error}"))
                })
            };
            let model = match method {
                Method::Install(_) => provider.install(model_id, &mut progress)?,
                _ => provider.preload(model_id, &mut progress)?,
            };
            Ok(json!({"model": model}))
        }
        Method::Transcribe { path, model_id } => {
            let transcription = provider.transcribe(path, model_id)?;
            if transcription.words.iter().any(|word| {
                !word.start.is_finite() || !word.end.is_finite() || !word.confidence.is_finite()
            }) {
                return Err(ProviderError::new(
                    -32603,
                    "Provider returned non-finite word timing",
                ));
            }
            serde_json::to_value(transcription)
                .map_err(|error| ProviderError::new(-32603, error.to_string()))
        }
    }
}

enum Line {
    End,
    Data,
    Oversized,
}

fn read_line<R: BufRead>(input: &mut R, line: &mut Vec<u8>) -> io::Result<Line> {
    line.clear();
    let mut oversized = false;
    let mut saw_bytes = false;
    loop {
        let bytes = input.fill_buf()?;
        if bytes.is_empty() {
            return Ok(if oversized {
                Line::Oversized
            } else if saw_bytes {
                Line::Data
            } else {
                Line::End
            });
        }
        saw_bytes = true;
        let newline = bytes.iter().position(|byte| *byte == b'\n');
        let count = newline.map_or(bytes.len(), |index| index + 1);
        if !oversized && line.len() + count <= MAX_REQUEST_BYTES {
            line.extend_from_slice(&bytes[..count]);
        } else {
            oversized = true;
        }
        input.consume(count);
        if newline.is_some() {
            return Ok(if oversized {
                Line::Oversized
            } else {
                Line::Data
            });
        }
    }
}

/// Serve custom streams without changing process file descriptors.
///
/// Useful for tests and embedding a transport. Only [`serve`] isolates stdout.
/// Custom blocking readers must reach EOF or return an error when their
/// transport closes. [`serve`] also wakes stdin when its worker exits.
pub fn serve_io<P: AsrProvider, R: BufRead, W: Write + Send + 'static>(
    provider: P,
    input: R,
    output: W,
) -> io::Result<()> {
    serve_io_inner(provider, input, output, || {})
}

struct OnWorkerExit<F: FnOnce()>(Option<F>);

impl<F: FnOnce()> Drop for OnWorkerExit<F> {
    fn drop(&mut self) {
        if let Some(notify) = self.0.take() {
            notify();
        }
    }
}

fn serve_io_inner<
    P: AsrProvider,
    R: BufRead,
    W: Write + Send + 'static,
    F: FnOnce() + Send + 'static,
>(
    mut provider: P,
    mut input: R,
    output: W,
    on_worker_exit: F,
) -> io::Result<()> {
    let output = Arc::new(Mutex::new(output));
    let busy = Arc::new(Mutex::new(false));
    let (sender, receiver) = mpsc::sync_channel::<Request>(1);
    let worker_output = output.clone();
    let worker_busy = busy.clone();
    let worker = thread::Builder::new()
        .name("vox-provider".into())
        .spawn(move || {
            // Also notify on an unexpected panic outside the adapter boundary.
            let _exit = OnWorkerExit(Some(on_worker_exit));
            let work_result = (|| {
                for request in receiver {
                    let result = catch_unwind(AssertUnwindSafe(|| {
                        invoke(&mut provider, &request.method, &worker_output)
                    }))
                    .unwrap_or_else(|_| {
                        Err(ProviderError::new(
                            -32603,
                            "Provider operation panicked; see stderr",
                        ))
                    });
                    // Publish the response and release admission together. A caller
                    // that immediately sends its next request will observe idle.
                    let mut busy = worker_busy
                        .lock()
                        .unwrap_or_else(|poison| poison.into_inner());
                    let sent = if let Some(id) = request.id {
                        let response = match result {
                            Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
                            Err(error) => error_response(id, error.code, error.message),
                        };
                        write_message(&worker_output, &response)
                    } else {
                        Ok(())
                    };
                    *busy = false;
                    sent?;
                }
                Ok(())
            })();
            let shutdown_result = catch_unwind(AssertUnwindSafe(|| provider.shutdown()))
                .unwrap_or_else(|_| Err(ProviderError::new(-32603, "Provider shutdown panicked")))
                .map_err(io::Error::other);
            work_result.and(shutdown_result)
        })?;

    let input_result = (|| {
        let mut line = Vec::new();
        loop {
            match read_line(&mut input, &mut line)? {
                Line::End => break,
                Line::Oversized => {
                    write_message(
                        &output,
                        &error_response(Value::Null, -32600, "Request exceeds 1 MiB"),
                    )?;
                    continue;
                }
                Line::Data => {}
            }
            if line.iter().all(u8::is_ascii_whitespace) {
                continue;
            }
            let value = match serde_json::from_slice(&line) {
                Ok(value) => value,
                Err(_) => {
                    write_message(
                        &output,
                        &error_response(Value::Null, -32700, "Invalid JSON"),
                    )?;
                    continue;
                }
            };
            let request = match parse_request(value) {
                Ok(request) => request,
                Err(response) => {
                    if let Some(response) = response {
                        write_message(&output, &response)?;
                    }
                    continue;
                }
            };
            let mut active = busy.lock().unwrap_or_else(|poison| poison.into_inner());
            if *active {
                if let Some(id) = request.id {
                    write_message(
                        &output,
                        &error_response(
                            id,
                            BUSY,
                            "Provider busy; retry after the active request completes",
                        ),
                    )?;
                }
                continue;
            }
            *active = true;
            if sender.send(request).is_err() {
                *active = false;
                return Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "Provider worker stopped",
                ));
            }
        }
        Ok(())
    })();
    // Closing admission drains the one accepted call and runs shutdown on its
    // owning thread. Native inference is never cancelled unsafely.
    drop(sender);
    let worker_result = worker
        .join()
        .unwrap_or_else(|_| Err(io::Error::other("Provider worker panicked")));
    // Preserve the original worker failure when it caused input to wake.
    worker_result.and(input_result)
}

#[cfg(unix)]
mod stdio {
    use std::fs::File;
    use std::io::{self, Read, Write};
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::os::unix::net::UnixStream;

    /// The worker owns the other socket endpoint. Its closure wakes poll even
    /// if stdin is still open and no more requests will arrive.
    pub struct Stdin {
        worker_exit: UnixStream,
    }

    impl Stdin {
        pub fn new() -> io::Result<(Self, UnixStream)> {
            let (worker_exit, notify) = UnixStream::pair()?;
            Ok((Self { worker_exit }, notify))
        }
    }

    impl Read for Stdin {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            if buffer.is_empty() {
                return Ok(0);
            }
            let mut descriptors = [
                libc::pollfd {
                    fd: libc::STDIN_FILENO,
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: self.worker_exit.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            loop {
                let ready = unsafe { libc::poll(descriptors.as_mut_ptr(), 2, -1) };
                if ready < 0 {
                    let error = io::Error::last_os_error();
                    if error.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(error);
                }
                if descriptors[1].revents != 0 {
                    return Err(io::Error::new(
                        io::ErrorKind::BrokenPipe,
                        "Provider worker stopped",
                    ));
                }
                if descriptors[0].revents != 0 {
                    let count = unsafe {
                        libc::read(libc::STDIN_FILENO, buffer.as_mut_ptr().cast(), buffer.len())
                    };
                    if count >= 0 {
                        return Ok(count as usize);
                    }
                    let error = io::Error::last_os_error();
                    if error.kind() != io::ErrorKind::Interrupted {
                        return Err(error);
                    }
                }
            }
        }
    }

    pub struct ProtocolStdout {
        saved: File,
    }

    impl ProtocolStdout {
        pub fn isolate() -> io::Result<Self> {
            io::stdout().flush()?;
            let fd = unsafe { libc::dup(libc::STDOUT_FILENO) };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            let saved = unsafe { File::from_raw_fd(fd) };
            if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
                return Err(io::Error::last_os_error());
            }
            if unsafe { libc::dup2(libc::STDERR_FILENO, libc::STDOUT_FILENO) } < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(Self { saved })
        }

        pub fn writer(&self) -> io::Result<File> {
            self.saved.try_clone()
        }
    }

    impl Drop for ProtocolStdout {
        fn drop(&mut self) {
            let _ = io::stdout().flush();
            unsafe {
                // Flush C stdio before restoring stdout, so buffered native
                // diagnostics cannot leak into the protocol on process exit.
                libc::fflush(std::ptr::null_mut());
                libc::dup2(self.saved.as_raw_fd(), libc::STDOUT_FILENO);
            }
        }
    }
}

/// Serve stdin/stdout until EOF, isolating Rust and native diagnostics on Unix.
#[cfg(unix)]
pub fn serve<P: AsrProvider>(provider: P) -> io::Result<()> {
    let protocol = stdio::ProtocolStdout::isolate()?;
    let (input, worker_exit) = stdio::Stdin::new()?;
    serve_io_inner(
        provider,
        io::BufReader::new(input),
        protocol.writer()?,
        || drop(worker_exit),
    )
}

#[cfg(not(unix))]
pub fn serve<P: AsrProvider>(_provider: P) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "Vox provider stdout isolation requires Unix",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn envelope_and_parameter_validation_preserve_request_ids() {
        for value in [
            json!([]),
            json!(null),
            json!({"jsonrpc":"1.0","id":1,"method":"models"}),
            json!({"jsonrpc":"2.0","id":true,"method":"models"}),
        ] {
            let error = parse_request(value).err().flatten().unwrap();
            assert_eq!(error["id"], Value::Null);
            assert_eq!(error["error"]["code"], -32600);
        }
        let error = parse_request(json!({"jsonrpc":"2.0","id":"x","method":"transcribe","params":{"modelId":"x","path":"a\0b"}})).err().flatten().unwrap();
        assert_eq!(error["id"], "x");
        assert_eq!(error["error"]["code"], -32602);
        assert!(parse_request(json!({"jsonrpc":"2.0","method":"missing"}))
            .err()
            .unwrap()
            .is_none());
    }

    #[test]
    fn bounded_framing_drains_oversized_input_and_accepts_final_line() {
        let mut bytes = vec![b'x'; MAX_REQUEST_BYTES + 100];
        bytes.extend_from_slice(b"\n{\"method\":\"models\"}");
        let mut input = Cursor::new(bytes);
        let mut line = Vec::new();
        assert!(matches!(
            read_line(&mut input, &mut line).unwrap(),
            Line::Oversized
        ));
        assert!(line.len() <= MAX_REQUEST_BYTES);
        assert!(matches!(
            read_line(&mut input, &mut line).unwrap(),
            Line::Data
        ));
        assert_eq!(line, br#"{"method":"models"}"#);
        assert!(matches!(
            read_line(&mut input, &mut line).unwrap(),
            Line::End
        ));
    }

    #[test]
    fn serialized_models_and_metrics_match_swift_contract() {
        let metrics = TranscriptionMetrics {
            model_load_ms: 42,
            was_preloaded: true,
            ..Default::default()
        };
        let value = serde_json::to_value(metrics).unwrap();
        assert_eq!(value["modelLoadMs"], 42);
        assert_eq!(value["wasPreloaded"], true);
        assert!(value["inferenceMs"].is_u64());
        assert!(value["totalMs"].is_u64());
    }
}
