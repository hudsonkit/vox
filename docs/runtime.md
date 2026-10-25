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

Private connections retain the same JSON-RPC methods, events, and connection ownership. The transport limits incoming frames to 16 MiB and queued output to 32 MiB. The runtime registry reports `port: 0` and `socketPath` for a private endpoint. The host owns capability publication and client discovery; the standalone CLI and browser bridge continue to use their existing TCP configuration.

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
