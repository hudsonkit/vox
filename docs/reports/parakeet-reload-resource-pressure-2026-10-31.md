# Parakeet reload under resource pressure

## Result

A separate private library process completed Parakeet v3 preparation, two warm
19-second generated-silence transcriptions, same-model reuse and explicit unload.
**Explicit reload was not attempted:** after unload, free disk was 4.94 GiB,
below the experiment's unchanged 5 GiB start reserve. This is a partial comparison,
not a reproduced reload stall or a verified fix.

Production engine code is unchanged from `8a5285d9d51bbf393f8be9679eda2ef82348831d`,
including component diagnostics introduced by
`f66a3af2afd367c8f570019b617de0c5def5ce28`. The existing model was
`parakeet:v3`, conversion revision
`7dd20fe6b1797d35f5e3307e8b1732d9a178edfe`. This run used the local debug test
product on the M1 host, macOS 27.0.1 build 26A434. It did not change the batch/live
selection, compute units, placement gate, compiler hints or application idle policy.

## Resource intervention and historical evidence

These conditions differ from the earlier normal-Agent window:

- At 05:24:27–05:24:38 UTC on October 31, the Talkie lane reset two positively
  owned, finished duplicate SwiftPM dependency caches. Its ledger reports free
  disk increasing from 3.3 to 5.6 GiB. It preserved signed products, source inputs,
  runtime evidence, model stores and Core ML caches. Earlier owned-cache cleanup
  at 05:01 and 05:10–05:12 is recorded separately.
- This probe started at 05:32:40 UTC with 5.41 GiB available in the temporary
  volume, kernel memory-pressure level 1, and 6652 MiB swap used. The compiler
  service was idle at the preflight snapshot. During the run, minimum sampled free
  disk was 2.60 GiB, pressure reached level 2, and compiler CPU reached 100%.
  Swap usage stayed at 6652 MiB. These are host conditions, not private-process
  memory measurements.
- Read-only historical unified logs contain a concrete ANECompilerService
  `F_PREALLOCATE` failure at **02:03:16.321 UTC**: growth from 2,564,816,896 to
  2,575,302,656 bytes failed with `No space left on device`, followed by a temporary
  allocation failure. This occurred during the earlier pending reload window.
  Redacted model/client labels prevent attributing that event conclusively to one
  model or request.

The historical allocation failure establishes real compiler disk pressure. It
**does not explain why specialization was needed or why a cached specialization
was not reused**. The new probe's targeted log query found no matching allocation
failure. Neither the resource intervention nor the new timings prove a code fix.

## Measurements

Source artifact: private run `run-20261031T053240Z`, UTC October 31. The raw metrics,
component log, one-second resource samples, owned-process samples, vmmap summary,
source hashes and intervention-ledger hashes are retained outside the repository.
No transcript, audio, credentials or machine-local paths are published here.

| Phase | Prepare | 19 s inference | Footprint at ready / after inference | Lifetime peak |
|---|---:|---:|---:|---:|
| First load in fresh process | 172,347.9 ms | 127.2 ms | 89.25 / 92.69 MiB | 100.22 MiB |
| Same resident runtime | 1.52 ms | 128.8 ms | 92.69 / 92.75 MiB | 100.22 MiB |
| After explicit unload, 300 ms settling | — | — | 80.56 MiB | 100.22 MiB |
| Explicit reload | **not started: reserve failed** | — | — | — |

Baseline footprint was 7.72 MiB. Peak is the process lifetime high-water mark,
not a separately reset peak for each phase. Footprint excludes OS compiler and
accelerator allocations. Unload cleared the actual runtime Session and placement;
the remaining 80.56 MiB is not a claim that framework/allocator memory returned to
baseline. Generated silence tests the production long-form execution path, not
recognition accuracy or microphone latency.

First-load stage diagnostics:

| Stage | Elapsed |
|---|---:|
| Preprocessor model load | 104 ms |
| Encoder model load | 34,707 ms |
| Encoder compute-plan load | 34,331 ms |
| Decoder model load | 180 ms |
| Joint model load | 113 ms |
| Vocabulary read | 11 ms |
| Long-form priming | 102,874 ms |

The encoder passed placement on attempt 1: 1379 ANE operations, 6 CPU operations,
0 GPU operations, 294 unknown operations; 342 ANE compute operations and 0 CPU
compute operations. Planned ANE cost fraction was **0.9995873**. A compute plan is
planned placement, not an execution trace. There was no retry or CPU fallback.
Same-model reuse emitted no component-load or priming events.

The first owned-process sample was inside Core ML model loading/AOT specialization.
A second sample during priming showed prediction execution preparing an operation
through `MLE5ProgramLibrary` and the AOT compiler, with another prediction waiting
on that library. Thus the 102.9-second prime was native first-use preparation, not
172 seconds of ordinary inference. This does not identify a persistent cache miss
or establish that specialization repeats on explicit reload.

## Reproducible probe and safety limits

The opt-in Swift test calls the production `ParakeetCoreMLRuntime` directly with
an existing pinned bundle. It performs no model installation, download, receipt
validation by compilation, daemon launch, microphone capture or paid call. It uses
one runtime, explicitly disables its idle timer for this short experiment, then
explicitly unloads. It preserves strict encoder placement checks. Application
policy is unchanged.

Build the tests without enabling the hardware test, then run the supervisor:

```sh
xcrun swift test --package-path swift --jobs 3 --filter ParakeetReloadHardwareProbe
python3 scripts/probe-parakeet-reload.py \
  --model-directory "$EXISTING_PARAKEET_V3_BUNDLE" \
  --output "$NEW_PRIVATE_RUN_DIRECTORY" --deadline-seconds 900
```

The supervisor requires a new private output directory, at least 5 GiB free disk
and normal kernel pressure before launch. The Swift test rechecks 5 GiB before
fresh load and explicit reload. This is a conservative experiment reserve, **not
an established Core ML minimum**. During execution, the supervisor stops its own
caller at less than 1 GiB free disk, critical pressure or the deadline. It does not
automatically replay requests or delete caches to obtain headroom.

SwiftPM's test helper has a separate process group. Before profiling or signalling
that helper, verify its direct parent and the mapped test bundle from this checkout.
The first run used an additional private guardian after this process-group behavior
was observed; the published supervisor includes that ownership check. No stop
signal was needed. Stopping a caller does not guarantee the OS compiler has stopped.
Do not signal the compiler or installed applications.

## Remaining investigation

The old post-idle stall is still unresolved. The current comparison stopped safely
before the operation needed to reproduce it. A subsequent test needs normal pressure
and the full start reserve **after explicit unload**, not merely at process launch.
Do not lower the reserve after observing a blocked phase or remove operator caches
to complete a table.

With that reserve, repeat the same pinned bundle and configuration through reload.
Use component timings plus owned-process samples to distinguish encoder load,
compute-plan loading and first-use priming. Record cache identity/resource evidence
before proposing a model-code fix. Apple's documented specialization cache persists
across loads, launches and reboots under OS management; a long reload is not an
established unavoidable cost. See [Apple's Core ML performance guide](https://developer.apple.com/documentation/coreml/analyzing-a-core-ml-model-s-performance-in-xcode).

No normal-Agent window was opened. Installed apps/services, operator audio, model
stores and Core ML caches were untouched. No release or merge was performed.

## Verification

- Full local Swift suite passes with hardware execution disabled; the new probe
  is reported as skipped. The opt-in real-model run is separately reported above
  as partial, with a failed reserve gate, not a passing hardware test.
- Six model-free Python tests pass for helper parent/bundle verification and
  separate-helper stop behavior. CI runs these without models.
- Generated documentation passes `bun run docs:check` (existing score 99/100).
