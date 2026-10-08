---
title: Swift Embed Guide
description: Agent-oriented instructions for integrating Vox directly into macOS and iOS apps such as Linea.
---

Use this guide when you are integrating Vox into a macOS or iOS app and want the app to call Vox directly in process. This is the default path for Apple-native clients such as Linea.

## Choose the integration mode

- Use embed mode when the caller is app code running inside a macOS or iOS process.
- Use Vox Companion (`voxd`) when the caller lives outside the app process, such as a web app, browser extension, or Bun/Node tool.
- Keep `voxd` out of the Apple app itself. If the goal is in-process app integration, embed the Swift packages directly instead.

## What embed mode is today

The current public embed surface is low-level but usable:

- ASR: `EngineManager`
- TTS generation: `TTSEngineManager`, `SynthesisRequest`
- optional Apple playback: `VoxAppleSpeech` / `AppleSpeechOutputController`
- outputs: `TranscriptionOutput`, `SynthesisOutput`, `TTSVoiceInfo`
- telemetry: `PerformanceRecorder`, `PerformanceSample`
- provider composition: `ProviderRegistry`, `TTSProviderRegistry`, `ProvidersConfig`, `ProviderEntry`

There is not yet a polished one-object Apple SDK facade. Agents should usually create a thin app-local wrapper such as `VoiceService` or `LineaVoiceStack` and keep raw Vox types behind that boundary. Use `VoxAppleSpeech` when the app wants a reusable per-audible-surface playback controller; keep product policy in the app.

## Package setup

`VoxCore` and `VoxEngine` support direct transcription embedding on macOS 14+
and iOS 17+. Minivox uses that same direct path and requires macOS 26+.

For a sibling repo during local development, prefer a local SwiftPM dependency:

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

actor LineaVoiceStack {
    private let clientId: String
    private let asr: EngineManager
    private let tts: TTSEngineManager
    private let performance = PerformanceRecorder()

    init(clientId: String = "linea-ios") {
        self.clientId = clientId
        self.asr = EngineManager()      // Parakeet
        self.tts = TTSEngineManager()   // OpenAI TTS plus AVSpeech fallback
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

- microphone permission
- audio capture
- temp-file creation for ASR input
- product-level spoken-output policy
- interruption handling
- product-level state and UX

Today the ASR entrypoint takes a `URL`, not an in-memory audio buffer. Agents should capture audio, write it to a temporary file, then call `transcribe(url:modelId:)`.

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

- ASR warm-up: `EngineManager.preload(modelId:progress:)`
- TTS warm-up: `TTSEngineManager.preload(modelId:voiceId:progress:)`

Do not hide warm-up behind app launch side effects unless the product intentionally chooses the `.eager` model download policy. Prefer `.onFirstUse` or warming on intent at a predictable app state transition.

## Telemetry

Companion mode records telemetry automatically. Embed mode does not.

If the app wants parity with Vox Companion telemetry, record samples yourself with `PerformanceRecorder` and preserve these dimensions:

- `clientId`
- `route`
- `modelId`
- `voiceId` for synthesis

Use the same route names Vox Companion uses:

- `transcribe.file`
- `synthesize.generate`

`RuntimePaths.performanceLogURL()` resolves to:

- macOS: `~/.vox/performance.jsonl`
- iOS: `Application Support/Vox/performance.jsonl`

## OpenAI TTS in embed mode

The default TTS surface is OpenAI-backed when an API key is configured:

- ASR: `EngineManager()` -> `ParakeetProvider()`
- TTS: `TTSEngineManager()` -> OpenAI TTS plus AVSpeech fallback
- default TTS model: `TTSDefaults.modelId` = `gpt-4o-mini-tts`
- local fallback TTS model: `TTSDefaults.localModelId` = `avspeech:system`

Prefer passing secrets in code or app configuration rather than relying on process environment inside an iOS app.

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

## Linea default plan

For the first Linea integration, the default plan should be:

- use embed mode on iOS and macOS
- add `VoxCore` and `VoxEngine`, plus `VoxAppleSpeech` if the app wants reusable Apple playback
- wrap Vox in one app-local actor or service
- use `parakeet:v3` for ASR; `parakeet:v2` is the English-only TDT option
- use `gpt-4o-mini-tts` for default TTS
- use `avspeech:system` only when a local system voice fallback is required
- record Vox-compatible telemetry from the app
- use Vox Companion only for web surfaces or cross-process workflows

## What agents should not assume

- There is no public one-object Apple SDK facade yet. `VoxAppleSpeech` is optional playback, not that facade.
- There is no public embed live-session coordinator yet.
- There is no public embed warm-up coordinator helper.
- Embed mode does not automatically write performance samples.
- Apple apps do not need `@voxd/sdk` or `@voxd/client`.
- `VoxAppleSpeech` does not own browser playback or app product policy.

## First tasks in a sibling app repo

1. Add `../vox/swift` as a local package dependency.
2. Create a single `VoiceService` or `LineaVoiceStack` actor in app code.
3. Warm the ASR and TTS engines explicitly.
4. Feed ASR with file URLs, not raw buffers.
5. Feed TTS output WAV data into the app playback layer, or use `AppleSpeechOutputController` for per-surface Apple playback.
6. Emit `PerformanceSample` records with stable route names.
7. Keep Companion mode out of the Apple app path unless the feature is genuinely web or cross-process.

See [Observability](./observability.md) for metric interpretation and [Architecture](./architecture.md) for package ownership.

## Packaged app resources

Copy `Vox_HudsonSpeechEngine.bundle` into the signed app's `Contents/Resources`.
`SpeechEngineResources` resolves the model catalog and mlx-audio provider script
from that location in apps, and from SwiftPM resources in command-line builds.
A packaged app does not fall back to a developer build directory.
