# Apple Embed Facts

## Use embed mode when

- target: macOS app or iOS app
- caller: app process
- requirement: voice in and voice out inside the app

## Use companion mode when

- target: web app or browser extension
- caller: Bun/Node tool outside the app process
- requirement: shared local voice service across processes

## Do not do this

- do not start `voxd` inside the Apple app just to call Vox APIs
- do not use `@voxd/sdk` or `@voxd/client` from app code
- do not hide warm-up as an implicit side effect

## Add package dependency

- remote dependency: `.package(url: "https://github.com/hudsonkit/vox.git", from: "0.5.2")`
- sibling checkout dependency: `.package(path: "../vox/swift")`
- required products for app embed: `VoxCore`, `VoxEngine`
- optional product for Apple playback: `VoxAppleSpeech` / `AppleSpeechOutputController`
- avoid `VoxService` and `VoxBridge` unless intentionally embedding companion/runtime behavior

## Start with VoxDictation

- `VoxDictation(clientId:modelId:preferredInputDeviceID:engine:recordsPerformance:)`, an actor in `VoxEngine`
- `warmUp(progress:)` downloads and loads the model; call on user intent, not at launch
- `start(onBuffer:)` records the microphone; macOS only, throws on iOS
- `stop()` returns `TranscriptionOutput` and deletes the recording; `cancel()` discards
- `transcribe(fileURL:)` works on macOS and iOS
- `inputLevel()` for meters; `isListening`, `isReady`
- errors: `VoxDictationError.alreadyListening`, `.notListening`
- records a `PerformanceSample` per transcription with routes `transcribe.dictation` / `transcribe.file`

## Default embed engines

- ASR default: `EngineManager()` -> `NativeASRProvider()` (batch Parakeet + explicit native streaming models)
- TTS generation default: `TTSEngineManager()` -> `TTSProviderRegistry` with every built-in provider (OpenAI, ElevenLabs, MiniMax, NVIDIA, Groq, Gemini, AVSpeech); routes by model id, never falls back between providers
- TTS playback is not on `TTSProvider`; optional Apple playback is `AppleSpeechOutputController`
- default ASR model id: `parakeet:v3`
- English-only ASR model id: `parakeet:v2`
- default TTS model id: `TTSDefaults.modelId` = `gpt-4o-mini-tts`
- local TTS model id: `TTSDefaults.localModelId` = `avspeech:system`
- default TTS format: `TTSDefaults.format` = `wav`

## Public types to use

- ASR input: `URL`
- ASR output: `TranscriptionOutput`
- TTS request: `SynthesisRequest`
- TTS output: `SynthesisOutput`
- voices: `TTSVoiceInfo`
- telemetry: `PerformanceRecorder`, `PerformanceSample`

## Warm-up

- dictation: call `dictation.warmUp(progress:)`
- call `asr.preload(modelId:progress:)`
- call `tts.preload(modelId:voiceId:progress:)`
- do not rely on `WarmupCoordinator`; it is not public in the embed surface

## Telemetry parity

- `VoxDictation` records automatically; `EngineManager` and `TTSEngineManager` callers must record manually
- preserve fields: `clientId`, `route`, `modelId`, `voiceId`
- preserve route names: `transcribe.dictation`, `transcribe.file`, `synthesize.generate`
- performance log path comes from `RuntimePaths.performanceLogURL()`

## App owns these concerns

- microphone permission (`NSMicrophoneUsageDescription`; audio-input entitlement when sandboxed)
- audio capture on iOS (macOS can use `VoxDictation` / `MicrophoneFileRecorder`)
- product-level spoken-output policy (dedupe, markdown flattening, fallback copy, preferences, queue priority)
- playback of `SynthesisOutput.audioData`, or an opt-in `AppleSpeechOutputController` per audible surface
- interruption handling
- product state and UI

## OpenAI TTS rule

- `gpt-4o-mini-tts` needs an OpenAI key; without one the request throws, with no automatic fallback
- use `TTSDefaults.localModelId` for the on-device system voice; retry with it yourself if you want a fallback
- key lookup order: `SynthesisRequest.providerCredentials`, `ProviderEntry.env`, process env, Vox credential store
- pass `OPENAI_API_KEY` via `ProviderEntry.env` or `providerCredentials`; never ship a long-lived key in the binary
- do not rely on process environment inside iOS app code

## Optional Apple playback

- `VoxAppleSpeech` is optional and per audible surface, not a singleton
- `avspeech:system` uses live `AVSpeechSynthesizer.speak()`, never `write()`-then-play
- generated-audio models play `SynthesisOutput.audioData` through an injectable player sink
- audio-session configuration is injectable and off by default
- Per-request local output: start(request,options:SpeechOutputOptions(pitchMultiplier:Double?,volume:Double?)) or throwing speak(request,options:). SynthesisRequest remains generation-only (speed unchanged).
- Pitch finite 0.5...2.0; volume finite 0...1; nil=platform default. Invalid values throw before replacing current playback; no silent clamp. Explicit values require support, even 1.0.
- Events/status expose requested options + actual canSetPitch/canSetVolume. System speech applies both before enqueue, preserves through seek/pause/resume, resets defaults on next request.
- Generated audio: pitch unsupported before synthesis; real player volume applied before play. Custom player volume support is learned after generation. Unsupported/declined options emit terminal failed (unsupportedPitch/unsupportedVolume), never silently ignore. Custom sinks default false; volume-capable players must implement setVolume(_:) -> Bool.
- new requests replace pending generation/playback
- stop/cancel are idempotent and must cancel Task, player, and synthesizer during the enqueue window
- events report resolving/generating, starting, playing, paused, resumed, wordRange, finished, cancelled, failed
- start(SynthesisRequest) throws -> SpeechOutputIdentity(requestId,generation); legacy speak unchanged. status() + events expose actual SpeechPlaybackCapabilities, initially unavailable during resolution.
- pause(identity)/resume(identity) async throws -> Bool: genuine retained utterance/player, no stop/re-synthesis. System true=accepted, paused/resumed events=delegate acknowledgement; false does not change state. Pause requires playing/resumed, resume requires paused; controlPending until system acknowledgement.
- seek(identity,toUTF16Offset:) throws -> new identity: live-system only, original-text character boundary before nonempty suffix; same request ID/new generation, cancels old and starts replacement even if previously paused. Invalid offsets leave playback untouched. Generated audio has no ranges or text seek.
- wordRange carries utf16Range(location,length,nsRange) in ORIGINAL unmodified request text, remapped across seeks; native will-speak evidence only, not playback clock/alignment. Discard invalid/split-surrogate ranges.
- stop(identity)/cancel(identity)/seek/pause/resume reject stale request OR generation; current-surface no-arg stop/cancel remain. Recheck event.identity after UI hops; caller-queued old events cannot be retracted.
- Custom sinks default unsupported; opt into playbackCapabilities and genuine controls/identity-bearing callbacks. examples/apple-readout compiles entire output consumer for iOS Simulator in CI. Evidence: reports/apple-readout-controls-2026-10-30.md; no physical-device audible acceptance implied.
- synthesis identity reports requested vs actual model/voice, not a guessed provider id
- synthesis identity is separate from the physical audio-output route
- do not put reply dedupe, markdown flattening, fallback copy, preference storage, queue priority, or telemetry double-recording in this controller

## Known gaps

- `VoxDictation` covers dictation only; `VoxAppleSpeech` is separate playback
- no microphone capture on iOS yet
- `VoxDictation` remains record-then-transcribe; use `NativeStreamingASR.shared` for PCM partials
- no automatic telemetry recording outside `VoxDictation`
- `VoxAppleSpeech` does not own browser playback or app product policy

## Default recipe

- client id: stable per app, for example `my-app-ios` / `my-app-macos`
- dictation: `VoxDictation`
- ASR engine for custom flows: `EngineManager()`
- TTS engine: `TTSEngineManager()`
- TTS default: `gpt-4o-mini-tts`
- TTS local model: `avspeech:system` (fallback is the app's choice)
- use Vox Companion only for web or cross-process workflows

## Packaged app resources

Xcode copies SwiftPM resource bundles automatically. When packaging by hand, copy the bundle SwiftPM built into the signed app's `Contents/Resources`: `Vox_HudsonSpeechEngine.bundle` when depending on the repo root, `HudsonSpeechEngine_HudsonSpeechEngine.bundle` when depending on `vox/swift`. Vox looks for both.
`SpeechEngineResources` resolves the model catalog and mlx-audio provider script
from that location in apps, and from SwiftPM resources in command-line builds.
A packaged app does not fall back to a developer build directory.

## Native streaming

- `NativeStreamingASR.shared` is exported by VoxEngine; Apple Silicon, macOS 14.4 / iOS 17.4+.
- Explicit install / preload; default streaming id from StreamingASRDefaults.modelId.
- `preload(modelId:directory:language:progress:)` supports an explicit offline bundle.
- `begin(clientId:modelId:)` -> UUID; requires ready model; one owner.
- `append(sessionId:clientId:samples:)` -> [StreamingASRUpdate]; 1–16000 finite mono 16 kHz float32 samples, await each call.
- `finish(sessionId:clientId:)` flushes -> final update; cancel discards.
- Cumulative text, approximate RNNT words, explicit endpointSource; endpoints do not auto-stop.
- Process-wide residency shared with batch; idle unload macOS 900 s / iOS 60 s, configurable; native ASRModelInfo.idleUnloadSeconds reports the actual value. Preload again after eviction or model switch; bounded desktop retention does not fix compiler stalls.
- `status()` exposes actual planned encoder placement from MLComputePlan, not requested computeUnits or a hardware trace. Native streaming production inventory/preload excludes Simulator, even ARM64; use physical iOS17.4+ for ANE validation.
- Several app processes intentionally share one voxd private authenticated Unix endpoint; do not load separate engines per app.

## Embedded Parakeet ownership

- Keep a concrete ParakeetProvider, optionally inject it into EngineManager. iOS embeds VoxCore/VoxEngine, no local daemon/transport/FluidAudio. Explicit batch ID parakeet:v3.
- await models(): filesystem metadata + actual runtime snapshot, no writes/download/load/Core ML compilation. modelDirectory(modelId:) throws -> URL is read-only location; do not manually delete paths.
- install(modelId:progress:) is now download-only (earlier versions also warmed); preload(modelId:progress:) explicitly loads, verifies encoder ANE placement and primes. Installed != preloaded. Same-model install/load are single-flight; cancelled waiter does not stop shared initialization.
- unload(modelId:) async throws -> ASRModelInfo releases actual shared Session/model closures, not just a provider reference. Metadata actors remain cached. Snapshot preloaded=false, placement=nil; other providers see it. Not an OS cache/RSS purge.
- deleteModel(modelId:) async throws -> ASRModelInfo unloads then deletes only selected Vox-owned revision, no siblings/root/FluidAudio/system caches. Missing directory idempotent; filesystem failure may leave partial deletion + unloaded runtime, so refresh status.
- Both reject admitted install/warmup/file-preparation/inference via ParakeetLifecycleError.busy; no stealing leases. Reservations are process-local, not cross-process store locks. Mac shared apps still use voxd.
- setIdleUnload(modelId:seconds:): finite nonnegative seconds, zero disables; production default macOS 900 s / iOS 60 s, env VOX_ASR_IDLE_SECONDS. Native ASRModelInfo reports actual idleUnloadSeconds. Shared process/model scope. Idle cannot interrupt active runtime work.
- Store deletion: descriptor-relative no-follow walk below trusted Vox home, receipts bind model/repo/revision; known built-in legacy layouts allowed, unknown custom unreceipted nonempty directories/alias receipts rejected. Do not hardcode cache manifests in callers.
- Cached engine conversion is process-selected; catalog refresh does not hot-swap it. Restart for conversion updates.
- examples/parakeet-lifecycle public native consumer compiles for ARM64 iOS Simulator in CI (entire VoxEngine, not only VoxClient). Simulator available=false; hardware ANE requires iOS17.4+/macOS14.4+. No iOS device footprint/placement/accuracy claimed.
