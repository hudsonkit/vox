---
title: Runtime
description: Companion request flow, warm-up, sessions, routes, ports, and runtime ownership boundaries.
---

## Core Flow

1. A companion-connected client connects to `voxd` over local WebSocket JSON-RPC, or reaches it indirectly through the local HTTP bridge.
2. The runtime resolves health, model state, and optional warm-up state.
3. The client triggers file transcription, file annotation, a live ASR session, one-shot synthesis, or a synthesis session.
4. `VoxEngine` resolves the right ASR, annotation, or TTS provider and returns transcript text, speaker attribution, word timings, or WAV bytes plus stage metrics.
5. The runtime records a tagged performance sample to `~/.vox/performance.jsonl`.
6. The daemon appends operational logs to `~/.vox/logs/voxd.log`.

## Warm-Up

Warm-up is a public API, not a hidden side effect. It applies to both ASR and TTS models.

- `warmup.status` -- check if the model is hot
- `warmup.start` -- warm immediately
- `warmup.schedule` -- warm after a delay

Typical pattern: create a `VoxClient` with a stable `clientId`, warm when the user opens a voice affordance, then transcribe or synthesize once the model is ready.

The ASR model itself is never embedded in the Swift product. Automatic
acquisition for live transcription is controlled by
`VoxSpeechPreferences.modelDownloadPolicy`:

| Value | Behavior |
|-------|----------|
| `never` | Never download automatically. Live transcription requires an already-installed model or an explicit install/warm-up request. |
| `on_first_use` | Start warm-up with the first live transcription session. This is the default. |
| `eager` | Start warm-up when `voxd` starts. |

The explicit `models.install`, `models.preload`, and `warmup.*` routes remain
available under every policy; choosing one of those routes is itself an
operator/user request to acquire the model.

## File Transcription

`transcribe.file` is best for benchmarks because it takes mic capture out of the measurement. Returns transcript text, word-level timestamps, `modelId`, elapsed time, and stage metrics.

Native Parakeet batch `words` are SentencePiece/whitespace-delimited word groups,
with punctuation attached as it appears in the decoded text. Older revisions
incorrectly returned individual BPE pieces in this array. A group's start/end
cover the minimum start and maximum end of its contributing model-token
intervals; `confidence` is the minimum piece confidence, not a calibrated word
posterior. Timings remain TDT decoder-frame estimates (80 ms frames), not forced
alignment or exact acoustic boundaries. Multiword pieces share their source
interval rather than receiving invented subdivisions. Language-specific
linguistic segmentation is not inferred beyond the model's whitespace markers.
Missing vocabulary entries do not invent labels; incomplete alignment arrays
return no timings rather than silently losing the tail or fabricating data.
The same grouping runs after long-file chunk merging.


## File Annotation

`annotate.file` uploads a finalized media file to an explicitly selected cloud
annotation model. The default `AnnotationManager` now routes these IDs:

| Vox model ID | Vendor model | Request credential | Audio events |
|---|---|---|---|
| `elevenlabs:scribe_v2` | `scribe_v2` | `ELEVENLABS_API_KEY` | Supported |
| `deepgram:nova-3` | `nova-3`, diarization `v2` | `DEEPGRAM_API_KEY` | Unsupported |

Call `annotation.models` for capability metadata. Inventory does not authenticate
an account. There is no implicit cloud default, ambient credential lookup, native
ASR fallback, or cross-request account cache. The old `speaker-diarization:v1`
placeholder errors with `annotation_model_required`. Native dictation and batch
ASR remain separate from these cloud file providers.

The authenticated private JSON-RPC request is:

```json
{
  "method": "annotate.file",
  "params": {
    "clientId": "meeting-app",
    "path": "/path/to/finalized-meeting.wav",
    "modelId": "elevenlabs:scribe_v2",
    "credentials": {"ELEVENLABS_API_KEY": "<request-scoped-key>"},
    "diarize": true,
    "tagAudioEvents": true,
    "languageCode": "eng",
    "numSpeakers": 2
  }
}
```

`diarize` defaults to true. `tagAudioEvents` defaults to true for Scribe and false
for Deepgram; explicitly requesting Deepgram events errors before upload.
`languageCode` is optional: Scribe accepts ISO 639-1/639-3 codes; Deepgram accepts
language/region codes or `multi`. It is a hint, never reported as detected language
unless the vendor actually returns it. `numSpeakers` is a Scribe-only 1–32 hint
and requires diarization. Cloud providers reject supplied `text`/`words` alignment
hints. Custom injected providers can still implement that legacy contract.

`VoxDaemonClient.listAnnotationModels()` returns `[AnnotationModelInfo]`.
`annotateFile(path:modelId:credentials:diarize:tagAudioEvents:languageCode:numSpeakers:timeout:)`
returns `AnnotationOutput`; its timeout defaults to 3600 seconds. Both methods
remain in the model-free `VoxClient` product. The TypeScript companion client
exposes `listAnnotationModels()` and `annotateFile(path, options)` with an explicit
`modelId`, optional `credentials`, these same options and `timeoutMs`.

### Annotation evidence and limits

- Word and event times are seconds from the file start. Missing or invalid word
  times fail, rather than becoming zero. Speaker IDs remain vendor IDs: Scribe
  strings are unchanged; Deepgram integers become decimal strings such as `"0"`.
- `words.confidence` and `words.speakerConfidence` are nullable. Scribe supplies
  raw `logProbability`, not a calibrated confidence; Vox does not exponentiate it.
  Deepgram preserves returned word and speaker confidence. Missing scores stay null.
- `audioEvents` contains Scribe's timed `audio_event` labels, separate from speech
  words. Vox ignores spacing tokens. Deepgram has no supported audio-event output.
- Scribe speaker spans derive from contiguous attributed words. Deepgram uses
  returned utterance spans, or derives spans from words when absent.
  `speakerSegmentsSource` distinguishes `vendor-utterances` and `word-span-derived`.
  Derived spans have no invented confidence; utterance transcription confidence
  is not speaker confidence. These spans are not acoustic VAD or speaker identity.
- Deepgram multilingual `languages` come from the selected alternative; per-word
  `words.language` is preserved when supplied. Vox never substitutes the first
  language for an absent detected-language field.
- `language`, `languageConfidence`, `languages`, `providerRequestId` and
  `providerModelIds` preserve vendor evidence. Missing IDs stay null/empty, not
  locally generated vendor identifiers. `unsupportedFields` names provider limits;
  `unavailableFields` names supported fields absent from this response.
- `duration` uses vendor duration, else readable local media metadata;
  `durationSource` is `vendor` or `media-file`. Neither is asserted to be billed
  duration. Unknown duration errors with `annotation_duration_unavailable` rather
  than inventing zero or using the last word's end.
- Vox limits input to 2,000,000,000 bytes and two active annotation requests. An
  additional request errors busy. Upload preparation copies in 64 KiB chunks to an
  owner-only temporary file, removed on completion/error/cancellation. No upload
  or response cache is kept. Successful performance samples contain routing and
  stage metrics, not keys, media, transcript text or vendor responses.
- HTTP responses are bounded to 4 MiB and encoded results to 8 MiB. Excess fails
  explicitly. Redirects are refused; Vox does not implement retries. HTTP errors
  expose status only, never vendor error bodies that could echo credentials.
- Cancel a Swift client task or disconnect its client to cancel that connection's
  in-flight uploads and response waits. Other clients are unaffected. No per-file
  cancel RPC or vendor cancellation guarantee exists. Already accepted vendor work
  can continue or incur charges. Upload and vendor retention require user consent;
  Vox does not promise the vendor's zero-retention mode or modify account settings.

The provider runs in Swift inside `voxd`, not a new external ASR process provider.
It implements the existing native annotation contract and does not introduce a
Python, MLX, FluidAudio, or Rust process in the native dictation path.
Host-only `VOX_ANNOTATION_ELEVENLABS_URL` and `VOX_ANNOTATION_DEEPGRAM_URL` can
override complete endpoints for testing/deployment. They accept HTTPS, or HTTP
loopback only, without URL credentials, queries or fragments. Invalid explicit
overrides fail closed. Clients cannot set these endpoints over RPC. A host owner
who overrides an endpoint controls where that provider's request key is sent.

Contract sources: [Scribe conversion API](https://elevenlabs.io/docs/api-reference/speech-to-text/convert)
and [Deepgram prerecorded API](https://developers.deepgram.com/reference/speech-to-text/listen-pre-recorded),
including [Nova-3 multilingual response fields](https://developers.deepgram.com/docs/nova-3-language-prompting).
Fixture tests validate routing and schema preservation, not paid-account access,
real audio accuracy, vendor retention or production vendor availability.

## Synthesis

`synthesize.voices` lists available voices for a TTS model.

`synthesize.generate` returns:

- `modelId`
- `voiceId`
- `format`
- `contentType`
- base64-encoded audio bytes
- elapsed time
- synthesis metrics

Longer-running output flows use:

- `synthesize.startSession`
- `synthesize.sessionStatus`
- `synthesize.cancel`

### Scoped ElevenLabs generation and voices

Send an explicit `modelId`, `voiceId` and `credentials: { "ELEVENLABS_API_KEY": key }`
to `synthesize.generate` or `synthesize.startSession`. The key belongs to that
request. It is not stored in provider configuration, the process environment,
history or credential files. Request keys override configured keys; an invalid
selected key fails instead of retrying another account.

`synthesize.voices` accepts the same credentials with an explicit ElevenLabs
`modelId`, so account-specific voices use the selected account. OpenAI's static
voice list also accepts scoped credentials. Unsupported built-in scoped voice discovery
returns an error instead of silently using daemon credentials. Do not place keys
in voice-list HTTP query strings; this is a companion RPC capability.

Swift `VoxClient` callers use `call(_:params:timeout:onProgress:)` with these JSON
parameters. No inference-engine linkage is required. TTS inventories describe
daemon-configured availability; supplying a key does not change global defaults
or inventory. See [provider rules and output-format requirements](./providers.md).

## RPC Routes

The runtime exposes these RPC routes:

- `transcribe.file`
- `annotate.file`
- `transcribe.startSession`
- `transcribe.sessionStatus`
- `transcribe.stopSession`
- `transcribe.cancelSession`
- `synthesize.voices`
- `synthesize.generate`
- `synthesize.startSession`
- `synthesize.sessionStatus`
- `synthesize.cancel`
- `models.list`
- `models.install`
- `models.preload`
- `models.catalog`
- `models.refreshCatalog`
- `warmup.status`
- `warmup.start`
- `warmup.schedule`

`models.catalog` returns the published dictation catalog, including `plugins[]`. Plugin install is `vox plugins install`, not an RPC. `voxd` loads `~/.vox/plugins/*/provider.json` at start. See [Models and plugins](./models.md).

## Performance routes

These are the route values currently emitted into `performance.jsonl`:

- `transcribe.file`
- `annotate.file`
- `transcribe.live`
- `synthesize.generate`
- `synthesize.startSession`

Cancelled synthesis sessions are currently recorded as `synthesize.startSession` with `outcome: "cancelled"`.

## Live Sessions

Speech sessions are coordinated in `VoxService`. Session ownership ties to both `connectionID` and `clientId`. Stop and cancel are distinct operations. Final transcript events include metrics and word-level timestamps. Synthesis session status includes the selected model and voice. Active session state is inspectable for operator recovery.

## Private local transport

A host app can construct `VoxRuntimeService` or `ServiceBridge` with `socketPath` and a nonempty `authToken`. This mode opens a Unix socket and does not open a TCP listener. Existing constructors without `socketPath` retain their TCP behavior.

The socket directory must be owned by the current user. The runtime creates it with mode `0700`, creates the socket with mode `0600`, rejects symlink paths, and checks the connected peer UID. Clients must send `x-lattices-token` during WebSocket upgrade. The server rejects browser `Origin` headers, invalid `Host` headers, duplicate headers, and unauthorized upgrades before RPC dispatch. Use `Host: localhost` and request path `/`.

Private connections retain the same JSON-RPC methods, events, and connection ownership. The transport limits incoming frames to 16 MiB and queued output to 32 MiB. The runtime registry reports `port: 0` and `socketPath` for a private endpoint. `VoxRuntimeService` publishes the owner-only capability described below. A raw `ServiceBridge` host can publish it with `PrivateRuntimeRegistration`. The TypeScript TCP client/CLI refuse private capabilities; TCP and browser deployments retain their explicit TCP configuration.

## Configuration

Ports and bind address are configurable via environment variables.

Vox uses two named companion ports:

| Role | Default | Transport | Env var | Stored |
|------|---------|-----------|---------|--------|
| `companion-ws` | `42137` | WebSocket | `VOX_PORT` | `runtime.json` |
| `companion-http` | `43115` | HTTP | `VOX_BRIDGE_PORT` | process/env only |

`companion-ws` is the `voxd` daemon port that `@voxd/sdk` discovers through `~/.vox/runtime.json`. `companion-http` is the browser-facing bridge port used by `@voxd/client`.

The bind host is shared across both surfaces:

| Variable | Default | Description |
|----------|---------|-------------|
| `VOX_PORT` | `42137` | `companion-ws` daemon WebSocket port |
| `VOX_BRIDGE_PORT` | `43115` | `companion-http` bridge port |
| `VOX_HOST` | `127.0.0.1` | Bind address for both services |
| `VOX_HOME` | `~/.vox` | Runtime data directory |

CLI flag `--port` takes precedence over env vars for both `voxd` and `voxbridge`.

## Important Swift entry points

- `swift/Sources/voxd/main.swift`
- `swift/Sources/VoxService/VoxRuntimeService.swift`
- `swift/Sources/VoxService/LiveSessionCoordinator.swift`
- `swift/Sources/VoxService/SynthesisSessionCoordinator.swift`
- `swift/Sources/VoxService/WarmupCoordinator.swift`
- `swift/Sources/HudsonSpeechEngine/ProviderRegistry.swift`
- `swift/Sources/HudsonSpeechEngine/TTSProviderRegistry.swift`
- `swift/Sources/VoxCore/SpeechModelCatalog.swift`
- `swift/Sources/VoxCore/PluginStore.swift`

Use the operator surface to inspect the runtime without guessing:

```bash
vox doctor
vox warmup status parakeet:v3
vox transcribe status
vox logs daemon --tail 80
```

See [Architecture](./architecture.md) for layer ownership and [Observability](./observability.md) for performance sample interpretation.

## Native PCM streaming

Use the app-captured PCM routes for model-backed partial text. The live default is `nemotron:unified-560ms` (Nemotron Labs Unified); file transcription remains `parakeet:v3`. These routes are separate from the existing daemon-microphone `transcribe.startSession` routes. The app owns microphone permission, capture, and conversion to mono 16 kHz float32 PCM. Vox owns inference, decoder state, word timings, and endpoint detection.

For several apps, run one `voxd` and connect through its authenticated private Unix transport. Set `VOX_SOCKET_PATH` and `VOX_AUTH_TOKEN` in the host environment; private mode requires both and opens no TCP listener. Do not launch one daemon per app. For a single-process app, use `NativeStreamingASR.shared` from `VoxEngine` instead. Both surfaces use the same Swift/Core ML implementation. Neither uses Python, MLX, or the FluidAudio package.

1. Call `models.install` with the live `modelId`. Installation does not load the streaming model.
2. Call `models.preload` explicitly. Preload loads the encoder, verifies its compute plan, and primes prediction. Allow for a cold ANE compile.
3. Call `transcribe.stream.start` with `clientId` and `modelId`. Start requires a preloaded model and does not download or warm it.
4. Send `transcribe.stream.append` packets. Await each acknowledgement before sending the next packet.
5. Call `transcribe.stream.finish` to flush pending audio and obtain the final transcript. Call `transcribe.stream.cancel` to discard it instead.

Every append, finish, and cancel request must include the returned `sessionId` and the same `clientId`, on the same connection. A disconnect cancels that connection's session. One session owns the native model slot; other callers receive a busy error. Sessions expire after 120 seconds. A client must start a new session after reconnecting.

### Swift companion client

For intentional cross-process Apple integrations, select the `VoxClient` Swift
package product. Its only target dependency is `VoxCore`. It does not link
`VoxEngine`, `HudsonSpeechEngine`, `VoxService`, or model resources. Both the root
package and `swift/Package.swift` export this product. It is not present in older
published versions; use a revision that contains the product.

```swift
import VoxClient

let client = VoxDaemonClient(clientId: "talkie")
try await client.connect(.unix(socketPath: socketPath, authToken: authToken))
_ = try await client.installModel(StreamingASRDefaults.modelId) { progress in
    // Update app UI from progress.event and progress.data. Return promptly.
}
_ = try await client.preloadModel(StreamingASRDefaults.modelId)
let session = try await client.startPCMStream()
let ack = try await client.appendPCMStream(
    sessionId: session.sessionId, sequence: session.nextSequence, samples: samples)
// Render ack.updates. Use ack.nextSequence for the next packet.
let final = try await client.finishPCMStream(sessionId: session.sessionId)
await client.disconnect()
```

The app supplies `socketPath`, `authToken`, and captured `samples`. Provision the
credential through the host, not a URL or a log. The Unix client checks private
filesystem ownership and permissions, rejects symlink paths, checks the server
peer UID, and validates the WebSocket upgrade before RPC dispatch. It masks
outgoing frames and bounds incoming messages to 16 MiB and queued output to 32 MiB.

`VoxEndpoint.runtime(runtime, authToken:)` selects a private socket from
`RuntimeInfo`. It refuses TCP metadata unless `allowTCP: true` is explicit.
Direct `.tcp(host:port:authToken:)` selection is also an explicit opt-in. This is
unencrypted WebSocket; use a trusted loopback host. The client never launches a daemon, reconnects, or falls back to another
transport. Use `connectDiscovered()` for the owner-only host capability described
below, or pass an explicit endpoint.

`listModels()`, `listCatalog()`, `installModel(_:onProgress:)`,
`preloadModel(_:timeout:onProgress:)`, and `transcribeFile(path:modelId:)` return
`JSONValue`, a Sendable Codable value. This preserves provider metrics and
catalog fields without a parallel schema. `nativeStreamingStatus()` returns
`NativeStreamingStatus` from `VoxCore`. PCM methods return typed
`PCMStreamingSession`, `PCMStreamingAcknowledgement`, and `StreamingASRUpdate`.
`cancelPCMStream(sessionId:)` discards the session without a transcript.

Use `call(_:params:timeout:onProgress:)` for other existing routes, including
warmup and TTS. It always supplies the client's stable `clientId`.
Progress callbacks receive `VoxRPCProgress` and run on the client actor; dispatch
UI changes to the main actor. Install defaults to a 30-minute request budget;
preload and file transcription default to 5 minutes, and other methods default
to 30 seconds.
Preload callers can select a different wait budget, for example
`preloadModel("parakeet:v3", timeout: .seconds(600))`. This changes the caller's
wait deadline, not residency or server compilation cancellation. Cold readiness
must be visible in app UI; do not hide it by disabling idle unload or starting
capture before readiness. At most 64 RPC requests can be pending. PCM append and finish reject overlapping
operations for the same session; await each acknowledgement.

A cancelled or timed-out request closes the connection and fails all pending
requests. The daemon cancels connection-owned sessions on disconnect. Execution
of an already received request is uncertain: cancellation of an install wait is
not a server-side download-cancel capability. Never retry an uncertain append.
Reconnect explicitly and start a new session. App error paths must disconnect or
cancel their owned session; abandoning an awaiting task without cancelling it is
not cancellation.

This client does not add VAD events, confirmed-word boundaries, dictionary hints,
download deletion/cancellation, or native ASR language result fields. It exposes
the 120-second native stream limit. Annotation has its own explicit cloud model
inventory, language evidence, credentials and limits described above. TTS cancellation uses synthesis sessions; raw
`synthesize.generate` does not have a per-request cancel RPC.

### Private runtime discovery

Start the user-owned shared daemon with:

```sh
voxd --private
```

This selects `VOX_HOME/voxd.sock` (default `~/.vox/voxd.sock`) and generates a fresh
256-bit credential with the system secure random source on each launch. It opens
no TCP listener. The credential is published only in the owner-only capability;
it is not put in process environment or command arguments. A user LaunchAgent
needs the executable path and `--private` in its `ProgramArguments`, not a token
in the plist. This change does not install or replace a launch service.

`VOX_SOCKET_PATH` can select a different private socket, with or without
`--private`. The daemon generates a credential when `VOX_AUTH_TOKEN` is absent;
a nonempty valid explicit token remains available for deliberate host control.
An explicitly empty/invalid token fails rather than being replaced. Do not
combine private mode with `--port`. Independently launched GUI clients should
use capability discovery, not inherit a socket-only environment override.
No app should start a replacement daemon when discovery or authentication fails.

In private mode, the daemon atomically publishes a credential-bearing capability
at `VOX_RUNTIME_PATH`, or `VOX_HOME/runtime.json`, or `~/.vox/runtime.json`.
The immediate directory is owner-only `0700`; the file is a same-user regular
file with mode `0600`, one hard link, and a 64 KiB reader limit. Reads and writes
reject symlink ancestors and leaves. Treat this file as a credential, not a
status document. Do not print or copy its raw JSON into logs or diagnostics.

All fields are at the top level:

| Field | Contract |
|---|---|
| `schemaVersion` | `1` |
| `transport` | `unix+ws+json-rpc` |
| `instanceId` | UUID, changes on each publication |
| `socketPath` | Absolute private Unix socket path |
| `authToken` | Current server token (generated unless explicitly overridden); no `authTokenPath` indirection |
| `port` | `0`; never interpret this as a request to use a default TCP port |
| `version`, `serviceName`, `pid` | Existing Vox runtime metadata |
| `startedAt` | Existing JSONEncoder Date representation: seconds since 2001-01-01 UTC |

`VoxEndpoint.discovered()` and `VoxDaemonClient.connectDiscovered()` use this order:

1. If either `VOX_SOCKET_PATH` or `VOX_AUTH_TOKEN` is present, require both to be
   nonempty and use that explicit pair. An incomplete pair is an error.
2. Otherwise read the capability file at the selected runtime path. Verify file
   safety, schema and private transport. Missing, malformed, unsafe and legacy
   TCP metadata do not trigger TCP fallback or daemon launch.
3. On connect, verify socket safety and the same-user server peer before sending
   the token. A reconnect must reread the capability and start a new session.

Private startup refuses a runtime record whose PID is still live, including
legacy TCP metadata without a token. Stop the existing host deliberately before
switching the canonical runtime to private mode. Do not fix an old `0644` record
by hand-writing a token or merely changing its permissions. Stale same-user
legacy metadata can be atomically replaced with a new `0600` capability after
the old PID is gone. Malformed or unsafe records fail closed; verify ownership
before manual cleanup. Use an isolated `VOX_HOME` and `VOX_RUNTIME_PATH` for tests.

Only one private publisher can hold a runtime-file lease. Isolated test hosts
must select their own `VOX_RUNTIME_PATH`. Publication failure closes the new
listener instead of leaving an undiscoverable service. Normal shutdown removes
only the capability whose `instanceId` belongs to that registration. After a
crash, a new host can acquire the released lease and replace stale metadata.
Swift `RuntimeRegistry.read()` still returns metadata only; health/status never
include `authToken`. The current TypeScript TCP client/CLI reject a private
capability explicitly rather than starting or connecting to a second TCP daemon.
They do not yet implement private Unix transport.

```swift
import VoxClient

let client = VoxDaemonClient(clientId: "talkie")
try await client.connectDiscovered()
let status = try await client.nativeStreamingStatus()
await client.disconnect()
```

The host owns daemon launch; `voxd --private` owns secure token generation and
publication unless an explicit credential override is supplied. Direct TCP mode remains available for deliberate
legacy deployments; its registry is metadata, not a private capability.

### PCM wire contract

| Route | Parameters | Result |
|---|---|---|
| `transcribe.stream.start` | `clientId`, optional `modelId` | `sessionId`, `modelId`, `sampleRate: 16000`, `channels: 1`, `encoding: "float32le"`, `maxPacketSamples: 16000`, `nextSequence: 0` |
| `transcribe.stream.append` | `clientId`, `sessionId`, `sequence`, `audioBase64` | `sessionId`, `nextSequence`, `updates[]` |
| `transcribe.stream.finish` | `clientId`, `sessionId` | `sessionId`, `result` |
| `transcribe.stream.cancel` | `clientId`, `sessionId` | `sessionId`, `cancelled: true`; no final transcript |
| `transcribe.stream.status` | none | loaded/loading `modelId`, encoder `placement`, active session/client, `idleUnloadSeconds` |

`audioBase64` encodes little-endian IEEE float32 samples. Each packet contains 1–16000 finite samples. Use 80 ms packets (1280 samples) for responsive feedback. Sequence numbers start at zero and increase once per acknowledged packet. Duplicate and out-of-order packets are rejected. Do not retry an append whose receipt is uncertain; cancel or reconnect and begin a new session. There is no unbounded server-side PCM queue.

Each update and final result contains:

- `text`: cumulative transcript, not a text delta;
- `words`: `word`, `start`, `end` in seconds, and `confidence`;
- `processedAudioMs`: the processed position on the input-audio timeline;
- `chunkLatencyMs`: inference time for that chunk;
- `endOfUtterance`: an endpoint notification, not an implicit stop;
- optional `endpointSource`: `model` for the Parakeet EOU token, or `blank-duration` for Nemotron's 1120 ms RNNT blank-duration rule.

Word timestamps are approximate greedy RNNT emission frames, not forced alignment. The caller decides whether an endpoint should finish the session. Finish is explicit, including when the last update signals an endpoint. Finish results do not synthesize a model endpoint.

### Placement and residency

After load, Vox reads `MLComputePlan` with `.cpuAndNeuralEngine`. Diagnostics expose preferred ANE, CPU, GPU, and unassigned operation counts, plus ANE/CPU counts for convolution, linear, and matrix-multiplication operations. A few CPU shape and integer operations are expected. The encoder must have compute operations on ANE. If any compute operations use CPU, at least 95% of the scheduled ANE/CPU estimated cost must be on ANE. This allows the two small CPU pre-encode convolutions in Nemotron on M1 without accepting a CPU encoder. A failed placement check releases the instance, retries once, then fails instead of accepting CPU fallback. This verifies the planned device assignment; it is not a hardware execution trace.

The native ASR slot is process-wide and shared by batch Parakeet and streaming providers. Model switching unloads the previous model before loading another. An active session or batch inference holds an exclusive lease. Warmup is serialized; same-model streaming warmups join one flight. Installation validation checks files and byte counts without loading or compiling models.

Idle models unload after 60 seconds. Set `VOX_ASR_IDLE_SECONDS` before starting the host to change this timeout; `0` disables eviction. Embedded streaming callers can also call `setIdleUnload(seconds:)`. Active sessions are not evicted. Preload again after an idle unload. `transcribe.stream.status` and `models.list` expose current residency and planned placement. Streaming telemetry preserves `clientId`, `route: "transcribe.streaming"`, and `modelId`.
