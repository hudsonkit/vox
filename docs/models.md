---
title: Models and plugins
description: Published dictation catalog, built-in families, and how Vox plugins install new ASR runtimes.
order: 34
---

The published catalog at `https://voxd.cc/data/models.json` is the source of dictation model ids. The same file lives in the repo as `data/models.json` and is bundled with the engine as a fallback.

Refresh the local snapshot explicitly:

```bash
vox models catalog
vox models catalog refresh
```

`VOX_MODEL_CATALOG_URL` overrides the catalog URL. A failed refresh keeps the bundled or cached snapshot. Catalog refresh never installs a plugin and never runs a plugin command.

## Built-in families

These families run without a plugin:

| Family | Default or typical ids | How it runs |
|---|---|---|
| `parakeet-tdt` | `parakeet:v3` (default), `parakeet:v2` (English) | On-device CoreML |
| `apple-speech` | `apple:speech-transcriber` | On-device Speech framework; macOS 26+ |
| `openai-transcribe` | `gpt-transcribe`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `whisper-1` | OpenAI Audio API; needs `OPENAI_API_KEY` |
| `mlx-audio` | Qwen3-ASR, Cohere Transcribe, Nemotron 3.5 ASR Streaming, Whisper turbo, Parakeet MLX ids | mlx-audio provider; opt-in in `providers.json` |

`parakeet:v3` stays the default for Minivox, Vox.app, and CLI warmup. Use `parakeet:v2` when you want the English-only TDT bundle.

Apple SpeechTranscriber is registered by the default daemon, so selecting its model id is enough. Apple downloads locale assets through `AssetInventory`; `VOX_APPLE_SPEECH_LOCALE` selects the locale.

## Current local shortlist

- `parakeet:v3`: default, mature CoreML path, 25 European languages.
- `apple:speech-transcriber`: system-managed on-device parity option with word timings on macOS 26+.
- `mlx-community/Qwen3-ASR-1.7B-8bit`: multilingual accuracy candidate on Apple Silicon.
- `mlx-community/cohere-transcribe-03-2026-mlx-8bit`: strong offline multilingual candidate; not a realtime model.
- `mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit`: 0.6B cache-aware streaming RNNT candidate covering 35 languages.

Catalog `capabilities.liveTranscription` describes what Vox exposes today, not what an upstream model architecture can theoretically do. It remains `false` for every current provider because Vox's public ASR contract still accepts a completed audio file and returns finalized text. Apple and Nemotron are streaming-capable foundations for the next runtime slice, but selecting them does not yet turn `session.partial` into model-backed partial transcription.

Vox does not ship Intel support. Local runtime entries are marked `architectures: ["arm64"]`. Audio conversion for native model inputs uses platform or provider libraries; do not add hand-written sample-rate conversion or denoising code to a model adapter.

SDK catalog methods:

```ts
await client.listCatalog();
await client.refreshCatalog();
```

RPC routes: `models.catalog`, `models.refreshCatalog`.

## Plugins

A plugin is an external JSON-RPC provider advertised in the catalog `plugins[]` array. Models point at a plugin with a `plugin` field.

Install is a CLI filesystem action, not an RPC:

```bash
vox plugins list
vox plugins install mlx-vlm
# restart voxd
vox transcribe file --model gemma-4-e2b-it /path/to/audio.wav
vox plugins remove mlx-vlm
```

`vox plugins install` writes `~/.vox/plugins/<id>/provider.json`. `voxd` loads those files at start and merges them into the provider registry.

Gemma 4 E2B (`gemma-4-e2b-it`) uses plugin `mlx-vlm`. The bundled runner speaks the provider protocol and calls mlx-vlm when `VOX_MLX_VLM_PYTHON` or `python3` has that package. Without mlx-vlm the plugin stays installed and reports `available=false`.

Plugin launchers are allowlisted: `node`, `bun`, `npx`, `bunx`, `uv`, `uvx`, `python3`, `python`. Native bundles can also launch a compiled executable inside their own plugin directory. Bundled plugins take their command from the CLI's bundle manifest. Installation writes an absolute command path so the daemon can start it without a shell.

### Cactus Whistle

Whistle runs in an optional Rust provider process with Cactus's prebuilt Needle CPU runtime on Apple Silicon. The compiled provider ships with the CLI and needs no Python, `uv`, or Rust installation. It loads only the speech model:

```bash
vox plugins install whistle
# restart voxd
vox models install whistle
vox models preload whistle
vox transcribe file --model whistle --metrics --timestamps /path/to/audio.wav
```

Plugin registration copies the compiled provider and writes `provider.json`. `models install` downloads the speech weights and native runtime. `models preload` loads the installed model into the persistent helper. Model listing does not download weights or load the model.

Assets are stored under `VOX_HOME/models/whistle` (default `~/.vox/models/whistle`). Transcription can load installed weights on its first call; `models preload` moves that work out of the transcription request. Neither operation downloads missing model assets.

Set `VOX_WHISTLE_LANGUAGE` in the provider's `env` to `en`, `de`, `fr`, `es`, `it`, `nl`, or `pl` to select a language. An unset value uses language detection. `VOX_WHISTLE_KEYWORDS` accepts comma-separated words for keyword biasing. Restart `voxd` after changing provider environment values.

The adapter accepts audio files up to 30 seconds and returns finalized text with word timestamps and confidence. Audio decoding and 16 kHz mono conversion use Symphonia and Rubato. This provider exposes file transcription; its catalog entry keeps `liveTranscription=false`.

Whistle's runtime has one shared model state per process. The helper accepts one operation at a time and returns a busy error for overlapping requests. After an error, callers can retry on the same process. Removing the plugin unregisters the helper; downloaded model assets remain available for reinstallation.

The [Whistle model card](https://huggingface.co/Cactus-Compute/whistle) documents the supported languages and model. The [Needle repository](https://github.com/cactus-compute/needle) documents the native runtime; the Rust adapter calls its C interface directly. Model installation downloads the pinned weights and runtime binary, checks their hashes, and keeps them for offline inference.

See the [Provider Protocol](./providers.md) for the stdin/stdout contract a plugin must implement.
