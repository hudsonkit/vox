---
title: Isolated native development host
description: Run a named private Vox daemon beside installed apps without changing their service or discovery endpoint.
---

Use a named development host when an Apple app deliberately shares speech across
processes. This workflow copies **voxd**, its TTS helper and the required SwiftPM resource
bundle, not Vox.app or Talkie.app. It creates no
launchd job, does not stop an installed service, and does not change `~/.vox`.
The app must explicitly select the development capability. Other clients continue
to discover their existing endpoint.

## Build and install private copies

Check out the exact reviewed Vox revision first. Build both executables explicitly:

```sh
xcrun swift build --package-path swift -c release --product voxd --jobs 3
xcrun swift build --package-path swift -c release --product voxttsd --jobs 3
VOX_BIN="$(xcrun swift build --package-path swift -c release --show-bin-path)"
VOX_REV="$(git rev-parse HEAD)"

# Set this to an EXISTING Vox model-store root, not a FluidAudio cache.
# It must contain the installed pinned Parakeet v3 and/or Unified bundles.
export EXISTING_VOX_MODELS="$HOME/.vox/cache/models"
python3 scripts/dev-voxd.py install talkie-native \
  --bin-dir "$VOX_BIN" --models-path "$EXISTING_VOX_MODELS" --revision "$VOX_REV"
```

Installation creates owner-only copies/state under `~/.vox-dev/talkie-native/`.
The script refuses an existing name, a symlink/private-directory violation, a
missing executable/resource bundle or an unknown model-store root. It records binary hashes and
the explicitly supplied source revision. Use a new name to stage another build;
do not overwrite a running copy.

`VOX_MODELS_PATH` selects the model-store root independently of `VOX_HOME`.
Sharing installed files does **not** share loaded model instances across processes.
One daemon still has one native ASR residency slot. The default model-store path
remains `VOX_HOME/cache/models`; its existing path/ownership checks are unchanged.
An explicit root is trusted configuration; choose a same-user absolute directory.
Do not use symlinks to bypass owned model-leaf checks. Explicit model installation
or deletion can mutate a shared installation, so coordinate model management.

## Run and connect

In one terminal, run the supervisor in the foreground:

```sh
python3 scripts/dev-voxd.py run talkie-native
```

It starts only its copied `bin/voxd --private`. Default idle retention is 900 seconds;
`--idle-seconds 60` selects the earlier desktop interval for a controlled reload
test. The model root comes from the installation manifest. These paths are separate:

| Purpose | Development path |
|---|---|
| Runtime/log/history home | `~/.vox-dev/talkie-native/home` |
| Private capability | `~/.vox-dev/talkie-native/runtime.json` |
| Unix socket | `~/.vox-dev/talkie-native/voxd.sock` |
| Executables | `~/.vox-dev/talkie-native/bin` |

The daemon generates its own token and publishes the capability as a same-user
0600 file in a 0700 directory. No token belongs in argv, environment, a launchd
plist or diagnostic output. No TCP listener opens. Existing `VOX_*` endpoint
settings are fenced from the child. The supervisor prints the capability path,
not its contents. A per-name lease prevents two instances.

In the development **Agent's process environment**, select only:

```sh
export VOX_RUNTIME_PATH="$HOME/.vox-dev/talkie-native/runtime.json"
```

Unset `VOX_SOCKET_PATH` and `VOX_AUTH_TOKEN` in the client if they were inherited:
an explicit endpoint/token pair takes precedence over capability discovery. A
Swift client uses the lightweight `VoxClient` product and
`VoxDaemonClient(clientId:).connectDiscovered()`. It must not launch a fallback
engine or daemon when discovery fails. Do not export the dev endpoint globally
with `launchctl setenv`; the Talkie lane owns isolated dev Agent/UI routing.

## Explicit preparation and verification

The public model-free example client can inspect the exact endpoint and operate
native speech without embedding `VoxEngine`:

```sh
xcrun swift build --package-path examples/dev-host-client --jobs 3
VOX_PROBE="$(xcrun swift build --package-path examples/dev-host-client --show-bin-path)/DevHostClient"
"$VOX_PROBE" health
"$VOX_PROBE" models
"$VOX_PROBE" prepare parakeet:v3
"$VOX_PROBE" file parakeet:v3 "$AUDIO_FILE"
"$VOX_PROBE" prepare nemotron:unified-560ms
"$VOX_PROBE" stream nemotron:unified-560ms "$MONO_16KHZ_WAV" --paced
```

If inventory says the selected revision is not installed, installation is a
separate explicit command, not a startup side effect:

```sh
"$VOX_PROBE" install parakeet:v3
"$VOX_PROBE" install nemotron:unified-560ms
```

Batch remains **Parakeet v3**; live PCM remains **Unified 560 ms**. Preparing one
can evict the other. `models.preload` emits `models.progress`; readiness includes
priming and verified planned ANE placement. A failed prime now fails preparation,
releases the temporary models before releasing residency, and never reports ready.
Preparation has an explicit 600-second client budget in this example. File
inference has a separate 120-second budget. A client timeout/cancel does not prove
that an OS compiler invocation has stopped; never replay automatically.

Native PCM uses `transcribe.stream.start/append/finish/cancel`. Input is finite
mono Float32 little-endian at 16 kHz, at most 16000 samples per acknowledged packet.
Finish flushes the tail; cancel discards. Connection, client and session identity
own mutations. Keep source audio in the caller until successful final delivery or
an explicit user discard. The example's `--paced` reports wall-clock first partial;
unpaced timing is compute throughput, not capture latency.

For a controlled same-daemon idle test, start the host with `--idle-seconds 60`,
then run `"$VOX_PROBE" cycle MODEL_ID "$MONO_16KHZ_WAV"`. It refuses missing models,
prepares and infers, observes actual `preloaded:false`, then prepares and infers
again. It does not install, pin a second model or treat cached warmup history as
readiness. The separate `vox-asr-bench lifecycle` diagnostic additionally tests
public embedded explicit unload and idle unload, using the same production models.

## Measured reload behavior

The [2026-10-31 native verification report](reports/native-dev-reload-2026-10-31.md)
records actual explicit and idle unload/reload with inference. It also records
unresolved slow Unified preparation and a separate normal dev-host compute-plan
failure. Do not treat the resource budget or 900-second retention as a cache fix.
Core ML stage failures include at most three allowlisted error domains/numeric
codes; raw error descriptions, arbitrary domains and userInfo are not logged.
Coordinate native compiler work with other dev hosts before measuring reload.

## Resource admission

On macOS, encoder loading, compute-plan loading and first-use priming require a
**3 GiB temporary-volume free-disk reserve** and reject critical kernel memory
pressure before that stage. Historical ANE compiler logs show a failed allocation
near 2.40 GiB. This reserve is a conservative safety budget, not a universal Core ML
minimum or proof that the OS will retain specialization caches. Mobile has no new
default disk floor pending device measurements.

`VOX_ASR_MIN_FREE_DISK_BYTES` configures the library budget; invalid values fail.
An explicit zero disables this disk floor, not placement checks. For a dev host,
use `run ... --minimum-free-disk-bytes N`. A rejection is actionable and leaves
native readiness false. It never deletes caches or falls back to CPU. Free space
or close competing work, then explicitly prepare again. Already resident reuse
still works without an encoder reload. Disk/cache resource pressure and code
changes must be reported separately; healthy-host success is not proof that every
historical OS cache failure is fixed.

## Stop and remove

Press Control-C in the supervisor terminal, or use:

```sh
python3 scripts/dev-voxd.py status talkie-native
python3 scripts/dev-voxd.py stop talkie-native
python3 scripts/dev-voxd.py status talkie-native
python3 scripts/dev-voxd.py remove talkie-native
```

Stop verifies the supervisor's PID/start identity before signalling only that
supervisor. It does not signal an installed app or the system compiler. Normal
daemon shutdown removes its own capability/socket. Remove refuses a running lease
or remaining capability and deletes only this named dev copy/state, never the
external shared model store. Preserve failed-run evidence before removal. Nothing
in this workflow installs, merges or releases an application.
