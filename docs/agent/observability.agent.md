# Observability Facts

- primary operator commands:
  - `vox transcribe file --metrics /path/to/audio.wav`
  - `vox transcribe bench /path/to/audio.wav 5`
  - `vox speak --no-play --output /tmp/out.wav "hello world"`
  - `vox speak bench "hello world" 5`
  - `vox perf dashboard`
- inference speed should be evaluated from `inferenceMs` / `synthesisMs`, not `totalMs`
- total latency should be evaluated from `totalMs`
- exported dimensions:
  - `clientId`
  - `route`
  - `modelId`
  - `voiceId` for synthesis

- Native streaming performance route: `transcribe.streaming`, preserving clientId/modelId.
- `vox-asr-bench` (Swift executable) reports physical process footprint, per-chunk latency, first partial by input-audio time and unpaced compute time, planned placement, and normalized WER when references exist.
- Benchmark takes model id, explicit streaming model directory (batch uses installed VOX_HOME cache), and a mono 16 kHz WAV or a directory of WAV + matching .txt references. Use `--paced` for wall-clock first-partial latency.
- Run a release build; distinguish cold preload/ANE compile time from warm inference, and process footprint from system-wide accelerator memory.

- Native diagnostics distinguish CoreML load stage (component model-load/compute-plan) and prediction stage (Parakeet preprocessor, encoder, aggregate decoder-joint). Opaque spanId groups one chunk across workers; includes queue/specialization time, not hardware counters; never sum concurrent spans as wall time. No audio/tokens/paths/raw errors. Numeric error chains max3 allowlisted domains. No concurrency/configuration/placement/eviction changes.
- Gate evidence: reports/native-dev-reload-2026-10-31.md. Controlled post-unload inference successes do not close the normal-Agent plan-failure/slow-prime gate; green CI is not native acceptance.

- Standalone scripts/probe-coreml-cache.swift: model-plan / shared-asset / plan-only, existing encoder only, no predictions/downloads/cache deletion/retries/retained models. macOS15+ANE, 5GiB before APIs, launch pressure1 then noncritical; private new report; weak model/plan/asset teardown. Explicit release+pause is NOT the runtime idle timer. CI --describe only, no hardware acceptance.
- Storage cache eviction can occur even with gigabytes free and memory pressure1/2. Track entries/purge events; ambiguous log --start strings are local time, --timezone UTC changes output. Keep raw logs private and distinguish correlation from per-file deleter proof.
