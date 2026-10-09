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

- ASR default: `EngineManager()` -> `ParakeetProvider()`
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
- new requests replace pending generation/playback
- stop/cancel are idempotent and must cancel Task, player, and synthesizer during the enqueue window
- events report resolving/generating, starting, playing, finished, cancelled, failed
- synthesis identity reports requested vs actual model/voice, not a guessed provider id
- synthesis identity is separate from the physical audio-output route
- do not put reply dedupe, markdown flattening, fallback copy, preference storage, queue priority, or telemetry double-recording in this controller

## Known gaps

- `VoxDictation` covers dictation only; `VoxAppleSpeech` is separate playback
- no microphone capture on iOS yet
- no public embed live-session coordinator yet (no partial text while recording)
- no raw-buffer ASR API yet
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
