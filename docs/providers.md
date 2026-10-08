---
title: Provider Protocol
description: How external STT and TTS engines plug into Vox via JSON-RPC over stdin/stdout.
order: 35
---

Vox separates the runtime (mic capture, sessions, routing, telemetry, playback handoff) from the speech engine. Engines are called _providers_. They can be external processes or built-in bridges that speak JSON-RPC over stdin/stdout.

Provider configuration plugs directly into the companion runtime's install, preload, and route-dispatch flow. Read [Runtime](./runtime.md) alongside this spec if you want the full daemon-side picture.

Providers can serve either:

- ASR / STT: accept audio and return text
- TTS: accept text and return audio

Built-in providers include:

- `parakeet` for on-device CoreML ASR (`parakeet:v3` default, `parakeet:v2` English)
- `apple-speech` for Apple SpeechTranscriber (`apple:speech-transcriber`, macOS 26+ on Apple Silicon)
- `openai-transcribe` for remote OpenAI file transcription (`gpt-transcribe`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `whisper-1`)
- `avspeech` for system TTS
- `openai-tts` for remote TTS
- `elevenlabs` for ElevenLabs remote TTS
- `minimax` for MiniMax remote TTS
- `nvidia` for NVIDIA Magpie remote TTS
- `groq` for Groq Orpheus remote TTS
- `gemini` for Gemini remote TTS
- `mlx-audio` for built-in external bridging across both ASR and TTS, including Whisper, Qwen3-ASR, Cohere Transcribe, Nemotron 3.5, and Parakeet MLX ids

## Model catalog

Operator-facing catalog and plugin steps live in [Models and plugins](./models.md).

The published catalog at `https://voxd.cc/data/models.json` is the source of dictation model ids. The same file lives in the repo as `data/models.json` and is bundled with the engine as a fallback.

Each model names a `family`. Built-in families the engine can run without a plugin:

- `parakeet-tdt`: CoreML Parakeet TDT bundles
- `apple-speech`: Apple SpeechTranscriber and system-managed locale assets
- `mlx-audio`: Hugging Face ids loaded by the mlx-audio provider
- `openai-transcribe`: OpenAI Audio transcriptions API

New families ship as plugins in the same catalog. A plugin is an external JSON-RPC provider. The catalog advertises it; install is explicit; `voxd` loads `~/.vox/plugins/<id>/provider.json` on start.

```bash
vox plugins list
vox plugins install mlx-vlm
# restart voxd
vox transcribe file --model gemma-4-e2b-it /path/to/audio.wav
vox plugins remove mlx-vlm
```

Refresh is explicit:

```bash
vox models catalog
vox models catalog refresh
```

`VOX_MODEL_CATALOG_URL` overrides the catalog URL. A failed refresh keeps the bundled or cached snapshot. Catalog refresh never installs or runs a plugin command. `vox plugins install` copies a bundled runner or records an allowlisted launcher (`node`, `bun`, `npx`, `bunx`, `uv`, `uvx`, `python3`, `python`).

## Provider Config

Providers are registered in `~/.vox/providers.json`:

```json
{
  "providers": [
    {
      "id": "parakeet",
      "kind": "asr",
      "builtin": true,
      "models": ["parakeet:v3", "parakeet:v2"]
    },
    {
      "id": "apple-speech",
      "kind": "asr",
      "builtin": true,
      "models": ["apple:speech-transcriber"],
      "env": {
        "VOX_APPLE_SPEECH_LOCALE": "en-US"
      }
    },
    {
      "id": "avspeech",
      "kind": "tts",
      "builtin": true,
      "models": ["avspeech:system"]
    },
    {
      "id": "openai-tts",
      "kind": "tts",
      "builtin": true,
      "models": ["gpt-4o-mini-tts"],
      "env": {
        "OPENAI_API_KEY": "sk-...",
        "VOX_OPENAI_TTS_TIMEOUT_SECONDS": "12"
      }
    },
    {
      "id": "elevenlabs",
      "kind": "tts",
      "builtin": true,
      "models": ["eleven_multilingual_v2"],
      "env": {
        "ELEVENLABS_API_KEY": "..."
      }
    },
    {
      "id": "minimax",
      "kind": "tts",
      "builtin": true,
      "models": ["speech-2.8-hd"],
      "env": {
        "MINIMAX_API_KEY": "..."
      }
    },
    {
      "id": "nvidia",
      "kind": "tts",
      "builtin": true,
      "models": ["magpie-tts-multilingual"],
      "env": {
        "NV_API_KEY": "..."
      }
    },
    {
      "id": "groq",
      "kind": "tts",
      "builtin": true,
      "models": ["canopylabs/orpheus-v1-english"],
      "env": {
        "GROQ_API_KEY": "..."
      }
    },
    {
      "id": "gemini",
      "kind": "tts",
      "builtin": true,
      "models": ["gemini-2.5-flash-preview-tts"],
      "env": {
        "GEMINI_API_KEY": "..."
      }
    },
    {
      "id": "mlx-audio",
      "kind": "asr",
      "builtin": true,
      "env": {
        "VOX_MLX_AUDIO_PYTHON": "/path/to/venv/bin/python",
        "VOX_MLX_AUDIO_ASR_MODELS": "mlx-community/Qwen3-ASR-1.7B-8bit,mlx-community/cohere-transcribe-03-2026-mlx-8bit,mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit"
      }
    },
    {
      "id": "mlx-audio",
      "kind": "tts",
      "builtin": true,
      "env": {
        "VOX_MLX_AUDIO_PYTHON": "/path/to/venv/bin/python",
        "VOX_MLX_AUDIO_TTS_MODELS": "mlx-community/Soprano-1.1-80M-bf16,mlx-community/Kokoro-82M-4bit",
        "VOX_MLX_AUDIO_TTS_DEFAULT_VOICE": "af_heart"
      }
    }
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | `string` | Yes | Unique identifier for this provider. |
| `kind` | `"asr" \| "tts"` | No | Provider kind. Defaults to `asr` if omitted. |
| `builtin` | `boolean` | No | If `true`, Vox uses its bundled implementation for the given `id`. |
| `command` | `string[]` | No | Executable and arguments Vox will spawn for an external provider. |
| `models` | `string[]` | No | Model IDs this provider serves. Optional when the provider reports models dynamically. |
| `env` | `Record<string, string>` | No | Extra environment variables passed to the provider process. |

Notes:

- Vox supports Apple Silicon only. Do not treat successful remote-provider compilation on an Intel host as a supported configuration.
- Register ASR and TTS as separate entries even when they share the same `id`.
- `models` is optional for external providers now. Vox can call `models()` and route dynamically from the returned list.
- OpenAI, NVIDIA Magpie, Groq, and Gemini/Google accept per-request `credentials` on `synthesize.generate` / companion synthesis. Those keys are allowlisted through `VoxRuntimeService` and `VoxBridge`; unknown keys, including ElevenLabs and MiniMax keys, are dropped. ElevenLabs and MiniMax currently read only provider `env` and the process environment.
- Credential order for the providers that accept lent keys is per-request `credentials`, then provider `env`, then the process environment. An explicit provider `env` key or alias, even empty or whitespace, fences process fallback for both configured credential resolution and default model selection so a host can lend keys per request without inheriting an ambient secret. Process env is consulted only when no relevant credential key is present in provider `env` (including when `env` is omitted). Values are never logged or stored by the allowlist parser.
- NVIDIA Magpie, Groq, and Gemini synthesis HTTP errors redact the exact request text before a vendor body can be persisted or logged. JSON diagnostics keep useful vendor detail after secret and exact-prompt redaction. Plain-text non-JSON bodies fail closed whenever synthesis sensitive values (prompt or instructions) are supplied, including distinctive fragments such as `quota: ` plus a short prompt prefix. Voice discovery has no prompt and is not covered by that fail-closed path. This sanitization applies to these new remote providers; OpenAI, ElevenLabs, MiniMax, and AVSpeech keep their existing error surfaces.
- `ELEVENLABS_BASE_URL`, `ELEVENLABS_OUTPUT_FORMAT`, `MINIMAX_BASE_URL`, `NVIDIA_TTS_URL`, `NVIDIA_VOICES_URL`, `GROQ_BASE_URL`, and `GEMINI_BASE_URL` can override vendor defaults.
- NVIDIA Magpie accepts `NV_API_KEY` and the `NVIDIA_API_KEY` compatibility alias, plus camelCase / snake_case variants. Gemini accepts `GEMINI_API_KEY`, `GOOGLE_API_KEY`, and `GOOGLE_GENAI_API_KEY`.
- Remote providers are considered for default model selection and in-process default registration only when they are configured in `providers.json` or the daemon environment. An API key in the process environment is not broader user consent than selecting or configuring that provider. Configured aliases such as `magpie`, `groq-tts`, and `google-tts` prevent the canonical default entries from being appended over that family's routing and key config.
- If `providers.json` contains only ASR entries, Vox falls back to default TTS providers. The inverse is also true. The default TTS model remains `gpt-4o-mini-tts` when OpenAI is configured. App-registry and daemon/config default selection share one canonical ranking independent of `providers.json` order and independent of the alphabetically sorted `TTSProviderRegistry` model list: OpenAI `gpt-4o-mini-tts`, then ElevenLabs, MiniMax, NVIDIA Magpie, Groq, Gemini, then `avspeech:system`.
- The public ASR provider method is currently file-based. Apple SpeechTranscriber and Nemotron have streaming-capable internals, but live partial events require a separate runtime/protocol integration.
- Native audio adaptation uses `AVAudioConverter`, SpeechAnalyzer's file path, or provider-owned conversion. Provider adapters must not implement ad hoc resampling or denoising.

### OpenAI TTS timeout

`openai-tts` uses a hard wall-clock request timeout so stalled remote TTS calls do not block the caller for minutes.

- default: `12` seconds
- env override: `VOX_OPENAI_TTS_TIMEOUT_SECONDS`
- compatibility alias: `OPENAI_TTS_TIMEOUT_SECONDS`
- maximum accepted value: `30` seconds

The timeout can be set in the provider `env` block or the daemon process environment.

### NVIDIA Magpie TTS

`nvidia` is the first-class Vox home for NVIDIA Magpie TTS Multilingual, using the hosted NVIDIA Developer Inference contract:

- model id: `magpie-tts-multilingual`
- voice discovery: `GET /v1/audio/list_voices`
- synthesis: multipart `POST /v1/audio/synthesize`
- encoding: `LINEAR_PCM` at `44100` Hz
- default voice: `Magpie-Multilingual.EN-US.Aria`
- language is inferred from the Magpie voice id (`EN-US` → `en-US`)
- credentials: `NV_API_KEY`, with `NVIDIA_API_KEY` as a compatibility alias; per-request lent keys are accepted
- input limit: 2000 normalized characters; longer text is rejected rather than truncated
- URL overrides: `NVIDIA_TTS_URL`, `NVIDIA_VOICES_URL`, or `NVIDIA_BASE_URL`

If Magpie returns a valid WAVE container, Vox passes it through. If it returns aligned LINEAR PCM (`audio/l16` or similar), Vox wraps that PCM as 16-bit 44.1 kHz WAV so the public `SynthesisOutput` contract stays `format: "wav"`. Other payloads are rejected.

### Groq Orpheus TTS

`groq` uses Groq's OpenAI-compatible speech endpoint and requests `response_format: "wav"`:

- models: `canopylabs/orpheus-v1-english`, `canopylabs/orpheus-arabic-saudi`
- default voice: `autumn`
- input limit: 200 characters; longer text is rejected rather than truncated
- credentials: `GROQ_API_KEY`; per-request lent keys are accepted
- URL override: `GROQ_BASE_URL` (default `https://api.groq.com/openai/v1`)
- successful responses must be a structurally valid WAV; nonempty non-WAV bytes are rejected

### Gemini TTS

`gemini` uses the Gemini Generate Content API with `responseModalities: ["AUDIO"]`:

- models: `gemini-2.5-flash-preview-tts`, `gemini-2.5-pro-preview-tts`, `gemini-3.1-flash-tts-preview`
- default voice: `Puck`
- official prebuilt catalog includes `Rasalgethi` (not `Rasalas`)
- credentials: `GEMINI_API_KEY`, with `GOOGLE_API_KEY` / `GOOGLE_GENAI_API_KEY` as aliases; per-request lent keys are accepted
- URL override: `GEMINI_BASE_URL` (default `https://generativelanguage.googleapis.com/v1beta`); trailing slashes are normalized before joining `/models/{model}:generateContent`

Gemini 2.5 and Gemini 3.1 Flash TTS Preview share the Generate Content `responseModalities: ["AUDIO"]` contract. Vox does not use a separate Interactions API for these models.

Gemini typically returns `audio/L16` PCM. Vox wraps that PCM in a WAV container so callers still receive `SynthesisOutput.format = "wav"`. This is a lossless PCM container wrap, not a transcode.

## Protocol Methods

All communication uses newline-delimited JSON-RPC 2.0 over stdin (requests from Vox) and stdout (responses from the provider).

### `models`

List available models for the provider kind.

**Request:**

```json
{ "jsonrpc": "2.0", "id": 1, "method": "models" }
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "models": [
      {
        "id": "mlx-community/whisper-large-v3-turbo-asr-fp16",
        "name": "whisper-large-v3-turbo-asr-fp16",
        "backend": "mlx-audio",
        "installed": true,
        "preloaded": false,
        "available": true
      }
    ]
  }
}
```

### `install`

Download or prepare model files.

**Request:**

```json
{ "jsonrpc": "2.0", "id": 2, "method": "install", "params": { "modelId": "mlx-community/Kokoro-82M-4bit" } }
```

The provider can emit progress notifications on stdout during installation or preload:

```json
{ "jsonrpc": "2.0", "method": "progress", "params": { "modelId": "mlx-community/Kokoro-82M-4bit", "progress": 0.5, "status": "loading" } }
```

**Response:** `{ "model": { ... } }`, where `model` matches an entry returned by `models`.

### `preload`

Load a model into memory so subsequent requests start faster.

**Request:**

```json
{ "jsonrpc": "2.0", "id": 3, "method": "preload", "params": { "modelId": "mlx-community/Soprano-1.1-80M-bf16" } }
```

**Response:** `{ "model": { ... } }`, with `model.preloaded: true` after loading succeeds.

## ASR Methods

### `transcribe`

Transcribe an audio file.

**Request:**

```json
{ "jsonrpc": "2.0", "id": 4, "method": "transcribe", "params": { "modelId": "mlx-community/whisper-large-v3-turbo-asr-fp16", "path": "/tmp/audio.wav" } }
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "modelId": "mlx-community/whisper-large-v3-turbo-asr-fp16",
    "text": "Hello world",
    "elapsedMs": 142,
    "metrics": {
      "inferenceMs": 130,
      "modelLoadMs": 0,
      "audioLoadMs": 5,
      "audioPrepareMs": 2,
      "fileCheckMs": 1,
      "modelCheckMs": 1,
      "totalMs": 142
    },
    "words": [
      { "word": "Hello", "start": 0.12, "end": 0.44, "confidence": 0.99 },
      { "word": "world", "start": 0.45, "end": 0.71, "confidence": 0.98 }
    ]
  }
}
```

## TTS Methods

### `voices`

List available voices for a model. If `modelId` is omitted, Vox may call `voices` across multiple models and merge the results.

**Request:**

```json
{ "jsonrpc": "2.0", "id": 5, "method": "voices", "params": { "modelId": "mlx-community/Kokoro-82M-4bit" } }
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "voices": [
      {
        "id": "af_heart",
        "name": "af_heart",
        "language": "en-US",
        "backend": "mlx-audio",
        "modelId": "mlx-community/Kokoro-82M-4bit",
        "available": true,
        "default": true
      }
    ]
  }
}
```

### `synthesize`

Generate audio from text.

**Request:**

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "synthesize",
  "params": {
    "modelId": "mlx-community/Soprano-1.1-80M-bf16",
    "input": "Hello from Vox",
    "voiceId": "af_heart",
    "format": "wav",
    "speed": 1.0
  }
}
```

**Response:**

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "modelId": "mlx-community/Soprano-1.1-80M-bf16",
    "voiceId": "af_heart",
    "format": "wav",
    "contentType": "audio/wav",
    "audioBase64": "<base64 wav data>",
    "elapsedMs": 418,
    "metrics": {
      "audioDurationMs": 1024,
      "characterCount": 14,
      "modelCheckMs": 0,
      "modelLoadMs": 0,
      "voiceResolveMs": 1,
      "synthesisMs": 363,
      "totalMs": 418
    }
  }
}
```

## Metrics Contract

Providers must return stage timings in the `metrics` object of every `transcribe` or `synthesize` response. These feed into Vox telemetry tagged with `modelId`, `route`, and, for TTS, `voiceId`.

### ASR metrics

Required fields:

| Field | Type | Description |
|-------|------|-------------|
| `inferenceMs` | `number` | Time spent running the model. |
| `totalMs` | `number` | Wall-clock time for the entire request. |

Optional but recommended:

| Field | Type | Description |
|-------|------|-------------|
| `modelLoadMs` | `number` | Time loading the model (0 if already preloaded). |
| `audioLoadMs` | `number` | Time reading the audio file from disk. |
| `audioPrepareMs` | `number` | Time resampling or converting the audio. |
| `fileCheckMs` | `number` | Time validating the audio file exists and is readable. |
| `modelCheckMs` | `number` | Time checking the model is installed and ready. |
| `audioDurationMs` | `number` | Duration of the input audio. |

### TTS metrics

Required fields:

| Field | Type | Description |
|-------|------|-------------|
| `totalMs` | `number` | Wall-clock time for the entire request. |

Optional but recommended:

| Field | Type | Description |
|-------|------|-------------|
| `synthesisMs` | `number` | Time spent generating audio once the model is running. |
| `inferenceMs` | `number` | Accepted as a fallback alias for `synthesisMs`. |
| `modelLoadMs` | `number` | Time loading the model (0 if already preloaded). |
| `modelCheckMs` | `number` | Time checking the model is installed and ready. |
| `voiceResolveMs` | `number` | Time resolving the requested voice. |
| `audioDurationMs` | `number` | Duration of the synthesized audio. |
| `outputBytes` | `number` | Number of encoded output bytes. |
| `characterCount` | `number` | Length of the input text. |

## What Vox handles

Providers only deal with models plus transcription or synthesis. The runtime handles everything else:

- Mic permissions and capture -- ASR providers receive a WAV file path
- Audio format normalization for ASR input
- Playback handoff -- TTS providers return audio bytes and Vox hands them back to the caller
- Session lifecycle -- start, stop, cancel coordinated by the daemon
- Warm-up scheduling and state
- Client identity routing (`clientId`)
- Performance telemetry collection
- Provider execution capacity and backpressure -- requests are not globally serialized by default

## Provider execution model

Provider calls are asynchronous work items. Vox must not treat correctness as "only one provider request can exist at a time."

TTS providers, especially remote API-backed providers, should support concurrent `synthesize` calls. A client may submit many independent utterances and await their results independently. Playback ordering is a caller concern, not a provider-execution constraint.

ASR has more physical-resource constraints because microphone capture may involve one input device, permissions, and ownership. That constraint belongs to capture/session coordination, not to the provider protocol itself. File transcription and provider inference can still be concurrent when the selected backend has capacity.

Capacity should be explicit:

- providers may advertise or be configured with max concurrency
- Vox may apply per-provider or per-model backpressure when capacity is exhausted
- backpressure should return a typed busy/capacity error or queue metadata, not silently impose a global mutex
- telemetry should distinguish provider execution time from queue/wait time when queueing exists

## Writing a provider

### Rust ASR adapters

Rust is the default implementation language for new external ASR providers. Use the `vox-provider` crate in `providers/vox-provider/`. It owns JSON-RPC parsing, result envelopes, progress notifications, error responses, and stdout isolation. Implement the `AsrProvider` trait:

| Adapter method | Return value |
|---|---|
| `models()` | Model info list; inspect local state without downloading or loading weights |
| `install(model_id, progress)` | Installed model info; prepare assets without loading the model |
| `preload(model_id, progress)` | Model info after loading weights into memory |
| `transcribe(path, model_id)` | Text, model id, elapsed time, stage metrics, and optional word timings |

Use the supplied progress callback during installation or warm-up. Return `ProviderError` for an expected failure. Start the process with `serve(adapter)`. The adapter remains alive to retain model state between calls.

The host permits one operation per process. Overlapping calls receive JSON-RPC error `-32001` (busy). Invalid input and adapter failures return errors without ending the process. On stdin EOF, the host finishes the accepted operation and exits. On Unix, native stdout output is redirected to stderr while a separate descriptor carries protocol responses.

`providers/example/` is the runnable starter. It validates WAV input and returns sample text without an inference engine. `providers/whistle/` is the real engine adapter. Add a crate to `providers/Cargo.toml` for another engine. Use an existing audio conversion library and expose install and warm-up separately.

```bash
cargo run --manifest-path providers/Cargo.toml -p vox-provider-example
# Write one JSON-RPC request per line, for example:
# {"jsonrpc":"2.0","id":1,"method":"models","params":{}}
```

Swift continues to own the embedded Apple engine and the daemon. Other provider languages remain compatible with the same wire protocol.

### Bundling a provider

Add a directory under `packages/cli/plugins/<plugin-id>/` with `bundle.json` and a compiled executable:

```json
{
  "executables": { "darwin-arm64": "bin/darwin-arm64/vox-whistle" },
  "env": { "VOX_PROVIDER_CALL_TIMEOUT_SECONDS": "300" }
}
```

Keys identify the operating system and architecture used by Node (`darwin-arm64` for Apple Silicon). The installer selects the matching executable, copies the bundle into `VOX_HOME/plugins/<plugin-id>/`, and writes an absolute command path. Native executables must be regular files inside the bundle. Unsupported platforms and missing binaries fail before changing an existing installation. Plugin registration does not run the provider.

Build Whistle's Apple Silicon bundle on macOS:

```bash
rustup target add aarch64-apple-darwin
bun run build:providers
bun run --cwd packages/cli build
```

Rust is required to build providers from source. Installed providers run without Rust, Python, or `uv`. The package release workflow builds the binary on macOS and includes it in the CLI package. The CLI's prepack check rejects packages that lack a declared provider executable.

Add a catalog plugin with `install: { "kind": "bundle", "id": "<plugin-id>" }` and a model entry whose `plugin` field matches the plugin id. Then run `vox plugins install <plugin-id>` and restart `voxd`. Extend `scripts/build-providers.ts` when adding a compiled bundle.

Existing single-file `.mjs` bundles and interpreted directory bundles remain supported. Interpreted bundles use `command`, optional `shared` files from `plugins/shared/`, and `{pluginDir}` substitution. Their launcher is resolved using the installer's `PATH`.

Bundle manifests and files ship with the CLI. A remote catalog can select a shipped bundle; it cannot replace that bundle's command. Bundle paths, shared filenames, symlinks, and commands are validated before installation changes files.

Run `bun run test:providers` to test the Rust protocol and adapters. These tests do not download model assets. Use a separate `VOX_HOME` for a real installation and transcription check.

### Other runtimes

A provider is any executable that reads newline-delimited JSON-RPC from stdin and writes responses to stdout. Minimal TypeScript example:

```typescript
// minimal-provider.ts
import { createInterface } from "readline";

const rl = createInterface({ input: process.stdin });

for await (const line of rl) {
  const req = JSON.parse(line);

  if (req.method === "models") {
    respond(req.id, {
      models: [
        {
          id: "my-model:v1",
          name: "My Model",
          backend: "custom",
          installed: true,
          preloaded: false,
          available: true,
        },
      ],
    });
  }

  if (req.method === "transcribe") {
    const text = await myTranscribe(req.params.path);
    respond(req.id, {
      modelId: req.params.modelId,
      text,
      elapsedMs: 100,
      metrics: { inferenceMs: 95, totalMs: 100 },
    });
  }

  if (req.method === "voices") {
    respond(req.id, {
      voices: [
        {
          id: "default",
          name: "Default",
          backend: "custom-tts",
          modelId: req.params?.modelId ?? "my-tts:v1",
          available: true,
          default: true,
        },
      ],
    });
  }

  if (req.method === "synthesize") {
    const audioBase64 = await mySynthesize(req.params.input);
    respond(req.id, {
      modelId: req.params.modelId,
      voiceId: req.params.voiceId ?? "default",
      format: "wav",
      contentType: "audio/wav",
      audioBase64,
      elapsedMs: 120,
      metrics: { synthesisMs: 110, totalMs: 120 },
    });
  }
}

function respond(id: number, result: unknown) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}
```

Register it in `~/.vox/providers.json`:

```json
{
  "providers": [
    {
      "id": "my-provider",
      "kind": "asr",
      "command": ["bun", "run", "minimal-provider.ts"],
      "models": ["my-model:v1"]
    },
    {
      "id": "my-tts",
      "kind": "tts",
      "command": ["bun", "run", "minimal-provider.ts"],
      "models": ["my-tts:v1"]
    }
  ]
}
```

Then select it via CLI or SDK by specifying the target model ID.

## Provider lifecycle

Vox spawns the provider process on first use. It stays alive for the daemon's lifetime. If it crashes, Vox restarts it on the next request.

Providers should be stateless between requests. The provider process can keep model weights in memory, but Vox assumes nothing about that state -- a crash and restart must not break anything.
