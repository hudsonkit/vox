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
- Private registry metadata includes `socketPath` and `port: 0`; VoxRuntimeService publishes the owner-only capability. A raw ServiceBridge host can use PrivateRuntimeRegistration. TypeScript TCP discovery refuses private capabilities.
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

- Standalone voxd --private: default ~/.vox/voxd.sock, fresh system-random 256-bit token, no TCP listener. VOX_SOCKET_PATH overrides path; optional explicit VOX_AUTH_TOKEN overrides token. No token in argv, process env or launchd plist is needed.

- Current StreamingASRDefaults.modelId: nemotron:unified-560ms; new Native provider is included when loading legacy custom ASR provider configurations unless the same provider id is explicitly configured.

## Swift companion client

- Product/module `VoxClient`, public actor `VoxDaemonClient(clientId:)`; depends only on VoxCore, no engines/resources. Root and nested Swift manifests export it.
- Explicit `connect(.unix(socketPath:authToken:))`; Unix path/ownership/permission/peer UID checks, authenticated and validated WebSocket upgrade. No launch, reconnect or fallback; connectDiscovered reads the private host capability.
- `VoxEndpoint.runtime(_:authToken:allowTCP:tcpHost:)` requires allowTCP=true for TCP metadata; direct `.tcp(host:port:authToken:)` is explicit opt-in, unencrypted trusted-loopback use.
- Typed `startPCMStream(modelId:)`, `appendPCMStream(sessionId:sequence:samples:)`, `finishPCMStream(sessionId:)`, `cancelPCMStream(sessionId:)`, `nativeStreamingStatus()`; shared DTOs re-exported from VoxCore.
- Generic Sendable Codable JSONValue from listModels/listCatalog/installModel/preloadModel/transcribeFile; `call(_:params:timeout:onProgress:)` exposes other existing routes, overrides clientId with owned identity.
- Progress VoxRPCProgress callback must return promptly; UI work goes to MainActor. Install timeout 1800 s; preload/file default 300 s; preloadModel(_:timeout:onProgress:) permits an explicit cold-readiness budget, e.g. 600 s; other calls 30 s.
- One typed append/finish in flight per session; 64 pending RPC limit; 16 MiB messages/32 MiB Unix queued output. Cancel remains callable during append/finish.
- Request task cancellation/timeout closes connection and fails all pending calls, never retries uncertain work; not a server download-cancel capability. Explicit reconnect starts a new session.
- No new capability negotiation, VAD, confirmed boundaries, hints, model delete/download cancellation, language field, or streaming diarization. File annotation uses explicit request-authenticated Scribe/Deepgram cloud models; one-shot generate has disconnect cancellation, not a per-request cancel RPC.

## Private capability discovery

- Official private bootstrap: voxd --private generates/publishes its own credential; explicit env pair remains supported. No daemon/client auto-launch or production launch-service replacement.
- Private mode atomically publishes VOX_RUNTIME_PATH, else VOX_HOME/runtime.json, else ~/.vox/runtime.json. Parent 0700, same-user regular file 0600, nlink=1, 64 KiB maximum; symlink-safe reads/writes and same-UID socket peer check.
- Root fields: schemaVersion=1, transport=unix+ws+json-rpc, instanceId UUID, socketPath absolute, authToken inline, port=0, plus existing version/serviceName/pid/startedAt metadata. startedAt keeps JSONEncoder seconds-since-2001 representation. No authTokenPath.
- VoxEndpoint.discovered() / VoxDaemonClient.connectDiscovered(): explicit env endpoint+token pair wins; either present requires both nonempty; otherwise secure capability file. No missing/invalid/TCP fallback, no daemon launch.
- One private runtime publisher lease; publication failure stops new listener; stop removes only its own instance. Distinct test hosts need distinct VOX_RUNTIME_PATH.
- RuntimeRegistry.read and health return metadata, never credentials. Never log raw capability JSON. TypeScript TCP discovery/CLI refuse private files rather than connecting/launching another TCP daemon; private TS transport is not implemented.

- Scoped ElevenLabs credentials.ELEVENLABS_API_KEY supported for synthesize.generate/startSession and voices with explicit modelId, through in-process or bundled voxttsd. No mutation/persistence of lent key, no retry against another account; inventory stays configured-only. OpenAI static voices also accept scoped keys; unsupported scoped voice providers error. Never send keys via voice-list query URLs. Swift VoxClient uses generic call, no engine dependency.

- PrivateRuntimeConfiguration.resolve parses --private / VOX_SOCKET_PATH; default socket VOX_HOME/voxd.sock, system CSPRNG 32-byte token, optional validated explicit auth override; invalid/empty explicit config and --port conflict fail. Generated secrets never enter process environment or logs; client incomplete-env-pair rules stay strict.
- Private publication checks prior owner PID before replacing legacy 0644 metadata: live PID blocks startup and rolls back listener; only a stale same-user record can upgrade to 0600 capability. Malformed/unsafe metadata fails. Never hand-write a token/chmod an active legacy record as a workaround. Operator stops/reconfigures the existing host deliberately; isolated tests use their own VOX_HOME/runtime path.

- Native Parakeet batch words now group SentencePiece/whitespace-delimited pieces, punctuation attached. Older revisions returned BPE pieces. Start/end=min/max contributing token intervals, confidence=min piece score; 80 ms decoder-frame estimates, not forced alignment/calibrated word posterior. Multiword pieces share source interval; missing vocab skipped, malformed alignment arrays return no timings. Grouping runs after long-file chunk merge.

## Cloud file annotation

- `annotation.models` inventory, `annotate.file` upload; explicit `elevenlabs:scribe_v2` / `deepgram:nova-3`, no cloud default. Default AnnotationManager is RemoteAnnotationProvider; old placeholder errors.
- `credentials.ELEVENLABS_API_KEY` / `DEEPGRAM_API_KEY` apply to one request only. No ambient fallback, account cache or global mutation. Same private capability and VoxClient, no engine dependency. Never log keys.
- `listAnnotationModels()` -> [AnnotationModelInfo]; `annotateFile(path:modelId:credentials:diarize:tagAudioEvents:languageCode:numSpeakers:timeout:)` -> AnnotationOutput, default 3600 s. Cancel disconnects and aborts own uploads; cannot undo vendor work/billing.
- `diarize` defaults true. Scribe events default true; numSpeakers 1–32 requires diarize. Deepgram events/count hints error before upload. Optional languageCode is not echoed as detected language. Cloud providers reject text/words alignment hints.
- Words have nullable confidence/logProbability/speakerConfidence. Scribe preserves logprob, no exponentiation; Deepgram preserves scores. Scribe speaker IDs unchanged; Deepgram integers become decimal strings. Missing times error. Events separate from speech; spacing ignored.
- Scribe speaker spans: word-span-derived; Deepgram: vendor-utterances else word-span-derived. No invented aggregate confidence or acoustic VAD. Duration vendor else actual media metadata, source explicit, otherwise error. No fake vendor IDs/language. unsupportedFields vs unavailableFields distinguish limits from missing response evidence.
- Two active uploads maximum; overflow errors busy. Input <=2,000,000,000 B, disk-streamed in 64 KiB chunks to 0700 dir/0600 file then removed. Response <=4 MiB, result <=8 MiB. Ephemeral HTTP, no caches/cookies/auth storage, no redirects/application retries. HTTP errors expose status only. Vendor retention, accuracy and account access unverified.
- Host-only complete endpoint overrides `VOX_ANNOTATION_ELEVENLABS_URL` / `VOX_ANNOTATION_DEEPGRAM_URL`: HTTPS or loopback HTTP, no query/fragment/userinfo. Invalid override fails closed. Never client-controlled.
- Integration: `xcrun swift build --package-path swift --product voxd`; `python3 scripts/test-private-annotation.py`. Isolated private daemon, two model-free clients, loopback fixtures only. No paid calls or installed runtime changes. Native ASR unaffected.
