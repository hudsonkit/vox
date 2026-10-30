# Native ASR selection, 2026-10-30

## Decision

Use **Nemotron Labs Unified 0.6B**, `nemotron:unified-560ms`, as the live default. The selected int8 Core ML conversion was published October 28. It meets the M1 streaming budget, uses less process memory than the older Nemotron candidates, and had the lowest streaming WER in this smoke corpus. Keep **Parakeet TDT v3** as the file default, pinned to the August 19 conversion.

Unified is buffered streaming, not a cache-aware encoder: it re-encodes a rolling window of up to 6.16 seconds, carries the RNNT prediction state, decodes only new frames, and retains 400 ms of right context. The 160 ms stride gives more frequent update opportunities than Nemotron 3.5's 560 ms chunks. The tradeoff is a later first partial: 1.52 s versus 1.12 s on the input-audio timeline in this subset. Do not describe the 560 ms algorithmic window as a measured 560 ms first-word latency.

The [NVIDIA model card](https://huggingface.co/nvidia/nemotron-labs-unified-asr-0.6b) describes the new checkpoint and its offline/streaming comparison with Parakeet v3 and Nemotron 3.5. The local results below are independent measurements, not NVIDIA's benchmark numbers.

## Host and method

- Apple M1, 16 GiB, macOS 27.0.1, Xcode Swift 6.4, release build.
- One ASR benchmark process at a time on a working, memory-pressured host. Background system/app work was not suspended. These are single passes, not isolated laboratory results.
- First 12 rows of `hf-internal-testing/librispeech_asr_dummy`, `clean/validation`, revision `5be91486e11a2d616f4ec5db8d3fd248585ac07a`: 12 utterances, 308 reference words, one speaker. Input is mono 16 kHz PCM, fed in 80 ms packets.
- WER lowercases and removes punctuation. It does not normalize abbreviations or number spellings. For example, `mr` and `mister` count as different words. This small corpus cannot establish production accuracy across accents, speakers, languages, or noise.
- Footprint is process `phys_footprint` in decimal MB after load **and explicit priming**, then after finish/reset. These are event snapshots, not peak allocations. Other processes and system-wide accelerator allocations are excluded.
- Chunk timing measures synchronous front-end/encoder/RNNT work before returning its update; it excludes transport, capture pacing, and the final autorelease-pool drain. Cadence differs by model; compare timing with the stride, not just with other rows.
- First-partial numbers in the table are median **input-audio time consumed before a nonempty partial**, not unpaced wall time. The benchmark's `--paced` mode measures wall-clock latency separately.

## Measurements

After-dictation footprint shows the **first / twelfth** utterance. Placement is preferred **ANE / CPU operation count** from `MLComputePlan`; constants are excluded. Quantization/constexpr operations without a scheduled device are recorded separately in the JSON, not counted as CPU fallback. There were no GPU operations.

| Model | Loaded MB | After dictation MB, first / twelfth | Chunk compute mean / p95 ms | First partial, audio ms | WER | Encoder ANE / CPU ops |
|---|---:|---:|---:|---:|---:|---:|
| `nemotron:unified-560ms` | 70.6 | 58.3 / 49.5 | 43.0 / 71.4 | 1520.0 | 3.57% (11/308) | 1400 / 47 |
| `nemotron:streaming-560ms` | 77.2 | 71.8 / 47.5 | 101.0 / 206.3 | 1120.0 | 5.84% (18/308) | 1620 / 60 |
| `nemotron:en-streaming-560ms` | 96.7 | 93.5 / 61.6 | 167.0 / 410.1 | 1120.0 | 4.55% (14/308) | 1616 / 56 |
| `parakeet:eou-320ms` | 33.5 | 38.5 / 35.0 | 52.1 / 130.8 | 1280.0 | 6.82% (21/308) | 1206 / 46 |
| `parakeet:eou-160ms` | 37.5 | 34.3 / 34.1 | 18.5 / 34.0 | 960.0 | 12.01% (37/308) | 1179 / 33 |
| `parakeet:v3` | 95.5 | 96.6 / 78.4 | file median 167.5 | — | 3.90% (12/308) | 1379 / 6 |

Parakeet v3's inference number is a **whole-file median**, not a streaming chunk. Its four compiled model programs and weight hashes were verified against the pinned conversion before reusing the existing cache. It has no first-partial event.

Strides: Unified 160 ms (400 ms right context), Nemotron 3.5 and older English 560 ms, EOU 320 ms 320 ms (630 ms input window), EOU 160 ms 80 ms (160 ms input window). Unified's measured 43.0 ms mean / 71.4 ms p95 fit its 160 ms step. Its 344 convolution/linear/matmul operations were planned on ANE, with none of those compute operations on CPU; scheduled estimated ANE cost fraction was 99.93%.

The two small CPU pre-encode convolutions in the older Nemotron plans are not a whole CPU encoder fallback: planned ANE cost fractions were 98.64% (3.5) and 98.36% (English). Placement policy permits that small CPU share, but rejects compute-free ANE assignments and mostly-CPU encoders. A failed placement check releases the instance, retries once, and then fails closed. A compute plan reports **planned placement**, not a hardware execution trace.

Cold process load, compute-plan preparation, and priming were expensive on this host: approximately 61–122 s across streaming candidates; Unified took 94.1 s. File Parakeet preload/prime took 78.1 s. These costs are excluded from warm chunk/first-partial measurements. Clients must await explicit preload and allow a cold compile; readiness is not a launch side effect.

## Paced and private-host validation

A separate paced run of the first utterance plus three seconds of trailing silence returned the first partial after **1655.8 ms wall time**, at 1520 ms of supplied audio. The final transcript had 0/17 word errors. It emitted a `blank-duration` endpoint and finished at 55.6 MB process footprint. This is one paced utterance, not a latency distribution.

A real `voxd` private Unix test used two authenticated connections and the selected model. It received 46 nonempty partial updates, 17 timestamped final words, and a blank-duration endpoint. A foreign connection could not append/cancel or start a competing owner. Disconnect released ownership; cancel discarded without a final transcript; a two-second test idle timeout unloaded the model. Test capture used a WAV fixture, not microphone permission or an operator recording.

## Memory and lifecycle findings

The first native streaming prototype retained Core ML temporary providers/tensors across cooperative-executor jobs. In a 12-utterance run, Nemotron 3.5 rose from 81.6 MB after the first utterance to 261.2 MB after the twelfth. Explicit per-chunk and per-reset Objective-C autorelease pools removed that accumulation: the corresponding final run ended at 47.5 MB, with a maximum post-dictation snapshot of 71.8 MB. The selected Unified run ended at 49.5 MB; its maximum post-dictation snapshot was 58.3 MB.

Batch and streaming share one process-wide native model-bundle slot. A lease prevents another client or preload from evicting an active session. Same-model warmups join one initialization flight. Idle unload defaults to 60 s, configurable with `VOX_ASR_IDLE_SECONDS` or the embedded setter. Installation validates files/byte counts without instantiating or compiling a CPU model.

CI exposed a separate existing issue: external-provider stdout/stderr readers used blocking `FileHandle.availableData` inside `Task.detached`, starving the bounded Swift cooperative executor on a small runner. Both readers now use dedicated Foundation threads, avoiding starvation of both Swift and GCD worker pools. The focused strict-cooperative-executor regression check completes both transport tests rather than consuming the executor's only worker.

## Candidate provenance and exclusions

- [Unified Core ML conversion](https://huggingface.co/FluidInference/nemotron-labs-unified-asr-0.6b-coreml), revision `bd13ddde81d3134719c520845346b3252daf3175`: `70_2_5_int8`, October 28. It uses the pinned English Nemotron Core ML mel front-end, then NeMo per-feature normalization. No FluidAudio Swift package or Python runtime is linked.
- [Nemotron 3.5 Latin Core ML](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML), revision `1a41b75758b0337ff67db7d5408280aaaf23074e`: `latin/560ms`. The conversion is the latest available in that repository; its card identifies an older base-checkpoint date. It is not presented as a conversion of every later NVIDIA update.
- [English Nemotron Core ML](https://huggingface.co/FluidInference/nemotron-speech-streaming-en-0.6b-coreml), revision `e673531caa6d25ab7baf5a8c14c9b99ba1551838`: 560 ms, also the shared front-end source for Unified.
- [Parakeet EOU Core ML](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml), revision `40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355`: 160 and 320 ms variants. Smaller and trained EOU signaling, but worse WER in this subset.
- [Parakeet v3 Core ML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml), revision `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`: batch path retained.
- [Nemotron 3.5 Transcribe Lite](https://huggingface.co/FluidInference/nemotron-3.5-transcribe-lite-coreml): surveyed, not a streaming replacement. The publisher describes an unofficial extraction of the audio/CTC side of the full LLM-based model, with fixed long windows. Not measured in this streaming harness.
- Apple's current [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer) / [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) / [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber) surfaces were surveyed. They manage system model resources and do not supply Vox an encoder model asset for this compute-plan placement contract. They were not measured by this Core ML harness; the existing Apple file provider remains separate.

## Talkie contract

Prefer one shared `voxd` private Unix host (`VOX_SOCKET_PATH` + `VOX_AUTH_TOKEN`), not an embedded copy in every app. Explicitly call `models.install` / `models.preload` for `nemotron:unified-560ms`. Then use `transcribe.stream.start`, `append`, `finish`, and `cancel` on the same authenticated connection and `clientId`.

Append 1–16000 mono 16 kHz float32le samples as base64, with acknowledged sequence numbers beginning at zero. Results contain cumulative `text`, `words` (`word`, `start`, `end`, `confidence`), and `endOfUtterance`. Word times are approximate RNNT emission frames. Nemotron endpointing is a 1120 ms RNNT blank-duration rule, explicitly marked `endpointSource: "blank-duration"`, not a trained EOU head. Endpoints do not auto-stop. Finish flushes; cancel discards. Disconnect cancels ownership. Sessions are bounded to 120 s.

Embedded single-process callers can use `NativeStreamingASR.shared` from `VoxEngine`. Companion preload currently uses English-US; embedded preload supports explicit language selection. See [the runtime contract](../runtime.md#native-pcm-streaming).

## Reproduce and remaining validation

Build `vox-asr-bench` in release mode. Supply the pinned model bundle directory and a directory of 16 kHz WAV files with matching `.txt` references. Use the pinned dataset rows above; original FLAC hashes and per-utterance measurements are in [the machine-readable results](./native-asr-2026-10-30.json). Batch uses its installed revision-specific `VOX_HOME` cache. Add `--paced` for a wall-clock first-partial run.

Broad multi-speaker/noisy dictation, non-English accuracy, and iOS hardware placement/footprint remain untested. Strict TypeScript checking also reports existing history/event generic type errors outside this PCM API; Bun builds and runtime tests are the current checks. No model weights, release artifacts, tags, packages, or deployment were published.
