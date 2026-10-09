---
title: Swift embed reference
description: Every type for running Vox inside a macOS or iOS app, covering dictation, transcription, speech output, timings and packaging.
---

This is the reference for running Vox inside a macOS or iOS app. New here? [Vox in your app](./start-swift.md) gets dictation working in a few minutes; come back for the details.

## Choose the integration mode

- Use embed mode when the caller is app code running inside a macOS or iOS process.
- Use Vox Companion (`voxd`) when the caller lives outside the app process, such as a web app, browser extension, or Bun/Node tool.
- Keep `voxd` out of the Apple app itself. If the goal is in-process app integration, embed the Swift packages directly instead.

## What embed mode is today

Start with `VoxDictation`. It wraps the pieces below in four calls: `warmUp()`, `start()`, `stop()`, `cancel()`, plus `transcribe(fileURL:)`. It records timings for you. Reach for the lower-level types when you need something it does not do.

- dictation: `VoxDictation` (microphone capture on macOS only; file transcription on both)
- microphone capture: `MicrophoneFileRecorder` (macOS only; the iOS build throws)
- ASR: `EngineManager`
- TTS generation: `TTSEngineManager`, `SynthesisRequest`
- optional Apple playback: `VoxAppleSpeech` / `AppleSpeechOutputController`
- outputs: `TranscriptionOutput`, `SynthesisOutput`, `TTSVoiceInfo`
- telemetry: `PerformanceRecorder`, `PerformanceSample`
- provider composition: `ProviderRegistry`, `TTSProviderRegistry`, `ProvidersConfig`, `ProviderEntry`

For anything beyond `VoxDictation`, keep raw Vox types behind one app-local actor such as `VoiceService`. Use `VoxAppleSpeech` when the app wants a reusable per-audible-surface playback controller; keep product policy in the app.

## Package setup

`VoxCore` and `VoxEngine` support direct transcription embedding on macOS 14+
and iOS 17+. Minivox uses that same direct path and requires macOS 26+.

Add the package from GitHub:

```swift
.package(url: "https://github.com/hudsonkit/vox.git", from: "0.5.2")
```

For a sibling checkout during local development, use a path dependency instead:

```swift
.package(path: "../vox/swift")
```

Add these product dependencies to the app target:

- `VoxCore`
- `VoxEngine`
- `VoxAppleSpeech` when the app wants the optional reusable Apple speech-output controller

Only add `VoxService` or `VoxBridge` if the app intentionally embeds companion/runtime behavior. That is not the default Apple app path.

## Minimal local-first service

```swift
import Foundation
import VoxCore
import VoxEngine

actor VoiceStack {
    private let clientId: String
    private let asr: EngineManager
    private let tts: TTSEngineManager
    private let performance = PerformanceRecorder()

    init(clientId: String = "my-app") {
        self.clientId = clientId
        self.asr = EngineManager()      // Parakeet
        self.tts = TTSEngineManager()   // every built-in TTS provider; no automatic fallback
    }

    func warmup() async throws {
        _ = try await asr.preload(modelId: "parakeet:v3") { _ in }
        _ = try await tts.preload(modelId: TTSDefaults.modelId, voiceId: nil) { _ in }
    }

    func transcribe(fileURL: URL) async throws -> TranscriptionOutput {
        let output = try await asr.transcribe(url: fileURL, modelId: "parakeet:v3")

        await performance.record(
            PerformanceSample(
                clientId: clientId,
                route: "transcribe.file",
                modelId: output.modelId,
                outcome: "ok",
                textLength: output.text.count,
                metrics: output.metrics.performanceMetrics
            )
        )

        return output
    }

    func synthesize(text: String, voiceId: String? = nil) async throws -> SynthesisOutput {
        let output = try await tts.synthesize(
            SynthesisRequest(
                text: text,
                modelId: TTSDefaults.modelId,
                voiceId: voiceId
            )
        )

        await performance.record(
            PerformanceSample(
                clientId: clientId,
                route: "synthesize.generate",
                modelId: output.modelId,
                voiceId: output.voiceId,
                outcome: "ok",
                textLength: text.count,
                metrics: output.metrics.performanceMetrics
            )
        )

        return output
    }
}
```

## App responsibilities

In embed mode, the app still owns:

- microphone permission (`NSMicrophoneUsageDescription`, and the audio-input entitlement when sandboxed)
- audio capture on iOS; on macOS `VoxDictation` or `MicrophoneFileRecorder` can capture for you
- product-level spoken-output policy
- interruption handling
- product-level state and UX

The ASR entrypoint takes a `URL`, not an in-memory audio buffer. `VoxDictation` records to a temporary file and deletes it after `stop()`. On iOS, write the recording to a file yourself, then call `transcribe(fileURL:)`.

`TTSProvider` and `TTSEngineManager` stay generation-only. They return WAV bytes in `SynthesisOutput.audioData` and do not own playback. Apps may play those bytes themselves, or opt into `VoxAppleSpeech` for a reusable Apple playback controller.

## Optional Apple speech output

`VoxAppleSpeech` is an optional embed product. `AppleSpeechOutputController` is a per-audible-surface playback arbiter, not a VoiceService facade and not an app product-policy layer.

Use it when an Apple app wants one controller per audible surface that:

- composes `TTSEngineManager` for generated-audio models
- uses live `AVSpeechSynthesizer.speak()` for `avspeech:system`, never `write()`-then-play
- plays `SynthesisOutput.audioData` through an injectable `AVAudioPlayer`-style sink
- replaces the previous pending generation or playback when a new request starts
- cancels the in-flight `Task`, audio player, and system synthesizer on idempotent `stop()` / `cancel()`, including during the enqueue window
- reports typed phases (`resolving` or `generating`, `starting`, `playing`, `finished`, `cancelled`, `failed`)
- reports requested vs actual model/voice identity separately from the physical audio-output route; it does not invent a provider id

Do not treat this controller as browser playback, OpenScout Ranger policy, or app product policy. Reply dedupe, markdown flattening, fallback copy, preference storage, queue priority, and telemetry double-recording stay in the app.

Audio-session configuration is injectable and disabled by default. There is no singleton and no process-global playback mutex; two controllers may run independently.

Route/model capability (`SpeechOutputCapabilities`) tells the controller whether a model is live system delivery or generated bytes. That capability does not add `speak()` to `TTSProvider`.

## Warm-up

Warm-up must remain explicit.

- dictation: `VoxDictation.warmUp(progress:)`
- ASR warm-up: `EngineManager.preload(modelId:progress:)`
- TTS warm-up: `TTSEngineManager.preload(modelId:voiceId:progress:)`

Do not hide warm-up behind app launch side effects. Warm on intent at a predictable app state transition, such as opening the screen that dictates. Without warm-up, the first transcription pays the model load.

## Telemetry

Companion mode records telemetry automatically. In embed mode, `VoxDictation` records a sample for every transcription (pass `recordsPerformance: false` to opt out). The lower-level types do not.

When you call `EngineManager` or `TTSEngineManager` directly, record samples yourself with `PerformanceRecorder` and preserve these dimensions:

- `clientId`
- `route`
- `modelId`
- `voiceId` for synthesis

Use the same route names Vox Companion uses:

- `transcribe.dictation` (microphone dictation, as `VoxDictation` records it)
- `transcribe.file`
- `synthesize.generate`

`RuntimePaths.performanceLogURL()` resolves to:

- macOS: `~/.vox/performance.jsonl`
- iOS: `Application Support/Vox/performance.jsonl`

## OpenAI TTS in embed mode

- ASR: `EngineManager()` -> `ParakeetProvider()`
- TTS: `TTSEngineManager()` registers every built-in provider: OpenAI, ElevenLabs, MiniMax, NVIDIA, Groq, Gemini and AVSpeech. It routes by model id and never falls back from one provider to another.
- default TTS model: `TTSDefaults.modelId` = `gpt-4o-mini-tts`, which needs an OpenAI key
- local TTS model: `TTSDefaults.localModelId` = `avspeech:system`, on device, no key

A synthesis request with `gpt-4o-mini-tts` and no key throws. If the app wants the system voice as a fallback, catch the error and retry with `TTSDefaults.localModelId`.

Keys are looked up in this order: `SynthesisRequest.providerCredentials`, the provider entry's `env`, the process environment, then the Vox credential store. An iOS app has no useful process environment, so pass the key in code. Never ship a long-lived key inside the app binary.

```swift
let ttsConfig = ProvidersConfig(providers: [
    ProviderEntry(
        id: "avspeech",
        kind: .tts,
        builtin: true,
        models: [AVSpeechSynthesizerProvider.modelID]
    ),
    ProviderEntry(
        id: "openai-tts",
        kind: .tts,
        builtin: true,
        models: OpenAITTSProvider.supportedModelIDs,
        env: ["OPENAI_API_KEY": apiKey]
    )
])

let tts = TTSEngineManager(provider: TTSProviderRegistry(config: ttsConfig))
```

## Default plan

For a new Apple app integration, the default plan is:

- use embed mode on iOS and macOS
- add `VoxCore` and `VoxEngine`, plus `VoxAppleSpeech` if the app wants reusable Apple playback
- start with `VoxDictation`; wrap anything lower-level in one app-local actor or service
- use `parakeet:v3` for ASR; `parakeet:v2` is the English-only TDT option
- use `gpt-4o-mini-tts` for default TTS
- use `avspeech:system` only when a local system voice fallback is required
- keep `VoxDictation`'s timings on, or record Vox-compatible samples yourself
- use Vox Companion only for web surfaces or cross-process workflows

## What agents should not assume

- `VoxDictation` covers dictation only. `VoxAppleSpeech` is optional playback, separate from it.
- `VoxDictation.start()` is macOS only; on iOS it throws.
- There is no public embed live-session coordinator yet: no partial text while recording.
- There is no public embed warm-up coordinator helper.
- `EngineManager` and `TTSEngineManager` do not write performance samples; only `VoxDictation` does.
- Apple apps do not need `@voxd/sdk` or `@voxd/client`.
- `VoxAppleSpeech` does not own browser playback or app product policy.

## First tasks in a sibling app repo

1. Add `https://github.com/hudsonkit/vox`, or `../vox/swift` for a sibling checkout.
2. Create one `VoxDictation`, or a single `VoiceService` actor in app code for lower-level use.
3. Warm explicitly, on user intent.
4. Feed ASR with file URLs, not raw buffers.
5. Feed TTS output WAV data into the app playback layer, or use `AppleSpeechOutputController` for per-surface Apple playback.
6. Emit `PerformanceSample` records with stable route names.
7. Keep Companion mode out of the Apple app path unless the feature is genuinely web or cross-process.

See [Observability](./observability.md) for metric interpretation and [Architecture](./architecture.md) for package ownership.

## Packaged app resources

Xcode copies SwiftPM resource bundles into the app for you. If you package the app yourself, copy the bundle SwiftPM built into the signed app's `Contents/Resources`. SwiftPM names it after the package that declares the target: `Vox_HudsonSpeechEngine.bundle` when you depend on the repository root, `HudsonSpeechEngine_HudsonSpeechEngine.bundle` when you depend on `vox/swift`. Vox looks for both.

`SpeechEngineResources` resolves the model catalog and mlx-audio provider script
from that location in apps, and from SwiftPM resources in command-line builds.
A packaged app does not fall back to a developer build directory.
