---
title: API
description: Current companion RPC routes, TypeScript SDK entrypoints, result types, and performance shapes.
---

Public protocol and SDK-facing type shapes.

## RPC Methods

### Health and Runtime

- `health`
- `doctor.run`

### Models

- `models.list`
- `models.install`
- `models.preload`
- `models.catalog`
- `models.refreshCatalog`

Catalog JSON may include `plugins[]`. Plugin install is a CLI file-system action (`vox plugins install`), not an RPC. `voxd` loads `~/.vox/plugins/*/provider.json` at start.

### Warm-Up

- `warmup.status`
- `warmup.start`
- `warmup.schedule`

### Transcription

- `transcribe.stream.start`, `transcribe.stream.append`, `transcribe.stream.finish`, `transcribe.stream.cancel`, `transcribe.stream.status` (app-captured PCM; [wire contract](./runtime.md#pcm-wire-contract))
- `transcribe.file`
- `transcribe.startSession`
- `transcribe.sessionStatus`
- `transcribe.stopSession`
- `transcribe.cancelSession`

### Annotation

- `annotation.models` (explicit cloud capability inventory)
- `annotate.file` ([request, evidence and limits](./runtime.md#file-annotation))

### History

- `history.list`
- `history.get`
- `history.delete`
- `history.clear`

### Synthesis

- `synthesize.voices`
- `synthesize.generate`
- `synthesize.startSession`
- `synthesize.sessionStatus`
- `synthesize.cancel`

### Voice quality metadata

`synthesize.voices` returns optional `quality` on each voice: `standard`, `enhanced`
or `premium`. The native Apple provider reads `AVSpeechSynthesisVoice.quality`:
platform `.default` maps to `standard`; `.enhanced` and `.premium` map directly.
Unknown platform cases and other backends omit the field. Vox does not infer
quality from a voice name or identifier. See [Apple's quality enum](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoicequality).

Absent or null quality means **unknown**, not `standard`. The `default` selection
flag is independent of quality. Existing IDs, language, availability and default
selection are unchanged. Swift `TTSVoiceInfo.quality` is `TTSVoiceQuality?`;
TypeScript `VoiceInfo.quality` is optional. Swift decoding accepts older data
without quality and treats unrecognized future quality strings as nil.

## Performance samples

These fields are present on every performance sample recorded to `~/.vox/performance.jsonl`.

```ts
type PerformanceRoute =
  | "annotate.file"
  | "transcribe.file"
  | "transcribe.live"
  | "transcribe.streaming"
  | "synthesize.generate"
  | "synthesize.startSession"
  | string;
```

```ts
interface PerformanceSample {
  timestamp: string;
  clientId: string;
  route: PerformanceRoute;
  modelId: string;
  voiceId?: string;
  outcome: "ok" | "error" | "cancelled" | string;
  textLength: number;
  error?: string;
  metrics?: PerformanceMetrics;
}

interface PerformanceMetrics {
  traceId: string;
  audioDurationMs: number;
  wasPreloaded: boolean;
  modelCheckMs: number;
  modelLoadMs: number;
  inferenceMs: number;
  totalMs: number;
  inputBytes?: number;
  fileCheckMs?: number;
  audioLoadMs?: number;
  audioPrepareMs?: number;
  characterCount?: number;
  outputBytes?: number;
  voiceResolveMs?: number;
  synthesisMs?: number;
  realtimeFactor?: number;
}
```

Current emitted performance routes:

- `transcribe.file`
- `annotate.file`
- `transcribe.live`
- `transcribe.streaming`
- `synthesize.generate`
- `synthesize.startSession`

## Core TypeScript SDK Entry Points

### `VoxClient`

- `connect()`
- `disconnect()`
- `doctor()`
- `listModels()`
- `listCatalog()`
- `refreshCatalog()`
- `listVoices()`
- `installModel()`
- `preloadModel()`
- `getWarmupStatus()`
- `startWarmup()`
- `scheduleWarmup()`
- `transcribeFile()`
- `annotateFile()`
- `synthesize()`
- `getLiveSessionStatus()`
- `cancelLiveSession()`
- `createLiveSession()`

### `FileTranscriptionResult`

- `modelId`
- `text`
- `elapsedMs`
- `metrics`
- `words`

### `SynthesisResult`

- `modelId`
- `voiceId`
- `format`
- `contentType`
- `audio`
- `audioBytes`
- `elapsedMs`
- `metrics`

### `FileAnnotationResult`

- `modelId`
- `text`
- `elapsedMs`
- `metrics`
- `words`
- `speakers`

### `TranscriptionMetrics`

- `traceId`
- `audioDurationMs`
- `inputBytes`
- `wasPreloaded`
- `fileCheckMs`
- `modelCheckMs`
- `modelLoadMs`
- `audioLoadMs`
- `audioPrepareMs`
- `inferenceMs`
- `totalMs`
- `realtimeFactor`

### `SynthesisMetrics`

- `traceId`
- `characterCount`
- `audioDurationMs`
- `outputBytes`
- `wasPreloaded`
- `modelCheckMs`
- `modelLoadMs`
- `voiceResolveMs`
- `synthesisMs`
- `inferenceMs`
- `totalMs`
- `realtimeFactor`

### `AnnotationMetrics`

- `traceId`
- `audioDurationMs`
- `inputBytes`
- `wasPreloaded`
- `fileCheckMs`
- `modelCheckMs`
- `modelLoadMs`
- `audioLoadMs`
- `audioPrepareMs`
- `diarizationMs`
- `totalMs`
- `realtimeFactor`

## Interface shapes

```ts
interface TranscriptionMetrics {
  traceId: string;
  audioDurationMs?: number;
  inputBytes?: number;
  wasPreloaded?: boolean;
  fileCheckMs?: number;
  modelCheckMs?: number;
  modelLoadMs?: number;
  audioLoadMs?: number;
  audioPrepareMs?: number;
  inferenceMs?: number;
  totalMs?: number;
  realtimeFactor?: number;
}

interface FileTranscriptionResult {
  modelId: string;
  text: string;
  elapsedMs: number;
  metrics?: TranscriptionMetrics;
  words: WordTiming[];
}

interface SpeakerSegment {
  speakerId: string;
  start: number;
  end: number;
  confidence?: number | null;
}

interface AttributedWordTiming {
  word: string;
  start: number;
  end: number;
  confidence: number | null;
  logProbability?: number | null;
  speakerConfidence?: number | null;
  language?: string | null;
  speakerId?: string | null;
}

interface AnnotationMetrics {
  traceId: string;
  audioDurationMs: number;
  inputBytes: number;
  wasPreloaded: boolean;
  fileCheckMs: number;
  modelCheckMs: number;
  modelLoadMs: number;
  audioLoadMs: number;
  audioPrepareMs: number;
  diarizationMs: number;
  totalMs: number;
  realtimeFactor: number;
}

interface FileAnnotationResult {
  modelId: string;
  text?: string;
  elapsedMs: number;
  metrics?: AnnotationMetrics;
  words: AttributedWordTiming[];
  speakers: SpeakerSegment[];
  providerId?: string | null;
  providerRequestId?: string | null;
  providerModelIds?: string[];
  duration?: number | null;
  durationSource?: string | null;
  language?: string | null;
  languageConfidence?: number | null;
  languages?: string[];
  audioEvents?: Array<{label: string; start: number; end: number; speakerId?: string | null; logProbability?: number | null}>;
  speakerSegmentsSource?: string | null;
  unsupportedFields?: string[];
  unavailableFields?: string[];
}

interface SynthesisOptions {
  modelId?: string;
  voiceId?: string;
  format?: string;
  speed?: number;
  instructions?: string;
  speechTiming?: boolean | SpeechTimingRequest;
  credentials?: {
    OPENAI_API_KEY?: string;
    openaiApiKey?: string;
    openai_api_key?: string;
    NV_API_KEY?: string;
    NVIDIA_API_KEY?: string;
    nvApiKey?: string;
    nvidiaApiKey?: string;
    nv_api_key?: string;
    nvidia_api_key?: string;
    GROQ_API_KEY?: string;
    groqApiKey?: string;
    groq_api_key?: string;
    GEMINI_API_KEY?: string;
    GOOGLE_API_KEY?: string;
    GOOGLE_GENAI_API_KEY?: string;
    geminiApiKey?: string;
    googleApiKey?: string;
    googleGenaiApiKey?: string;
    gemini_api_key?: string;
    google_api_key?: string;
    google_genai_api_key?: string;
  };
}

interface SpeechTimingRequest {
  enabled?: boolean;
  modelId?: string;
  cues?: Array<{
    id: string;
    text?: string;
    textStart?: number;
    textEnd?: number;
  }>;
}

interface SynthesisMetrics {
  traceId: string;
  characterCount: number;
  audioDurationMs: number;
  outputBytes: number;
  wasPreloaded: boolean;
  modelCheckMs: number;
  modelLoadMs: number;
  voiceResolveMs: number;
  synthesisMs: number;
  inferenceMs: number;
  totalMs: number;
  realtimeFactor: number;
}

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

interface SpeechTiming {
  source: "asr" | "native" | "estimated" | string;
  modelId: string;
  elapsedMs: number;
  words: SpeechTimingWord[];
  cues: SpeechTimingCue[];
}
```

## Warm-up states

```ts
type WarmupState = "idle" | "scheduled" | "warming" | "ready" | "failed";
```

Apps use this to tell whether the runtime is cold, warming, or ready for hot-path speech.

See the [SDK Guide](./sdk.md) for usage patterns and [Runtime](./runtime.md) for route ownership and session semantics.
