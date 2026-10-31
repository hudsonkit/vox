---
title: Observability
description: Read Vox performance samples, stage timings, client dimensions, and operator dashboards.
---

Telemetry is built into the runtime for both transcription and synthesis. Each performance sample includes:

- `clientId`
- `route`
- `modelId`
- `voiceId` for synthesis routes when a voice is selected
- `outcome`
- nested `metrics`

## Metrics

Transcription metrics:

- `fileCheckMs`
- `modelCheckMs`
- `modelLoadMs`
- `audioLoadMs`
- `audioPrepareMs`
- `inferenceMs`
- `totalMs`
- `audioDurationMs`

Synthesis metrics:

- `modelCheckMs`
- `modelLoadMs`
- `voiceResolveMs`
- `synthesisMs`
- `totalMs`
- `audioDurationMs`
- `outputBytes`
- `characterCount`

Derived values: `realtimeFactor`, warm vs cold from `modelLoadMs`, audio-to-text speed from `audioDurationMs / inferenceMs`, and text-to-audio speed from `audioDurationMs / synthesisMs`.

## Storage

The runtime appends JSON lines to:

```text
~/.vox/performance.jsonl
```

The CLI dashboard reads from this file. You can also export it to another metrics backend.

Current emitted performance routes:

- `transcribe.file`
- `transcribe.live`
- `transcribe.streaming`
- `synthesize.generate`
- `synthesize.startSession`

Cancelled synthesis sessions are recorded under `synthesize.startSession` with `outcome: "cancelled"`.

## Operator Commands

```bash
vox transcribe file --metrics /tmp/sample.wav
vox transcribe bench /tmp/sample.wav 5
vox speak --metrics "hello world"
vox speak bench "hello world" 5
vox perf dashboard
vox perf dashboard --client vox-cli
```

## Reading the numbers

`inferenceMs`, `synthesisMs`, and `totalMs` measure different things.

- For ASR, `inferenceMs` is how fast the hot model ran.
- For TTS, `synthesisMs` is how long audio generation took once the request was inside the model.
- `totalMs` is what the user experienced end-to-end.

## Example sample

```json
{
  "timestamp": "2026-04-25T17:54:26Z",
  "clientId": "menu-bar",
  "route": "synthesize.generate",
  "modelId": "avspeech:system",
  "voiceId": "com.apple.voice.compact.en-US.Samantha",
  "outcome": "ok",
  "textLength": 14,
  "metrics": {
    "audioDurationMs": 1240,
    "synthesisMs": 182,
    "inferenceMs": 182,
    "totalMs": 196
  }
}
```

## Dashboard tips

- Only compare clients when the prompt or audio shape is similar.
- Use `inferenceMs` for loaded-model ASR speed.
- Use `synthesisMs` for loaded-model TTS speed.
- Use `totalMs` for end-user latency.
- Large `modelLoadMs` spikes are warm-up events, not inference regressions.

See [Runtime](./runtime.md) for emitted routes and [API](./api.md) for the current performance sample shape.

## Native ASR measurements

Build `vox-asr-bench` with `swift build --package-path swift -c release --product vox-asr-bench`. It accepts a model id, an explicit streaming model bundle directory, and a mono 16 kHz WAV. A directory of WAV files with matching `.txt` references produces a multi-utterance report. Batch `parakeet:v3` uses its installed `VOX_HOME` cache rather than the directory argument.

The JSON report separates preload and priming from dictation. It reports process `phys_footprint` in decimal MB, per-chunk latency, input-audio time at the first partial, unpaced compute time to that partial, and the encoder's compute-plan placement. Add `--paced` to feed capture packets in real time and measure wall-clock first-partial latency. Unpaced compute time is not user-perceived latency. WER scoring lowercases text and removes punctuation; it does not normalize abbreviations or number spellings.

These measurements exclude other processes and system-wide accelerator memory. Compare candidates on the same audio, host, and build configuration. A small smoke corpus is not a production accuracy evaluation.

### Private Parakeet reload comparison

`scripts/probe-parakeet-reload.py` supervises an opt-in production-runtime test of
fresh-process preparation, resident reuse, explicit unload and reload using an
existing pinned v3 bundle and generated silence. It records component logs,
physical footprint/lifetime peak, placement, disk and kernel memory pressure.
It does not install models or launch an app/daemon. Ordinary Swift tests skip it.

The experiment requires at least 5 GiB free disk and normal pressure before launch,
and rechecks the disk reserve before each nonresident load. It stops only its
verified owned caller at the resource/deadline limit; it never deletes caches or
signals the OS compiler. This reserve is an experiment policy, not a measured
Core ML minimum. See the [resource-pressure report](./reports/parakeet-reload-resource-pressure-2026-10-31.md)
for the command, partial results and unresolved cache-reuse question.
