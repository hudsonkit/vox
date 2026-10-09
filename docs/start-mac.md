---
title: Vox on your Mac
description: Try Minivox in sixty seconds, then install the Vox app so Node tools and web pages can use speech on your Mac.
---

## Try Minivox in 60 seconds

Minivox is the smallest dictation app built on Vox. It needs macOS 26.

```bash
bunx @voxd/cli@latest install mini
```

1. Put the text cursor wherever you want the words.
2. Press **Right ⌘M** and allow microphone and Accessibility access.
3. Speak, then press **Right ⌘M** again. The text is copied and pasted where your cursor was.

The first dictation downloads the speech model, about 500 MB, so expect a pause once. Run `minivox settings` to change the shortcut or microphone.

Minivox uses [Vox in your app](./start-swift.md): there is no daemon, just a Swift app linking the Vox packages. Its source is in [`apps/minivox`](https://github.com/hudsonkit/vox/tree/main/apps/minivox) and short enough to read in one sitting.

## Install the Vox app

Install Vox on your Mac when other programs should share one speech engine: Node and Bun tools, web pages, browser extensions, the command line.

1. Download Vox from [voxd.cc/download](https://voxd.cc/download) and drag it to Applications.
2. Open it. Vox lives in the menu bar and starts the local engine.
3. Check it from a terminal:

```bash
bunx @voxd/cli@latest doctor        # expect ready: true
```

The app runs two local endpoints, both on `127.0.0.1` only:

| Endpoint | Used by | Default port |
|---|---|---|
| WebSocket engine | `@voxd/sdk`, the CLI | `42137` |
| HTTP bridge | `@voxd/client` in web pages | `43115` |

The HTTP bridge runs inside the Vox app. If only the engine is running, for example after `vox daemon start`, Node tools work but web pages will not find Vox.

## Try it from the terminal

```bash
alias vox="bunx @voxd/cli@latest"
vox warmup start parakeet:v3                   # preload the model
vox transcribe file --metrics recording.wav   # text plus stage timings
vox speak --model avspeech:system "Hello"     # system voice, no key needed
vox perf dashboard                             # timings by app and model
```

## Next

- Use it from code: [Vox for Node](./start-node.md) or [Vox for the browser](./start-browser.md).
- All commands, benchmarks and troubleshooting: [Command line](./quickstart.md).
