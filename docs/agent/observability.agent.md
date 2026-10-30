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
