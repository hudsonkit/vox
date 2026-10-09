---
title: Start here
description: Pick the shortest path to working speech with Vox, in your app, on your Mac, from Node, or from the browser.
---

Vox is open-source speech-to-text and text-to-speech for Mac apps. Transcription runs on your Mac. Speech output uses the system voice on device, or a cloud voice when you bring a key.

Pick the row that matches what you are building. Each path ends with something you can run.

| You are building | Start with | Runs where | First result |
|---|---|---|---|
| Just want to try it | [Try Minivox](./start-mac.md#try-minivox-in-60-seconds) | macOS 26 | Dictate anywhere, paste the text |
| A Swift app | [Vox in your app](./start-swift.md) | Inside your app | `VoxDictation` start, stop, text |
| A Bun or Node tool | [Vox for Node](./start-node.md) | Talks to Vox on your Mac | Transcribe a file, speak a line |
| A web page or extension | [Vox for the browser](./start-browser.md) | Talks to Vox on your Mac | Dictate into a page |
| Anything, with a coding agent | [Build with an agent](./start-agent.md) | Wherever the agent works | A prompt that wires Vox in |

## Two ways Vox runs

- **Vox in your app.** Your Swift app links the Vox packages and runs speech in its own process. Nothing else to install for your users.
- **Vox on your Mac.** The Vox app runs a local engine that other programs talk to: Node and Bun tools over WebSocket, web pages over a local HTTP bridge. Your users install Vox once; every tool on the Mac shares one loaded model.

Both keep the same habits:

- **Preload.** Loading a model takes seconds the first time. Vox makes that step explicit (`warmUp`, `preloadModel`) so you can do it when the user shows intent, not on their first word.
- **Timings.** Every transcription can record how long each stage took, tagged with your app's name, so you can see where time goes. See [Observability](./observability.md).

## Requirements

- An Apple Silicon Mac. Intel Macs are not supported.
- macOS 14 or later for Vox in your app; macOS 26 or later for Minivox and the Vox app.
- iOS 17 or later for file transcription inside an iOS app.
- Bun 1.2 or later, or Node 22 or later, for the TypeScript packages.

## What Vox does not do yet

Saying this up front saves you an afternoon:

- **No microphone capture on iOS.** On iOS, record audio in your app and hand Vox the file. Microphone capture in `VoxDictation` is macOS only.
- **No live partial text inside your app.** In-app dictation returns the transcript when you stop. Live partials are available through Vox on your Mac (the browser and Node live sessions).
- **Speech output is not all local.** The default high-quality voice, `gpt-4o-mini-tts`, calls OpenAI and needs your API key. The local option is the system voice, `avspeech:system`. Vox does not switch between them for you.
- **The browser client only listens.** `@voxd/client` transcribes and aligns. To speak text, use Node, the CLI, or Swift.

## Reference

Once something runs, these pages hold the details:

- [Swift embed reference](./apple-embed.md): every embed type, speech output, packaging.
- [Node SDK reference](./sdk.md) and [Browser client reference](./web-integration.md).
- [Command line](./quickstart.md): install, health checks, benchmarks.
- [Models and plugins](./models.md), [Providers](./providers.md), [Observability](./observability.md).
