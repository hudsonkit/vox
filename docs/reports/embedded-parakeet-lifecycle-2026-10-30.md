# Embedded Parakeet lifecycle verification

## Supported surface

The iOS batch integration embeds `VoxCore` + `VoxEngine` and keeps a concrete
`ParakeetProvider`, optionally injected into `EngineManager`. Batch model remains
`parakeet:v3`. No local daemon, VoxClient transport, FluidAudio loader or Python
runtime is introduced into this native path.

| Method | Contract |
|---|---|
| `await models()` | Structural filesystem metadata and actual runtime snapshot; no model load/download/compilation or metadata writes |
| `modelDirectory(modelId:)` | Read-only owned revision location; no caller hardcoded manifest/cache paths |
| `install(modelId:progress:)` | Download/validate only; no Core ML load or priming |
| `preload(modelId:progress:)` | Explicit load, verified ANE encoder placement and priming |
| `unload(modelId:)` | Reject admitted operations, then clear actual shared loaded Session; return current `ASRModelInfo` |
| `deleteModel(modelId:)` | Reject admitted operations, unload, remove selected owned revision only; return current snapshot |
| `setIdleUnload(modelId:seconds:)` | Shared process/model timeout, default 60 s; zero disables idle eviction |

Install is deliberately download-only now; older Parakeet versions also warmed
inside install. Applications must call preload visibly when they want readiness.
Native file transcription still loads on demand when the explicit file operation
requires it. Installed does not imply preloaded, valid model semantics or ANE
execution; only an actual load verifies placement.

## Reference ownership

Clearing an app's provider reference was insufficient because process-wide engine
metadata retains the runtime. The new unload clears that runtime's model-bearing
Session closure and placement, not just a provider dictionary entry. The cached
runtime/metadata actors remain intentionally shared, preventing duplicate owners
from loading independent copies. Model-scoped residency eviction cannot steal an
active lease or unload another model. Warmup's lease is released before completing
its load flight, preventing an idle timer from racing final warmup handoff.

The operation reservation spans download, warmup, file preparation and inference.
Unload/delete throw `ParakeetLifecycleError.busy` until admitted work settles.
Shared install/load flights remain owned if one waiter cancels; they cannot be
deleted underneath another caller. The reservation is process-local, not a
cross-process filesystem lease. Cached conversion selection is process-scoped;
a catalog refresh does not hot-swap an existing cached engine.

No API promises a forced Core ML system-cache purge or immediate RSS reduction.
Readiness comes from the actual shared Session snapshot, not an app-maintained flag.
Filesystem deletion failure can leave partial storage with the runtime already
unloaded; callers should refresh inventory rather than infer success.

## Owned deletion

New directories receive an atomic receipt bound to model ID, repository and
revision. Known built-in legacy layouts remain manageable without an existing
receipt. Unknown custom nonempty directories, mismatched/corrupt/hard-linked
receipts and unsafe names are rejected. Deletion opens owned path components
relative to the trusted Vox home without following symlinks. It recursively
unlinks only the selected model directory, never symlink/hard-link targets,
other models, older revision directories, external FluidAudio stores or OS caches.
Receipts are kept until child removal succeeds so partial failures retain ownership.

## Verification

- Eleven new lifecycle/storage tests plus existing Parakeet tests pass (42 focused
  tests in total). A weak lifetime witness captured by the production runtime's
  injected Session becomes nil after unload, including unload by another provider
  owner while the first provider remains retained. Reload creates a new Session.
- Fixture inventory and download-only installation make zero calls to the injected
  model loader; download counts prove single-flight installation. Real WAV file
  preparation/inference uses the production provider contract with a fake decoder,
  not a real Core ML model or an accuracy measurement.
- Busy guards cover held inference, initialization and download. Cancelling the
  first install waiter does not make the directory deletable or cancel another
  owner. Idle timeout, reservations spanning file preparation, and model-scoped active residency guards are tested.
- Filesystem tests preserve sibling sentinels and external symlink targets; reject
  symlinked parents/leaves, traversal, unowned custom directories and wrong receipts.
- **The complete `VoxEngine` compiles for ARM64 iOS Simulator**, including native
  Parakeet. The independent public-only `examples/parakeet-lifecycle` consumer also
  compiles through the repository-root package, not just the lightweight VoxClient.
  That consumer compilation is now part of CI. Existing `cblas_scopy` deprecation
  warnings remain; no Accelerate ABI migration was attempted here.
- Production Parakeet reports unavailable on Simulator, which has no ANE. Native
  inference requires supported Apple Silicon and macOS 14.4 / iOS 17.4 hardware.
  **No physical iOS ANE placement, footprint, cold-readiness or accuracy result is
  claimed.** Prior M1 batch measurements are unchanged, not a test of this API on iOS.

Reproduce:

```sh
xcrun swift test --package-path swift --filter Parakeet --jobs 3
xcrun swift build --package-path examples/parakeet-lifecycle \
  --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  --scratch-path /private/tmp/vox-parakeet-example-ios --jobs 3
```

All lifecycle/deletion tests use isolated temporary stores and synthetic files.
No installed model, installed daemon/app, Talkie source, launchd service or real
vendor endpoint was changed. No model weights were downloaded, no real Core ML
model was loaded for these tests, and no merge or release occurred.

## Full regression checks

The full local suite passes 268 Swift Testing cases. Focused Parakeet tests pass
with the strict cooperative executor. Bun clients/CLI/browser suites pass 61 tests
with 8 opt-in integration skips. Documentation generation/check passes with the
existing audit warnings. The real isolated private annotation and TTS fixtures
also pass; TTS cancellation still preserves another client's in-flight request
and the shared helper PID. No native ASR weights or phone hardware were used by
these checks.
