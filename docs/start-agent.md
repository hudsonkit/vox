---
title: Build with an agent
description: Copy-paste prompts that get a coding agent to add Vox to your project correctly the first time.
---

Coding agents do well with Vox when they read the right page first. Each prompt below points the agent at one page and states the facts it most often gets wrong.

Every page on this site has a compact agent version, and the whole set is at [voxd.cc/llms.txt](https://voxd.cc/llms.txt) and [voxd.cc/llms-full.txt](https://voxd.cc/llms-full.txt).

## Add dictation to a Swift app

```text
Add on-device dictation to this app with Vox. Read https://voxd.cc/docs/start-swift first and follow it.

- Add the Swift package https://github.com/hudsonkit/vox (products VoxCore and VoxEngine).
- Use VoxDictation. Call warmUp() when the user opens the screen that dictates, not at app launch.
- Wire a mic button: start() on press, stop() on release, put result.text into the text field.
- Add NSMicrophoneUsageDescription to Info.plist.
- On iOS, start() is not available: record to a file and call transcribe(fileURL:).
- Keep clientId stable; it names this app in Vox's timings.
```

## Add spoken replies to a Swift app

```text
Add spoken output to this app with Vox. Read https://voxd.cc/docs/start-swift#4-speak-text first.

- Add the VoxAppleSpeech product from https://github.com/hudsonkit/vox.
- Use one AppleSpeechOutputController per place in the UI that speaks.
- Default to the system voice, TTSDefaults.localModelId. Only use gpt-4o-mini-tts if the user supplies an OpenAI key; Vox does not fall back between them automatically.
- Never hard-code an API key in the app.
```

## Use Vox from a Bun or Node tool

```text
Use Vox on this Mac for speech in this tool. Read https://voxd.cc/docs/start-node first.

- Install @voxd/sdk and connect with new VoxClient({ clientId: "<this tool's name>" }).
- Call preloadModel("parakeet:v3") before the first transcription.
- Pass absolute file paths to transcribeFile.
- If connect() fails, tell the user to open the Vox app (https://voxd.cc/download).
```

## Add dictation to a web page

```text
Add dictation to this web page using Vox on the visitor's Mac. Read https://voxd.cc/docs/start-browser first.

- Install @voxd/client and create the client with a stable clientId.
- Call probe() on load; if false, show a link to https://voxd.cc/download and hide the mic button.
- Use createLiveSession(): onPartial for live text, start() to begin, stop() to finish.
- localhost works out of the box. For production, the origin must be added in Vox settings or ~/.vox/origins.d/.
- The browser client does not speak text.
```

## What agents get wrong without these

- Inventing a `VoxClient` in Swift. Swift apps use `VoxDictation` and the Swift packages, never the TypeScript SDK.
- Calling `warmUp()` at launch, which costs memory before the user asks for anything, or never calling it, which makes the first dictation slow.
- Assuming the OpenAI voice falls back to the system voice.
- Assuming iOS can record through Vox.
- Using the old `github.com/arach/vox` URL. The repository is `github.com/hudsonkit/vox`.
