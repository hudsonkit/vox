---
title: Vox for Node
description: Transcribe, dictate and speak from a Bun or Node tool through Vox on your Mac.
---

`@voxd/sdk` lets a Bun or Node program use the speech engine in the Vox app on the same Mac. The model stays loaded across every tool that uses it.

## 1. Run Vox on your Mac

Install and open the Vox app, then check it: see [Vox on your Mac](./start-mac.md#install-the-vox-app).

```bash
bunx @voxd/cli@latest doctor        # expect ready: true
```

## 2. Install the SDK

```bash
bun add @voxd/sdk          # or: npm install @voxd/sdk
```

## 3. Transcribe a file and speak a line

```ts
import { writeFile } from "node:fs/promises";
import { VoxClient } from "@voxd/sdk";

const vox = new VoxClient({ clientId: "my-tool" });
await vox.connect();

await vox.preloadModel("parakeet:v3");
const result = await vox.transcribeFile("/absolute/path/to/audio.wav", "parakeet:v3");
console.log(result.text, `${Math.round(result.elapsedMs)} ms`);

const speech = await vox.synthesize("Hello from Vox.", { modelId: "avspeech:system", format: "wav" });
await writeFile("hello.wav", speech.audio);

vox.disconnect();
```

- `clientId` names your tool in Vox's timings. Pick something stable.
- `preloadModel` loads the model before the first request. Skip it and the first transcription waits for the load.
- File paths must be absolute: Vox reads the file itself.
- `avspeech:system` is the Mac's system voice. For `gpt-4o-mini-tts`, add an OpenAI key in the Vox app, or pass `credentials: { OPENAI_API_KEY }` in the options.

## 4. Dictate with live text

Vox records from the Mac's microphone and streams partial text while the user speaks:

```ts
const session = vox.createLiveSession();
session.on("partial", ({ text }) => process.stdout.write(`\r${text}`));

const done = session.start();
setTimeout(() => session.stop(), 5000);
console.log("\n" + (await done).text);
```

The first live session makes macOS ask whether Vox may use the microphone.

## Runnable example

[`examples/node-hello`](https://github.com/hudsonkit/vox/tree/main/examples/node-hello):

```bash
cd examples/node-hello
bun install
bun run index.ts path/to/audio.wav
```

## Next

- Every method, the result shapes and error codes: [Node SDK reference](./sdk.md).
- Timings by tool and model: `vox perf dashboard --client my-tool`, see [Observability](./observability.md).
