# Embedded Parakeet lifecycle

A model-free-at-initialization Apple app actor using only public `VoxCore` and
`VoxEngine`. Batch policy is explicitly `parakeet:v3`; no daemon or transport is
linked. This is a library example, not an app launcher or a model download script.

- `inventory()` reads structural installation metadata and actual runtime status.
- `download(progress:)` installs only; `prepare(progress:)` loads, verifies ANE
  placement and primes explicitly. Dispatch progress updates to MainActor yourself.
- `transcribe(fileURL:)` returns native word timings and stage metrics. The app owns
  iOS capture and the file lifetime. Missing files fail before loading.
- `unload()` clears the shared model Session. `deleteOwnedModel()` also removes only
  the selected Vox-owned revision. Both throw `ParakeetLifecycleError.busy` while
  a file operation, installation or warmup is active; wait for it to settle first.
- `modelDirectory()` is read-only location metadata, not permission to bypass safe
  deletion with a caller-owned recursive remove.
- `setIdleUnload(seconds:)` is model-scoped; zero disables idle unloading. Default
  production timeout is 900 s on macOS and 60 s on iOS, optionally configured by
  `VOX_ASR_IDLE_SECONDS`. Inventory reports the actual `idleUnloadSeconds`.
  The desktop window reduces eviction churn; it does not guarantee fast reload.

The engine metadata actors remain shared; unload drops their actual loaded Session,
not merely this actor's reference. Core ML system caches/RSS are not forcibly purged.
The lifecycle reservation is process-local, not a cross-process model-store lease.
Simulator compiles the native engine but cannot provide ANE inference; production
Parakeet advertises unavailable there. Physical iOS 17.4+ hardware is required.

Compile the whole public native engine and this consumer for Simulator:

```sh
xcrun swift build --package-path examples/parakeet-lifecycle \
  --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  --scratch-path /private/tmp/vox-parakeet-example-ios --jobs 3
```

No model is downloaded or compiled by this build. See
[the embedded lifecycle contract](../../docs/apple-embed.md#embedded-parakeet-lifecycle).
