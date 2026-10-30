# Runtime Facts

- health methods: `health`, `doctor.run`
- warmup methods: `warmup.status`, `warmup.start`, `warmup.schedule`
- ASR model routes: `models.list`, `models.install`, `models.preload`, `models.catalog`, `models.refreshCatalog`
- ASR file route: `transcribe.file`
- annotation route: `annotate.file`
- ASR live routes: `transcribe.startSession`, `transcribe.sessionStatus`, `transcribe.stopSession`, `transcribe.cancelSession`
- TTS routes: `synthesize.voices`, `synthesize.generate`, `synthesize.startSession`, `synthesize.sessionStatus`, `synthesize.cancel`
- performance log path: `~/.vox/performance.jsonl`
- runtime metadata path: `~/.vox/runtime.json`
- model catalog cache: `~/.vox/cache/models-catalog.json`
- plugin store: `~/.vox/plugins/<id>/provider.json`
- browser bridge endpoints other than `/health` are origin-gated
- session ownership includes both `connectionID` and `clientId`; stop and cancel are not interchangeable

- Private host mode: pass `socketPath` plus `authToken` to `VoxRuntimeService` or `ServiceBridge`; no TCP listener opens.
- Private clients send `x-lattices-token` before WebSocket upgrade, with `Host: localhost` and path `/`; browser Origin headers are rejected.
- Private transport checks peer UID, uses directory `0700` and socket `0600`, and rejects symlink paths.
- Private registry metadata includes `socketPath` and `port: 0`; host capability discovery owns this mode. Standalone CLI/browser TCP behavior is unchanged.
- Frame bounds: 16 MiB inbound, 32 MiB queued outbound; connection ID and client ID still own sessions.

## Native app-captured PCM

- Default streaming model: `StreamingASRDefaults.modelId`; batch default stays `parakeet:v3`.
- Install and preload explicitly with `models.install` / `models.preload`; start never downloads or warms.
- Routes: `transcribe.stream.start|append|finish|cancel|status`; separate from the old daemon-microphone sessions.
- Start: clientId + modelId -> sessionId, 16 kHz mono float32le, nextSequence=0, maxPacketSamples=16000.
- Append: clientId + sessionId + sequence + audioBase64; await ack nextSequence + updates[] before next packet.
- Updates: cumulative text, words (seconds), processedAudioMs, chunkLatencyMs, endOfUtterance, optional endpointSource.
- Word timings are greedy RNNT emission frames, not forced alignment.
- Endpoint source: `model` for Parakeet EOU; `blank-duration` for Nemotron (1120 ms); endpoint does not auto-stop.
- Finish flushes -> result; cancel discards -> cancelled, no final transcript.
- Connection AND clientId AND sessionId own mutation; disconnect cancels; 120 s session limit.
- One acknowledged packet in flight; no uncertain append retries; reconnect means new session.
- Shared native model slot spans batch and streaming; exclusive active lease; unload previous before switching.
- MLComputePlan verifies ANE compute placement after load, retries once, fails closed; planned placement, not execution trace.
- Idle unload default 60 s; VOX_ASR_IDLE_SECONDS=0 disables; preload after eviction.
- Private Unix transport is intentional cross-process mode for Talkie and other app processes.

- Standalone voxd: set VOX_SOCKET_PATH + VOX_AUTH_TOKEN for the same private transport; no TCP listener in that mode.

- Current StreamingASRDefaults.modelId: nemotron:unified-560ms; new Native provider is included when loading legacy custom ASR provider configurations unless the same provider id is explicitly configured.
