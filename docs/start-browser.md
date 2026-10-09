---
title: Vox for the browser
description: Add dictation and file transcription to a web page or extension through Vox on your Mac.
---

`@voxd/client` lets a web page or browser extension use Vox on the visitor's Mac through a small HTTP bridge on `127.0.0.1`. No server of yours handles the audio.

The browser client listens and transcribes. To speak text, use [Node](./start-node.md), the command line, or [Swift](./start-swift.md).

## 1. Run Vox on your Mac

Install and open the Vox app: see [Vox on your Mac](./start-mac.md#install-the-vox-app). The bridge runs inside the app, so the app must be open, not only the background engine.

## 2. Allow your page's origin

Vox only answers pages it trusts. Any `http://localhost` or `http://127.0.0.1` port is allowed out of the box, so local development needs no setup.

For your own domain, add it in the Vox app's settings, or drop a JSON file into `~/.vox/origins.d/`:

```json
{"origins":["https://app.example.com"]}
```

## 3. Install the client

```bash
bun add @voxd/client       # or: npm install @voxd/client
```

## 4. Find Vox, then dictate

```ts
import { createVoxdClient } from "@voxd/client";

const vox = createVoxdClient({ clientId: "my-site" });

if (await vox.probe()) {
  const session = vox.createLiveSession();
  session.onPartial(({ text }) => { output.textContent = text; });

  stopButton.onclick = () => session.stop();
  const final = await session.start();
  output.textContent = final.text;
}
```

- `probe()` returns `false` quickly when Vox is not running, so it is safe on every page load. Offer a link to [voxd.cc/download](https://voxd.cc/download) in that case.
- Vox records from the Mac's microphone, so your page needs no microphone permission of its own.
- An origin that is not allowed fails on the first call after `probe()`, such as `capabilities()` or `start()`.

## Transcribe a file or recording

```ts
const result = await vox.transcribe({ audio: file, timestamps: true });
result.text;    // full transcript
result.words;   // [{ word, start, end }, ...]
```

`audio` takes a `Blob`, `File` or `ArrayBuffer`.

## Runnable example

[`examples/web-hello`](https://github.com/hudsonkit/vox/tree/main/examples/web-hello) is one HTML page with dictation and file upload:

```bash
cd examples/web-hello
bun install
bun run start            # http://localhost:3000
```

## Next

- Alignment jobs, fallbacks, error codes and the bridge endpoints: [Browser client reference](./web-integration.md).
