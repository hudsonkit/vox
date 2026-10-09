---
title: Vox in your app
description: Add on-device dictation and speech output to a Swift app with VoxDictation, from package setup to a shippable app.
---

Vox in your app means your Swift app links the Vox packages and runs speech in its own process. Your users install nothing else.

You will end up with dictation in four calls: `warmUp()`, `start()`, `stop()` for text, or `cancel()`.

## 1. Add the package

In Xcode, choose **File → Add Package Dependencies…**, enter `https://github.com/hudsonkit/vox`, and add the `VoxCore` and `VoxEngine` libraries to your app target.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/hudsonkit/vox.git", from: "0.5.2"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "VoxCore", package: "vox"),
        .product(name: "VoxEngine", package: "vox"),
    ]),
]
```

Vox needs macOS 14 or iOS 17, on Apple Silicon.

## 2. Dictate

```swift
import VoxCore
import VoxEngine

let dictation = VoxDictation(clientId: "my-app")

// When the user shows intent, for example opening the compose view:
try await dictation.warmUp()

// Mic button down:
try await dictation.start()

// Mic button up:
let result = try await dictation.stop()
print(result.text)
```

- `warmUp()` downloads the speech model the first time (about 500 MB) and loads it into memory. Later launches only load it. Call it before the user needs it; if you don't, the first `stop()` waits for it. Pass a closure to show progress: `warmUp { progress in … }`.
- `start()` records the default microphone to a temporary file. `stop()` transcribes it, deletes the file and returns a `TranscriptionOutput` with `text`, `words` timings and `metrics`.
- `cancel()` stops and throws the audio away. `inputLevel()` gives a 0 to 1 level for a meter while recording.
- `start(onBuffer:)` hands you live 16 kHz audio buffers if you want your own waveform.

Already have audio? `try await dictation.transcribe(fileURL: url)` works on macOS and iOS.

The default model is `parakeet:v3`, which handles 25 European languages. `VoxDictation(clientId:modelId: "parakeet:v2")` uses the English-only model.

## 3. Ask for the microphone

Add `NSMicrophoneUsageDescription` to your Info.plist with a sentence your users will see, for example *"Dictation turns your voice into text on this Mac."*

A sandboxed Mac app also needs the **Audio Input** capability (`com.apple.security.device.audio-input`) and **Outgoing Connections** (`com.apple.security.network.client`) for the first model download.

## 4. Speak text

Speech output is a separate, optional piece. Add the `VoxAppleSpeech` library, then keep one controller per place in your app that talks:

```swift
import VoxCore
import VoxEngine
import VoxAppleSpeech

let speech = AppleSpeechOutputController(onEvent: { event in
    print(event.phase)   // .generating, .playing, .finished, .cancelled, .failed
})

await speech.speak(SynthesisRequest(text: "Your draft is saved.", modelId: TTSDefaults.localModelId))
await speech.stop()
```

A new `speak` replaces whatever was playing. `TTSDefaults.localModelId` is `avspeech:system`, the built-in system voice: on device, free, no key.

For a more natural voice, use `gpt-4o-mini-tts` (`TTSDefaults.modelId`). It calls OpenAI with your API key, so give the engine the key explicitly:

```swift
let engine = TTSEngineManager(provider: TTSProviderRegistry(config: ProvidersConfig(providers: [
    ProviderEntry(id: "avspeech", kind: .tts, builtin: true,
                  models: [AVSpeechSynthesizerProvider.modelID]),
    ProviderEntry(id: "openai-tts", kind: .tts, builtin: true,
                  models: OpenAITTSProvider.supportedModelIDs,
                  env: ["OPENAI_API_KEY": apiKey]),
])))
let speech = AppleSpeechOutputController(engine: engine)
await speech.speak(SynthesisRequest(text: "Your draft is saved.", modelId: TTSDefaults.modelId))
```

Vox does not fall back from OpenAI to the system voice on its own. If there is no key or no network, the request fails with `.failed`; choose the model in your app. Don't ship an OpenAI key inside an app binary: fetch a short-lived key from your server, or let users bring their own.

## 5. See where time goes

`VoxDictation` records the timings of every transcription to `~/.vox/performance.jsonl` on macOS, or `Application Support/Vox/performance.jsonl` on iOS, tagged with your `clientId`, the route (`transcribe.dictation` or `transcribe.file`) and the model. With the Vox command line installed:

```bash
vox perf dashboard --client my-app
```

Pass `recordsPerformance: false` to turn this off.

## 6. Ship it

- **Resource bundle.** Vox's model catalog lives in a SwiftPM resource bundle. Xcode copies it for you. If you package the app yourself, copy the bundle SwiftPM built, `Vox_HudsonSpeechEngine.bundle` or `HudsonSpeechEngine_HudsonSpeechEngine.bundle` depending on which package you depend on, into `YourApp.app/Contents/Resources`. A packaged app never falls back to a developer build directory.
- **Model download.** The first `warmUp()` downloads from Hugging Face. Ship with outgoing network allowed, and show progress.
- **Microphone and sandbox.** The usage string and entitlements from step 3.
- **Signing.** Nothing Vox-specific; sign and notarize as usual.

## On iOS

On iOS, `VoxDictation` preloads and transcribes files; `start()` is macOS only for now. Record with `AVAudioRecorder` or `AVAudioEngine` to a file, then call `transcribe(fileURL:)`. On iOS the app must also set up its own `AVAudioSession` for recording.

## A runnable example

[`examples/swift-embed`](https://github.com/hudsonkit/vox/tree/main/examples/swift-embed) is a small command-line program built on `VoxDictation`:

```bash
cd examples/swift-embed
swift run vox-embed-demo listen 5
swift run vox-embed-demo speak "Hello from Vox"
```

[Minivox](https://github.com/hudsonkit/vox/tree/main/apps/minivox) is a real menu-bar app built from the same pieces.

## Next

- Every type behind `VoxDictation`, other speech providers, and the speech output controller in depth: [Swift embed reference](./apple-embed.md).
- Other models: [Models and plugins](./models.md).
