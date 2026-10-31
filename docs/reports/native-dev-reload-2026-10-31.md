# Native reload and isolated development host verification

## Result

The normal native providers completed inference after real explicit unload and
idle unload on an Apple M1 mini, macOS 27.0.1 (26A434). A copied release `voxd`
also completed both models after the original 60-second idle interval. No CPU
fallback or second retained native model was used.

**The specialization-cache problem is not resolved.** Unified required 49.698
seconds to prepare after idle in the release daemon. A separate Talkie-owned dev
host later failed Parakeet's compute-plan phase after 34.952 seconds. These results
must not be presented as a cache-reuse fix or a completed own-voice acceptance test.

## Source and inputs

- Main base: `8a5285d9d51bbf393f8be9679eda2ef82348831d`.
- Release daemon tested: `0d32218a1aa551c66c0e4f3017e6397c48729d00`.
- Daemon SHA-256: `b6b350ed82af570fc0d806929a3234299036990a8ea049e31f3683743daf5499`.
- `9260f976b8616d4c9d6ce25e660c6e822aa9452d` fixes the portable benchmark
  entrypoint and a Python fixture publication race. Its engine/service sources
  are identical to the tested release daemon's sources.
- Parakeet v3 conversion: `7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`.
- Unified 560 ms conversion: `bd13ddde81d3134719c520845346b3252daf3175`.
- Existing model files only; no model download or deletion during these runs.
- Synthetic mono 16 kHz WAV, 15.868125 seconds, 41 words, final word
  `watermelon`; SHA-256
  `6b8388668e16a58ea0faf4a586a2c72496f90dcd381a472c86e4cc887c9eda34`.
- No operator microphone, playback or paid vendor call in this Vox measurement.

## Release private daemon, actual 60-second idle

One normal production-factory daemon served Parakeet and then Unified. A separate
model-free public `VoxClient` consumer prepared and inferred, polled until actual
`preloaded:false` with no placement, then prepared and inferred again. The model
inventory never showed two preloaded native models. Preparing Unified evicted
Parakeet. Each final transcript preserved the tail and contained 41 timed words.

| Model | Initial prepare | Post-idle prepare | Initial / post-idle inference |
|---|---:|---:|---:|
| Parakeet v3 | 65.410 s | 991 ms | 249 / 204 ms native inference |
| Unified 560 ms | 64.700 s | **49.698 s** | Paced 15.868 s audio; first partial 1106 / 1158 ms |

Preparation values include CLI startup/transport. Parakeet inference uses the
server's `inferenceMs`, excluding file preparation and transport. Unified first
partial is wall-clock from first PCM append with 1280-sample paced packets, not
unpaced throughput. Stop-to-final was 64.8 / 51.6 ms, with 93 nonempty cumulative
updates per run. The final update's `chunkLatencyMs:0` is not a measured per-chunk
latency distribution; this run did not retain that distribution.

Daemon physical footprints below are the **raw units printed by `vmmap`**, not
RSS and not a precise byte measurement. Peak is process-lifetime peak, including
Parakeet earlier in the same daemon when reading Unified's row.

| Model | Initial ready / after inference | Actually idle-unloaded | Post-idle ready / after inference | Lifetime peak after final |
|---|---:|---:|---:|---:|
| Parakeet v3 | 53.2M / 59.4M | 40.0M | 79.8M / 81.2M | 86.0M |
| Unified 560 ms | 92.0M / 92.3M | 79.1M | 92.3M / 93.0M | 93.3M |

MLComputePlan reported these planned placements on each load, attempt 1:

| Model | ANE / CPU / GPU operations | ANE / CPU conv-linear-matmul | Estimated ANE cost fraction |
|---|---:|---:|---:|
| Parakeet v3 | 1379 / 6 / 0 | 342 / 0 | 0.999587 |
| Unified 560 ms | 1400 / 47 / 0 | 344 / 0 | 0.999272 |

There were 294 / 297 operations with no device usage respectively. Constants are
excluded from the unknown count. This is verified **planned placement**, not an
execution trace. Device checking remains mandatory and fails closed.

Unified's post-idle work was not just transport overhead: encoder model-load took
23.300 s and compute-plan took 24.678 s. This directly preserves the nonreuse
case rather than hiding it with longer retention.

## Public embedded lifecycle baseline

These debug benchmark runs used the production public ParakeetProvider and
NativeStreamingASR, no injected session/runtime. The Core ML loader was unchanged
from main; the model-root selector and reporting harness were added. Each phase
performed inference, not just model construction. The harness observed real
explicit unload and real idle eviction before reloading.

| Model / idle interval | First prepare | Resident reuse | Explicit reload | Idle reload | Lifetime process peak |
|---|---:|---:|---:|---:|---:|
| Parakeet v3 / 2 s | 64.448 s | 4.29 ms | 796 ms | 734 ms | 111.34 MiB |
| Unified / 2 s | 47.512 s | 0.58 ms | 2.271 s | 2.231 s | 75.92 MiB |
| Parakeet v3 / 60 s | 76.856 s | 4.35 ms | 784 ms | 2.207 s | 112.72 MiB |

The first row's post-idle inference took 186 ms; the 60-second Parakeet run took
415 ms. Unified debug unpaced inference took roughly 5.2–5.6 seconds for the whole
input; this is not capture latency. These measurements are separate from the
release private-daemon table. Unload releases model ownership, not all framework
allocations; footprint need not return to the process baseline.

## Root-cause evidence and limits

The historical low-space failure is confirmed: at 02:03:16.321 UTC the system ANE
compiler logged `F_PREALLOCATE failure` and `No space left on device` for an
allocation growing from 2,564,816,896 to 2,575,302,656 bytes. The redacted log cannot
prove which model/request owned that allocation. It does not establish why a
specialization was not reused.

The healthy-host tests followed explicit disk recovery by the Talkie lane. The
initial embedded run had about 9.18 GiB available and kernel pressure level 1.
Disk, swap and pressure varied during the day. The 60-second embedded Parakeet
reload finished at pressure level 2. Do not attribute improvements solely to Vox
code. No model/Core ML/operator caches were removed by this Vox investigation.

At 16:03:37 UTC, a separately named Talkie-owned copied dev host loaded the
Parakeet encoder in 470 ms, then failed compute-plan at 16:04:12 after 34.952 s.
The admission snapshot showed 5,763,313,664 free bytes and pressure level 1. This
failure occurred before the later prototype below. The client reported `Failed to construct compute plan, internal failure.`
The old stage logger did not retain numeric error causes. Additional bounded, allowlisted domain/code logging
now records failures without raw descriptions, paths, bodies or arbitrary domains.
No retry of that peer request was performed by this lane. A precise underlying
failure category and a coordinated rerun remain required.

A temporary same-MLModelAsset model/plan experiment compiled but showed no benefit
in a partial, resource-confounded run. It overlapped the separate dev host's later
Unified preparation, then stopped before resident reuse because the unchanged
5 GiB experiment reserve failed. It did not test explicit/idle reload. The patch
was discarded and is not part of this PR. No OS cache-reuse claim follows.

A later, positively owned, finished model-free example-client build scratch
(about 140 MiB) was cleaned. A shell sequencing mistake ran SwiftPM clean after a
precheck refused preservation, so the example binary had to be rebuilt. The raw
logs, root build products, model store and installed apps were not touched. Disk
had already recovered to about 5.8 GiB before that cleanup; do not attribute the
resource recovery to this small cleanup.

Apple documents that device-specialized Core ML assets are cached and that the
system can remove them under storage pressure. This is a plausible contributor,
not proof of the failure above. See [Core ML performance analysis](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode)
and [Improve Core ML integration with async prediction](https://developer.apple.com/videos/play/wwdc2023/10049/).

## Later normal-Agent observation on e040eb1

The peer replaced only its owned dev copy with `e040eb1`; this Vox investigation
did not stop or replace it. The copied daemon hash was
`d8070ceb084cfa6ae03502286e6814543da7ec31fe8f0b963bf38912371971f6`.
After a real idle eviction at 16:34:08 UTC, the normal Agent's next prepare began
at 16:34:32. It completed at 16:38:34 and real file inference then took 214 ms.
Preparation's component times were:

| Component | Time |
|---|---:|
| CPU preprocessor model-load | 19.858 s |
| Encoder model-load | 705 ms |
| Encoder compute-plan | 81.097 s |
| Decoder / joint model-load | 169 / 93 ms |
| Prime | 139.549 s |

The plan admission snapshot had 11,643,252,736 free bytes and pressure level 2.
Priming began with 11,173,330,944 free bytes and pressure level 1. Planned placement
remained 1379 ANE / 6 CPU operations, 342 ANE / 0 CPU compute. The request completed
without an error, but approximately four minutes of post-idle preparation is not
a reliable fast-reload result. **The earlier normal-Agent failure and Gate 2
remain open.** More free space did not by itself restore fast plan/prime behavior.

A read-only sample of the same hash-verified dev daemon during its first prime
showed three concurrent async prediction stacks creating execution operations.
One entered on-device compilation, then `MILCompilerForANE` and ANE `compileModel`
XPC; others waited on the program-library queue. Physical footprint and lifetime
peak were both 94.8M at that sample. This is actual ANE compilation during
prediction, not evidence of CPU inference fallback. The generic method name
`forceRespecialization` does not establish that its boolean argument was true.

The exact process's unified log also showed three private E5RT `(13)` errors at
each prime start. The message is redacted and its code is not established as
POSIX EACCES. No lower-level cause is inferred from that number.

New chunk-correlated preprocessor/encoder/decoder-joint prediction diagnostics
separate those API costs without changing concurrency or compiler configuration.
They have model-free tests but have not yet been exercised in a coordinated new
native run. A separate Core-ML-only existing-encoder isolation probe was compiled
privately, with explicit release/weak-reference checks and no automatic replay.
It has not loaded a model; the peer retains the native resource window.

## Implemented safeguards, not a cache workaround

- Failed Parakeet priming now throws instead of reporting ready. Temporary loaded
  models are dropped before releasing failed initialization's residency lease.
- Encoder model-load, compute-plan and priming reject a deficient temporary-volume
  free-disk budget or critical memory pressure before entering that stage.
  macOS default reserve is 3 GiB; this is a safety policy, not a universal Core ML
  minimum or a cache guarantee. Mobile has no new default reserve.
- A forced 100 GiB budget test rejected prepare before encoder loading in 1 ms.
  Inventory remained installed but not preloaded, placement absent. This verifies
  admission behavior, **not a new real ENOSPC reproduction**.
- Native failure logs record at most three allowlisted error domains and numeric
  codes. They never reflect NSError descriptions/userInfo, arbitrary domains,
  audio, text, paths or credentials.
- No CPU fallback, automatic replay, permanent double residency, cache deletion
  or private OS cache-control API was introduced.

Use [the isolated host recipe](../dev-runtime.md) for explicit preparation and
own-voice development testing. A client must preserve captured source audio until
successful final delivery or an explicit user discard. A timeout does not prove
that system compilation stopped.

## Verification and remaining gate

Local Swift tests, model-free named-host tests, copied-resource private metadata
smoke and docs checks passed. Public CI for `9260f97` passed in run
`41214989337`. New failure-diagnostic tests exercise a nested synthetic Core ML /
unknown / POSIX ENOSPC chain and verify that secret descriptions/domains do not
enter events. These tests require no model or vendor call.

The remaining gate is a coordinated normal dev Agent post-idle rerun with the
underlying compute-plan failure recorded, followed by operator own-voice acceptance.
The named daemon used for the controlled tables was stopped after measurement.
The peer's separate dev daemon/Agent and all installed services/apps were left
untouched. No main merge, release or installed-app overwrite was performed.
