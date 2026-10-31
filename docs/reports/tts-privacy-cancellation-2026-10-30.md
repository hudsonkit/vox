# TTS error privacy and provider cancellation verification

## Findings and root causes

Talkie's loopback audit found a loaned OpenAI key reflected by a synthetic HTTP
401 response in Vox's persisted diagnostics. A failing regression reproduced
this against the current provider: both JSON and plain-text error bodies became
`NSError.localizedDescription`, then propagated through `voxttsd`, the external
transport and the service's telemetry/error log. Substring redaction in the app
cannot repair host-side persistence.

A second failing regression showed `StdioTransport.call` ignored task
cancellation. Removing the client wait alone did not stop work. The helper also
awaited each synthesis before reading another stdin line, so it could not receive
a request cancellation during HTTP processing.

## Fix

- OpenAI HTTP errors now contain only the HTTP status, matching ElevenLabs. Neither
  JSON nor plain-text vendor bodies enter errors, telemetry or logs. The default
  HTTP session is ephemeral, without URL cache, credential storage or cookies;
  requests use no-store. Header values are validated without echoing the key.
- Service generation and authenticated voice lookup reserve connection-owned task
  tickets before launching. Disconnect cancels only that connection's tasks. The
  shared ticket implementation handles cancellation/completion before attachment.
- Stdio calls are cancellation-aware. Cancellation and timeout remove/resume the
  matching continuation once. An ordered writer emits `$/cancelRequest` with the
  numeric transport request ID for opted-in providers. Late replies are ignored.
  Cancellation does not stop or restart the shared provider process.
- Stock `voxd` marks its bundled `voxttsd` as request-cancellation capable. Custom
  external TTS entries may explicitly set `supportsRequestCancellation: true` only
  for a compatible helper. Absent/false retains legacy protocol compatibility:
  local waits cancel, but remote execution might continue.
- `voxttsd` reads bounded stdin frames on a dedicated POSIX reader thread and
  admits at most 16 concurrent requests. Actor-owned IDs route cancellation to one
  task. Notification parsing continues while HTTP/AVFoundation awaits. Parent EOF
  cancels accepted work and drains it. Unknown cancellation IDs are ignored.

## Real Talkie audit rerun

The unchanged Talkie `verify-vox-tts.py` runner and its existing built speech probe
were run against the rebuilt stock private daemon and bundled helper, using a
fresh isolated output home and loopback vendor fixtures. No Talkie edits, real
account keys, paid endpoints, capture, playback, installed app/daemon changes,
launchd changes, merge or release occurred.

- ElevenLabs account A/B voices and synthesis passed.
- OpenAI account A/B synthesis passed; invalid-key responses remained rejected.
- Native system output remained valid: 184 voices, 198648-byte mono WAV,
  2.205805 seconds. The file was inspected, never played.
- Client cancellation returned in 2.062083 ms in this Debug M1 smoke run.
- The vendor observed peer disconnect **before** its delayed 3-second response.
- The audit found no loaned keys in the new isolated Vox store or diagnostics.
- The owned helper exited after daemon shutdown without forced cleanup.

Earlier audit artifacts were left untouched. This fix prevents new writes; it
cannot retroactively remove any prior reflected credentials from existing logs.

## Reproducible Vox-only regression

```sh
xcrun swift build --package-path swift --jobs 3
python3 scripts/test-private-tts.py
```

The committed fixture builds two fresh consumers of the model-free `VoxClient`,
then launches actual `voxd --private` and stock `voxttsd` in a temporary Vox home.
Its HTTP server is loopback-only. Synthetic keys are request-scoped; empty provider
key settings fence any ambient/keychain fallback without installing a global key.

It asserts account-specific voice lookups, valid WAV generation through both
vendors, OpenAI/ElevenLabs reflected-body 401 sanitation, a rejected keyless
request after loans and no loan values in the daemon home/logs/client output.

Two ElevenLabs requests are held in flight simultaneously. Client A cancels;
the fixture observes A's outgoing HTTP connection close before releasing B.
B still returns valid audio, remains connected and successfully generates again.
The helper PID is unchanged. A local run measured 0.075333 ms client cancellation
and 70.581 ms until the polling client observed the HTTP peer close. These are
smoke measurements, include scheduling/polling overhead and are not latency SLAs.
All nine expected vendor requests are asserted. Capability/socket and helper EOF
cleanup are checked. This regression runs in CI alongside private annotation.

Unit tests additionally cover already-cancelled calls, exact notification IDs,
transport timeouts, deliberately late replies, oversized frames rejected before write, continuation ownership and
legacy-provider local cancellation without killing the process.

## Limits

Closing the HTTP request does not guarantee that a real vendor stops processing,
retains no data or refunds accepted work. A cancelled VoxClient call disconnects
that client and cancels all its owned work; independently cancellable operations
should use separate client connections. Existing public synthesis-session cancel
semantics remain unchanged. No live vendor quality, availability or account-tier
access was tested. Native ASR selection, weights, residency and measurements are
unchanged.

## Checks

Full local Swift suite: 257 Swift Testing cases pass. Focused transport/provider
and task-ownership tests also pass with a strict cooperative executor. The root
model-free client (via the fixture consumer) and iOS simulator client compile.
Bun clients/CLI/browser tests: 61 pass, 8 opt-in integration skips. Documentation
generation/check passes with the existing audit warnings. Both committed private
TTS and annotation fixtures pass without paid calls. Broad repository TypeScript
checking remains outside this fix and retains its previously documented failures.
