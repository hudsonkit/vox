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

## Embedded Parakeet lifecycle

For an iOS app that owns native batch ASR, keep a concrete `ParakeetProvider`.
It implements `ASRProvider` and can also be injected into `EngineManager`.
No daemon, private socket, Python/MLX runtime or FluidAudio loader is required.
Batch policy remains explicitly `parakeet:v3`. These APIs require a source revision
containing the lifecycle change; older published package ranges do not provide
the new unload/delete methods. Pin the integration revision until released.

```swift
import Foundation
import VoxCore
import VoxEngine

let batch = ParakeetProvider()
let inventory = await batch.models()           // no download, Core ML load or compilation
let directory = try batch.modelDirectory(modelId: "parakeet:v3") // read-only location
let installed = try await batch.install(modelId: "parakeet:v3") { event in
    print(event.status, event.progress)         // download/structural validation only
}
let ready = try await batch.preload(modelId: "parakeet:v3") { event in
    print(event.status, event.progress)         // load, ANE placement check, priming
}
try await batch.setIdleUnload(modelId: "parakeet:v3", seconds: StreamingASRDefaults.idleUnloadSeconds)
// The app owns capture and provides a finalized audio file to batch.transcribe.
let unloaded = try await batch.unload(modelId: "parakeet:v3")
let deleted = try await batch.deleteModel(modelId: "parakeet:v3")
```

**Install is now download-only for Parakeet.** Earlier revisions also loaded and
primed during `install`. Call `preload` explicitly when ready to pay the cold-load
cost. `installed` means the required bundle files exist, not that their Core ML
contents have been loaded, compiled or verified for ANE execution. Inventory and
location lookup never create a model or compile on CPU to validate files.

- `unload(modelId:)` clears the actual shared runtime Session and its model-bearing
  closures. It returns an `ASRModelInfo` snapshot with `preloaded: false` and no
  placement. Other provider instances see that same released Session. Cache actors
  and manifest metadata stay shared; this is not just clearing one app reference.
- `deleteModel(modelId:)` unloads first, then removes only that Vox-owned revision.
  It returns the actual installation/runtime snapshot. Missing storage is
  idempotent. It never deletes siblings, FluidAudio stores, the model-store root,
  older revision directories or Core ML's system/compiler caches. On a filesystem
  error deletion may be partial and the runtime can already be unloaded; refresh
  inventory rather than presenting a cached success state.
- Both methods throw `ParakeetLifecycleError.busy` while any provider owner has
  admitted installation, warmup, file preparation or inference for that model.
  They do not steal active inference. Stop requesting work, wait for admitted work
  to settle, then retry. Same-model installation and warmup are single-flight;
  cancelling a waiter does not stop another owner's shared download/load.
- `setIdleUnload(modelId:seconds:)` is process/model-scoped, including other owners
  of the shared runtime. Default is 900 s on macOS and 60 s on iOS, optionally
  configured by `VOX_ASR_IDLE_SECONDS`; zero explicitly disables idle eviction.
  The setter rejects invalid values. Native inventory includes the actual
  `ASRModelInfo.idleUnloadSeconds`; this is not a promise of fast reload.
  Idle eviction never interrupts active operations. Cold preparation must remain
  visible in app UI; do not silently pin models to hide startup cost.
- Use `modelDirectory(modelId:)` for display or inspection, not caller-owned
  recursive deletion. Talkie does not need manifest/cache path knowledge.
  Owned-store deletion uses descriptor-relative traversal without following
  symlinks below the trusted Vox home. Receipts bind new storage to model ID,
  repository and revision. Known built-in legacy layouts remain manageable;
  unreceipted custom nonempty directories and mismatched receipts are refused.
- The reservation is process-local. Do not share one embedded store across app
  processes without higher-level ownership coordination. On macOS, intentionally
  shared clients should continue using `voxd`, not embed a second engine.
- Unloaded means Vox released its Session references, not a guarantee of immediate
  RSS reduction or an OS-wide cache purge. Readiness/placement comes from the
  runtime snapshot, never an app-maintained boolean inferred from a wrapper release.

The shared engine uses its process-selected conversion/store revision. Catalog
refresh does not hot-swap a cached Parakeet engine; restart the process for a
conversion revision change. Defaults remain pinned to the current shipped v3
conversion. No lifecycle method imports a foreign FluidAudio installation.

The complete [`examples/parakeet-lifecycle`](https://github.com/hudsonkit/vox/tree/main/examples/parakeet-lifecycle)
consumer imports only public `VoxCore`/`VoxEngine` and is compiled for ARM64 iOS
Simulator in CI. Simulator supports integration compilation, not ANE inference:
production Parakeet advertises `available: false` there. Native inference requires
supported Apple Silicon hardware and macOS 14.4 / iOS 17.4 or newer. No physical
iOS placement, memory or accuracy result is implied by a Simulator build.

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
- reports typed phases (`resolving` or `generating`, `starting`, `playing`, `paused`, `resumed`, `wordRange`, `finished`, `cancelled`, `failed`)
- reports requested vs actual model/voice identity separately from the physical audio-output route; it does not invent a provider id

Do not treat this controller as browser playback, OpenScout Ranger policy, or app product policy. Reply dedupe, markdown flattening, fallback copy, preference storage, queue priority, and telemetry double-recording stay in the app.

Audio-session configuration is injectable and disabled by default. There is no singleton and no process-global playback mutex; two controllers may run independently.

Route/model capability (`SpeechOutputCapabilities`) tells the controller whether a model is live system delivery or generated bytes. That capability does not add `speak()` to `TTSProvider`.

### Pause, resume, seek and highlighting

Use `start(_:)` when you need an identity for controls. The older `speak(_:)`
entrypoint and current-surface `stop()` / `cancel()` remain source-compatible.
Prefer identity-scoped controls for asynchronous UI actions:

```swift
import VoxCore
import VoxEngine
import VoxAppleSpeech

let output = AppleSpeechOutputController(onEvent: { event in
    // Hop to the app's UI actor. Check event.identity against its current
    // request/generation there before applying state or event.utf16Range.
})
let request = SynthesisRequest(text: "Read this original text", modelId: TTSDefaults.localModelId)
var identity = try await output.start(request)
// After a playing event, and only when its capabilities.canPauseResume is true:
let pauseAccepted = try await output.pause(identity)
// For system speech, wait for paused acknowledgement before resuming.
let resumeAccepted = try await output.resume(identity)
// Seek restarts the ORIGINAL request's suffix; preserve the replacement identity.
identity = try await output.seek(identity, toUTF16Offset: 5)
try await output.stop(identity)
```

`status()` and every event expose `SpeechPlaybackCapabilities`. These are actual
sink capabilities; they do not promise every voice accepts every control. During
resolution capabilities can be unavailable. Pause requires `playing`/`resumed`,
resume requires `paused`, and only one system control can await acknowledgement.
A true system control return means AVFoundation accepted it; `didPause` /
`didContinue` drive the `paused` / `resumed` events. A false return does not invent
a state change. Pause does not stop, regenerate or reset the utterance/player.

| Sink | Pause/resume | UTF-16 ranges | Seek by replacement |
|---|---|---|---|
| Built-in live system speech | Yes, accepted/acknowledged separately | Native will-speak callbacks only | Yes, original-text suffix |
| Built-in generated-audio player | Yes, retained player position | Unavailable | Unavailable |
| Existing custom sink | Unsupported by default | Unsupported by default | Unsupported by default |

`SpeechOutputEvent.identity` includes both `requestId` and `generation`. Seek keeps
the original request ID and returns a new generation; stop/cancel/seek reject stale
identities without touching the current surface. Invalid seek offsets leave
current playback intact. Seek accepts an original-text UTF-16 **character boundary**
before nonempty remaining text, not a byte offset, grapheme count, time or fraction.
It starts a replacement utterance rather than preserving a paused state. Voice,
speed and original text remain unchanged. Request replacement emits one cancelled
event for the old generation, then starts the new one.

Only `wordRange` events contain `utf16Range: SpeechUTF16Range?` (`location`, `length`,
plus `nsRange`). System utterance-relative ranges are validated and shifted to the
**original, unmodified request text**, including repeated seeks. Invalid bounds,
overflow and split surrogate pairs are discarded. These callbacks anticipate the
spoken word; they are not acoustic timestamps or forced alignment. Generated audio
never fabricates ranges. Do not apply ranges to separately normalized or edited text.

The controller fences request AND generation before emitting callbacks. An event
already emitted to a caller's UI queue cannot be retracted; validate its identity
again after the actor/queue hop. Custom sinks opt into controls through the new
protocol requirements, whose defaults remain unsupported. Their pause/resume
implementations must be genuine; system sinks must acknowledge through typed
callbacks carrying the original identity. Audio-session/interruptions and UI policy
stay with the application.

See the public-only [readout consumer](../examples/apple-readout/README.md), compiled
for iOS Simulator in CI. No audible device run or physical-iOS behavior is implied
by its synthetic tests and compilation. The [readout verification report](./reports/apple-readout-controls-2026-10-30.md) records coverage and limits.

### Per-request output pitch and volume

Keep generation parameters in `SynthesisRequest` and local playback parameters in
`SpeechOutputOptions`. This prevents unsupported pitch from being silently passed
to a cloud generation provider:

```swift
let identity = try await output.start(
    SynthesisRequest(text: originalText, modelId: TTSDefaults.localModelId, speed: 1.2),
    options: SpeechOutputOptions(pitchMultiplier: 0.6, volume: 0.4)
)
// Or try await output.speak(request, options: options) when no token is needed.
```

`pitchMultiplier` accepts finite **0.5...2.0**; `volume` accepts finite **0...1**.
Both are optional Doubles; nil leaves the platform default. Values are validated
before replacing current playback, not silently clamped. Invalid values throw
`invalidPitchMultiplier` / `invalidVolume` synchronously from `start` or the explicit
options `speak` overload. The older no-options `speak(_:)` remains unchanged.

Events/status report the requested `options` and actual `canSetPitch` / `canSetVolume`
capabilities. Built-in live system speech supports both, setting the utterance
properties **before enqueue**. Pause/resume and seek-as-replacement preserve them.
A subsequent request with nil options gets fresh platform defaults, not the previous
request's settings. Explicit defaults such as pitch=1 still require sink support.

Built-in generated audio supports local player volume, not pitch. Pitch requests
fail before synthesis. Volume is checked/applied to the actual generated-audio
sink before play. With custom player factories this check necessarily occurs after
generation; unsupported or declined volume fails without playing. Existing custom
sinks default both capabilities to false; a player opting into volume must implement
`setVolume(_:) -> Bool`. A false return rejects the option.

Unsupported options discovered during asynchronous route/player resolution emit an
identity-bearing terminal `failed` event with typed `controlError` (`unsupportedPitch`
/ `unsupportedVolume`) and human-readable `error`, not a successful request with
ignored controls. Do not parse localized error text to classify unsupported options. Observe terminal events, not only
the initial `start` return. No generated-audio pitch shift, word alignment or
provider synthesis pitch/volume parameter is fabricated by this output API.

## Warm-up

Warm-up must remain explicit.

- dictation: `VoxDictation.warmUp(progress:)`
- ASR warm-up: `EngineManager.preload(modelId:progress:)`
- TTS warm-up: `TTSEngineManager.preload(modelId:voiceId:progress:)`

Do not hide warm-up behind app launch side effects. Warm on intent at a predictable app state transition, such as opening the screen that dictates. Without warm-up, the first transcription pays the model load.

## Telemetry

Companion mode records telemetry automatically. In embed mode, `VoxDictation` records a sample for every transcription (pass `recordsPerformance: false` to opt out). `NativeStreamingASR.finish` also records its session, preserving clientId, route, and modelId; pass `recordPerformance: false` when the caller records it. The lower-level file engines do not.

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

- ASR: `EngineManager()` -> `NativeASRProvider()` (batch Parakeet plus explicit streaming models)
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
- `VoxDictation` still records then transcribes. Use `NativeStreamingASR.shared` with app-captured PCM for model-backed partials.
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

## App-captured streaming ASR

Use `NativeStreamingASR.shared` when the app needs partial transcripts before capture stops. This API requires physical Apple Silicon hardware and macOS 14.4 or iOS 17.4, so Core ML placement can be verified. Simulator inventory advertises unavailable and production preload refuses before model loading; Simulator compilation is not ANE support. The app supplies finite mono 16 kHz float32 PCM; use platform audio conversion, not a custom resampler.

```swift
import VoxCore
import VoxEngine

let asr = NativeStreamingASR.shared
let modelId = StreamingASRDefaults.modelId
// Explicit user-initiated warmup, not an app-launch side effect.
_ = try await asr.preload(modelId: modelId, progress: { progress in
    print(progress.status)
})
let sessionId = try await asr.begin(clientId: "my-app", modelId: modelId)
// Feed 1–16000 samples per call; await each call before sending the next packet.
let updates = try await asr.append(
    sessionId: sessionId, clientId: "my-app", samples: capturedSamples
)
for update in updates { print(update.text, update.endOfUtterance) }
let final = try await asr.finish(sessionId: sessionId, clientId: "my-app")
print(final.text, final.words)
// On interruption/error, call cancel instead of finish. It discards pending audio and text.
```

`preload(modelId:directory:language:progress:)` can use an explicitly supplied offline model bundle. Without a directory, preload installs missing assets. Installation alone is available through `install(modelId:progress:)` and does not instantiate models. Warmups for the same model join one flight. Start requires a ready model and never performs warmup.

The runtime has one active owner and one loaded native ASR model per process. Batch Parakeet and streaming share that residency slot. Idle unload defaults to 900 seconds on macOS and 60 seconds on iOS; call `setIdleUnload(seconds:)` to configure it. A model switch still replaces the one resident model. The desktop window reduces eviction churn, not Core ML compiler latency; see the [idle/reload investigation](./reports/idle-reload-2026-10-30.md). Call `status()` to inspect the loaded model, planned encoder device assignment, and owner. Word timings are approximate RNNT emission frames. See [Native PCM streaming](./runtime.md#native-pcm-streaming) for endpoint semantics and lifecycle limits.

For several app processes, deliberately use one `VoxRuntimeService` host or `voxd` over the authenticated private Unix transport. Each app sends PCM using the `transcribe.stream.*` routes. Do not embed a separate model in every app when the product intends shared residency.
