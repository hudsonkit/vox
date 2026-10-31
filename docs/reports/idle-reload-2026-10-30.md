# Native ASR idle and reload investigation

## Decision and unresolved issue

The macOS native ASR default is now a bounded **900-second idle window**, up from
60 seconds. iOS stays at 60 seconds until physical-device memory measurements
justify another policy. `VOX_ASR_IDLE_SECONDS` overrides the default; zero explicitly
disables idle eviction. Embedded setters remain available. Native model inventory
now reports the actual `idleUnloadSeconds`, including model-scoped Parakeet changes.

This change reduces application-triggered eviction between nearby dictations. It
**does not fix the observed ANE compiler stall**, prove cache reuse or guarantee
small peak memory during preparation. One native model slot still spans batch and
live ASR. Explicit unload/delete and active-work protections remain unchanged.
Switching between batch Parakeet v3 and live Nemotron Unified still replaces that
slot and can require cold preparation.

## Read-only evidence

Talkie's approved normal-UI test used exact Vox revision `768491d` on the working
M1 host. The inspected bundle was `run-20261031T014747Z`, including `voxd.log`,
`voxd-during-file.sample.txt`, vmmap captures and cleanup metadata. This investigation
did not restart, attach to, or modify that daemon or the installed application.
The owned test process had already exited when this investigation began.

All times below are UTC on 2026-10-31. Sizes preserve the units of the source tools.

| Observation | Evidence / limitation |
|---|---|
| First preload | Talkie reported 106.132 s; daemon started loading at 01:47:58 and became ready at 01:49:44 |
| First encoder placement | At 01:49:43: ANE 1379 ops, CPU 6, GPU 0, unknown 294; ANE compute ops 342, CPU compute ops 0; planned ANE cost fraction 0.999587 |
| First priming | 966 ms, after model loading/placement; not the source of the initial 106 s delay |
| Second preload after default idle eviction | Started 01:52:00; no placement/session-loaded/ready event through last status poll 02:02:57, over 10 min 57 s pending; completion was not recorded |
| Sample at 01:54:15 | `MLModel` load → Espresso ANE compiler `build_segment` → `_ANEClient doLoadModel` → synchronous XPC wait for the ANE service |
| vmmap at 01:55:27 | Physical footprint 1.2G, peak 2.3G; about 1.2G dirty swapped; compiler/load transient, not a measured post-dictation steady state |
| Early first-load vmmap | 66.5M footprint / 70.9M peak at 01:49:02, **before ready**; cannot establish loaded-model residency |

The sample establishes an ANE load/compiler wait. The word `Espresso` in this stack
is not evidence of CPU encoder fallback. The first completed load met the ANE
placement gate. The second load never reached the placement report, so its final
placement is unknown. Existing earlier warm Agent diagnostics put daemon residency
near 100 MiB for batch and below that for live; this run does not establish that
steady state. The restored installed Agent's later status is not the test Agent's
memory measurement.

Cleanup metadata records restoration of the old installed Agent, unchanged installed
executable, and removal of the isolated private capability/socket. No test daemon
was kept resident to hide the reload issue.

## Root-cause boundary and diagnostics

Source inspection confirms fixed revision paths and explicit model configuration.
Inventory/install validation does not load Core ML on CPU. Same-model warmups join
one runtime flight, and a native residency lease prevents a concurrent second
model load. These facts rule out an intentional CPU-validation load in this path;
they do not identify why this OS/compiler invocation failed to finish promptly.

The old logs placed one boundary around component loading and compute-plan analysis.
They could not distinguish encoder `MLModel.load` from `MLComputePlan.load`, or a
later decoder/joint load. New `CoreML load stage` diagnostics record separate
started/completed/failed events, elapsed milliseconds and attempt number for:

- Parakeet preprocessor, encoder, decoder and joint `model-load`;
- encoder `compute-plan`, shared by batch and streaming;
- Parakeet vocabulary read.

The diagnostic event contains model ID, component and phase, not file paths,
request text/audio, credentials or untrusted error descriptions. The compute-unit
configuration, placement verification/retry and optimization hints are unchanged.

Apple describes specialization as hardware/OS/compute-unit specific and its
specialization cache as persistent across loads, launches and reboots under OS
management. Therefore a repeated multi-minute reload is not established as the
necessary cost of a healthy cached model. The exact compiler/cache condition here
remains unresolved. `MLComputePlan` reports planned placement/cost, not measured
execution timing. See [Apple's Core ML performance guide](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode).

Do not enable `fastPrediction` as an assumed fix: Apple documents increased
specialization time and possible increased memory/disk use. It needs a measured
comparison, not an unverified configuration change. See [Apple's specialization strategy](https://developer.apple.com/documentation/coreml/mloptimizationhints-swift.struct/specializationstrategy-swift.enum/fastprediction).

## Next controlled measurement gate

Use the next operator-owned test window, not an overlapping compiler probe:

1. Prepare only the selected operation's model. Record exact revision, OS and
   configuration; expose prepare progress in the UI. Do not alternate models just
   to poll readiness.
2. Record footprint at baseline, ready, after dictation and after explicit unload.
   Also record compiler/load peak and stage timings separately from steady state.
3. At the new 900-second default, verify a nearby same-model prepare reuses the
   ready Session with no new load-stage event. Then explicitly unload and prepare
   the same installed revision to measure true reload and cache reuse.
4. Propagate the chosen cold-preparation budget through every Talkie/XPC/RPC layer.
   The earlier 120/150-second envelopes could preempt a 600-second prepare, but
   extending them does not cure compilation. A client timeout/cancel does not prove
   a synchronous OS compiler operation has stopped; do not launch overlapping
   replacement compiles.
5. Repeat on a quiet host. If reload remains blocked, retain paired stage logs,
   same-PID samples, footprint/peak and OS diagnostics for the compiler/cache issue.
   Do not claim this policy change fixed reload latency or memory.

No new hardware model load, download, deletion, paid call, installed-daemon change,
release or merge was performed for this investigation. Synthetic lifecycle tests
can prove timeout reporting, reference release and active-work protection; they
cannot prove real-model compiler-cache reuse or physical-iOS footprint.

## Change verification

- Full Swift suite: **274 Swift Testing cases** plus XCTest suites pass. New tests
  cover platform/environment policy, old inventory decoding, configured timeout
  roundtrips, native model/status timeout agreement and success/failure phase logs.
- Strict cooperative focused run: **55 tests** pass, including existing Parakeet
  reference-release, single-flight and idle active-operation protections.
- Public native `VoxEngine` + Parakeet consumer compiles for ARM64 iOS Simulator.
  This proves compilation, not physical-device ANE placement or the iOS idle policy's
  memory effect.
- Companion client builds; **61 Bun tests pass / 8 opt-in skips**. Generated docs
  pass consistency checks (existing aggregate documentation score 99/100).
- Local private annotation/TTS fixture reruns stopped while compiling their fresh
  model-free clients: the filesystem returned `No space left on device`. No fixture
  daemon or vendor request had started. They are not reported as passing reruns;
  both remain CI gates. An inspection after cleanup found only 1.6 GiB available.
  This later disk-pressure observation is not a measurement of free space during
  Talkie's earlier compiler stall and does not establish its cause. Record free
  disk space and memory pressure in the next controlled reload comparison too.
