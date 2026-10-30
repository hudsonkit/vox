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

## File Annotation

`annotate.file` is the file-first speaker annotation route. It accepts an audio path plus optional transcript text and word timings, and returns speaker segments, speaker-attributed words, and annotation metrics.

The route is scaffolded now so evaluation harnesses and future diarization backends can share one contract even before the default annotation backend lands.

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
`preloadModel(_:onProgress:)`, and `transcribeFile(path:modelId:)` return
`JSONValue`, a Sendable Codable value. This preserves provider metrics and
catalog fields without a parallel schema. `nativeStreamingStatus()` returns
`NativeStreamingStatus` from `VoxCore`. PCM methods return typed
`PCMStreamingSession`, `PCMStreamingAcknowledgement`, and `StreamingASRUpdate`.
`cancelPCMStream(sessionId:)` discards the session without a transcript.

Use `call(_:params:timeout:onProgress:)` for other existing routes, including
warmup, annotation and TTS. It always supplies the client's stable `clientId`.
Progress callbacks receive `VoxRPCProgress` and run on the client actor; dispatch
UI changes to the main actor. Install has a 30-minute request budget, preload and
file transcription have 5-minute budgets, and other methods default to 30 seconds.
At most 64 RPC requests can be pending. PCM append and finish reject overlapping
operations for the same session; await each acknowledgement.

A cancelled or timed-out request closes the connection and fails all pending
requests. The daemon cancels connection-owned sessions on disconnect. Execution
of an already received request is uncertain: cancellation of an install wait is
not a server-side download-cancel capability. Never retry an uncertain append.
Reconnect explicitly and start a new session. App error paths must disconnect or
cancel their owned session; abandoning an awaiting task without cancelling it is
not cancellation.

This client does not add capability negotiation, VAD events, confirmed-word
boundaries, dictionary hints, download deletion/cancellation, or language result
fields. It exposes the existing daemon contract, including its 120-second native
stream limit. `annotate.file` remains a file-first scaffold, not a guarantee of an
installed diarization backend. TTS cancellation uses synthesis sessions; raw
`synthesize.generate` does not have a per-request cancel RPC.

### Private runtime discovery

A host starts one private `voxd` with `VOX_SOCKET_PATH` and `VOX_AUTH_TOKEN`.
Standalone `voxd` supports this mode; it opens no TCP listener. No app should
start a replacement daemon when discovery or authentication fails.

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
| `authToken` | Inline host-provisioned token; no `authTokenPath` indirection |
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

The host owns daemon launch and token provisioning. This change does not install
or replace a launch service. Direct TCP mode remains available for deliberate
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
