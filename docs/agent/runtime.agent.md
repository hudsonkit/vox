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
