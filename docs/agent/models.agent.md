# Models and plugin facts

- catalog URL: `https://voxd.cc/data/models.json`
- repo source: `data/models.json`
- bundled fallback: `swift/Sources/HudsonSpeechEngine/Resources/models.json`
- cache: `~/.vox/cache/models-catalog.json`
- override: `VOX_MODEL_CATALOG_URL`
- refresh: `vox models catalog` / `vox models catalog refresh`; RPC `models.catalog` / `models.refreshCatalog`
- SDK: `listCatalog()`, `refreshCatalog()`
- catalog refresh never installs or runs a plugin
- default ASR: `parakeet:v3`; English TDT: `parakeet:v2`
- Apple Silicon only; Intel Macs are unsupported
- native core ASR: `apple:speech-transcriber` on macOS 26+
- Apple locale env: `VOX_APPLE_SPEECH_LOCALE`
- recommended MLX candidates: `mlx-community/Qwen3-ASR-1.7B-8bit`, `mlx-community/cohere-transcribe-03-2026-mlx-8bit`, `mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit`
- Native coreml-streaming models have liveTranscription=true through NativeStreamingASR.shared / transcribe.stream.*; file-only models remain false. Old daemon-microphone startSession remains record-then-transcribe.
- never add hand-written resampling or denoising inside a model adapter; use platform/provider DSP libraries
- OpenAI file ASR: `gpt-transcribe`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe`, `whisper-1`
- plugins CLI: `vox plugins list|install|remove`
- plugin store: `~/.vox/plugins/<id>/provider.json`
- `voxd` loads installed plugins at start
- Gemma 4 E2B: model `gemma-4-e2b-it`, plugin `mlx-vlm`
- plugin launchers: `node`, `bun`, `npx`, `bunx`, `uv`, `uvx`, `python3`, `python`; install resolves launchers to absolute paths
- Whistle: model/plugin `whistle`, family `cactus-whistle`, optional Rust provider using prebuilt Needle CPU runtime; no Needle text model
- Whistle setup: bundled Apple Silicon executable; `vox plugins install whistle`, restart voxd, `vox models install whistle`, `vox models preload whistle`
- provider runs without Python/uv/Rust installed; only model install downloads weights/runtime; model listing does not load weights
- Whistle: file ASR up to 30 seconds, word timestamps/confidence, one operation per process; overlapping calls return busy
- Whistle adapter uses Symphonia/Rubato for audio conversion; `liveTranscription=false`
- Whistle assets: `VOX_HOME/models/whistle`; transcribe can cold-load installed assets but cannot download them
- Whistle env: `VOX_WHISTLE_LANGUAGE` (en/de/fr/es/it/nl/pl, unset auto), `VOX_WHISTLE_KEYWORDS` (comma-separated)

- Native ASR requires Apple Silicon, macOS 14.4 / iOS 17.4 for compute-plan verification.
- Default live id: StreamingASRDefaults.modelId; file default: parakeet:v3, pinned 7dd20fe (August 19 conversion).
- Models/preload surfaces include planned computePlacement; streaming status exposes residency and owner.
- CoreML streaming installation is disk-only; preload explicitly loads/primes; idle unload default macOS 900 s / iOS 60 s; native inventory exposes actual idleUnloadSeconds.
- Batch and streaming share one process-wide native model slot; multiple app processes use one authenticated private Unix host.

- Current live default: nemotron:unified-560ms (Nemotron Labs Unified, Oct 28 conversion bd13ddd); 160 ms stride + 400 ms right context, buffered re-encode, not encoder-cache streaming.
- Nemotron 3.5 Latin cache-aware alternative: nemotron:streaming-560ms, 560 ms chunks.
