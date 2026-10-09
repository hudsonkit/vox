---
title: SDK (Companion Client)
description: Typed Bun and Node access to Vox Companion over local WebSocket JSON-RPC.
---

> Use `@voxd/sdk` when you want a Bun or Node tool to talk to `voxd` over local WebSocket JSON-RPC. For Apple apps, embed the Swift packages directly. For web apps or browser extensions, use [`@voxd/client`](./web-integration.md) instead.

`packages/client/` connects to `voxd` when you want out-of-process access to models, voices, warm-up, transcription, synthesis, and stage metrics.

`listCatalog()` and `refreshCatalog()` read the published dictation catalog. Plugin install stays on the CLI (`vox plugins install`). See [Models and plugins](./models.md).

## Example

```ts
import { VoxClient } from "@voxd/sdk";

const client = new VoxClient({ clientId: "menu-bar" });

await client.connect();
await client.scheduleWarmup("parakeet:v3", 500);

const transcript = await client.transcribeFile("/tmp/sample.wav", "parakeet:v3");
const voices = await client.listVoices("avspeech:system");
const speech = await client.synthesize("Hello from Vox", {
  modelId: "avspeech:system",
  voiceId: voices[0]?.id,
  format: "wav",
});

console.log(transcript.text);
console.log(transcript.metrics?.inferenceMs);
console.log(transcript.words);
console.log(speech.audioBytes);
console.log(speech.metrics?.synthesisMs);

client.disconnect();
```

## Client Identity

`clientId` is used to attribute latency by consumer, compare route-level behavior across integrations, and support multi-client workflows.

## Main methods

```ts
interface VoxClientSurface {
  connect(): Promise<void>;
  disconnect(): void;
  doctor(): Promise<unknown>;
  listModels(): Promise<unknown>;
  listCatalog(): Promise<SpeechModelCatalog>;
  refreshCatalog(): Promise<SpeechModelCatalog>;
  listVoices(modelId?: string): Promise<unknown>;
  installModel(modelId?: string): Promise<unknown>;
  preloadModel(modelId?: string): Promise<unknown>;
  getWarmupStatus(modelId?: string): Promise<unknown>;
  startWarmup(modelId?: string): Promise<unknown>;
  scheduleWarmup(modelId?: string, delayMs?: number): Promise<unknown>;
  transcribeFile(path: string, modelId?: string): Promise<FileTranscriptionResult>;
  annotateFile(path: string, options?: AnnotationOptions): Promise<FileAnnotationResult>;
  synthesize(text: string, options?: SynthesisOptions): Promise<SynthesisResult>;
  getLiveSessionStatus(): Promise<LiveSessionStatus | null>;
  cancelLiveSession(sessionId?: string): Promise<{ cancelled: boolean; sessionId: string }>;
  createLiveSession(): VoxLiveSession;
}
```

## File result shape

```ts
interface FileTranscriptionResult {
  modelId: string;
  text: string;
  elapsedMs: number;
  metrics?: TranscriptionMetrics;
  words: WordTiming[];
}
```

## Synthesis result shape

```ts
interface SynthesisResult {
  modelId: string;
  voiceId: string;
  format: string;
  contentType: string;
  audio: Uint8Array;
  audioBytes: number;
  elapsedMs: number;
  metrics?: SynthesisMetrics;
  speechTiming?: SpeechTiming;
}
```

## Error handling

All client methods throw when `voxd` is unreachable, the model isn't installed, or a transcription or synthesis request fails. Errors are plain `Error` instances, so check `message` for a human-readable description.

```ts
try {
  const result = await client.transcribeFile("/tmp/audio.wav");
} catch (err) {
  // Common causes:
  // - Companion not running: start with `vox daemon start`
  // - Model not installed: run `vox models install` first
  // - Voice mismatch: inspect `client.listVoices(modelId)`
  // - Request failed: daemon logs have details (`vox logs daemon`)
  console.error(err.message);
}
```

For live sessions, call `session.cancel()` in a `finally` block to ensure the microphone is always released:

```ts
const session = await client.createLiveSession();
try {
  // ...use session
} finally {
  await session.cancel();
}
```

## Configuration

```ts
const client = new VoxClient({
  clientId: "menu-bar",    // stable identity for telemetry
  port: 42137,             // override the `companion-ws` daemon port
  host: "127.0.0.1",       // override daemon host
});
```

On the daemon side, set `VOX_PORT` or `VOX_HOST` environment variables to override defaults. `VOX_PORT` controls the `companion-ws` daemon port discovered from `~/.vox/runtime.json`.

## Integration advice

- embed Swift directly for macOS and iOS apps; use `@voxd/sdk` when you want Vox Companion access from JS or tooling
- use a stable `clientId` per product surface such as `menu-bar`, `browser-extension`, or `vox-cli`
- warm on intent, not on every keystroke
- call `listVoices(modelId)` before pinning a TTS voice in product code
- benchmark with representative audio clips and read `inferenceMs` separately from `totalMs`
- preserve raw transcription and synthesis metrics in your own telemetry if the app already exports traces
