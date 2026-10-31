# Embedded Apple readout controls

## Scope and caller contract

This follow-up adds native `VoxAppleSpeech` readout controls for an embedded Apple
app. It does not add Apple batch ASR, a daemon, an external provider, a vendor call
or a Talkie implementation. Existing ASR residency/reload investigation is unchanged.

```swift
let identity = try await output.start(request)
// Wait for playing and inspect capabilities before enabling controls.
let accepted = try await output.pause(identity)
// System accepted != paused acknowledgement. Wait for the paused event.
let continued = try await output.resume(identity)
let replacement = try await output.seek(identity, toUTF16Offset: originalOffset)
try await output.stop(replacement)
```

`start(_:)` returns `SpeechOutputIdentity(requestId:generation:)`. Existing `speak`
and no-argument stop/cancel remain source-compatible. Every event carries both
identity fields, actual sink `capabilities`, optional `utf16Range` and existing
model/voice/output-route identity. `status()` reports the current identity, phase,
capabilities, original text UTF-16 length and replacement start offset.

New phases are `paused`, `resumed` and `wordRange`; consumers with exhaustive enum
switches must handle them. Range events do not overwrite the playback state.

| Actual sink | Pause/resume | Original-text UTF-16 ranges | Text seek |
|---|---|---|---|
| Built-in system speech | Genuine platform pause/continue, acknowledgement events | Native will-speak callbacks only | Replacement generation, same original request |
| Built-in generated audio | Retained player pause/play; no new prepare or generation | Unavailable | Unavailable |
| Existing custom sink | Unsupported unless explicitly implemented | Unsupported unless explicitly implemented | Unsupported unless explicitly implemented |

A system control returning true means accepted. Only matching delegate callbacks
produce paused/resumed events. False does not invent a state transition. Commands
require playing/resumed for pause, paused for resume, and no pending system control.
Status/capabilities can be unavailable while a new request resolves. Pause never
calls stop or re-synthesizes. Generated audio retains its player and position.

## Per-request native pitch and volume

`SpeechOutputOptions(pitchMultiplier:volume:)` is separate from generation-only
`SynthesisRequest`. Pass it to `start(request,options:)` or the throwing explicit
options `speak` overload. Pitch accepts finite 0.5...2.0 and volume finite 0...1,
matching the SDK utterance property bounds. Nil means fresh platform defaults.
Invalid options throw before replacing the active request. They are not clamped.

Live system speech applies both to the actual utterance before enqueue. Events
and status expose requested options and actual `canSetPitch` / `canSetVolume`.
Seek preserves options; pause/resume retains the utterance/player; new requests
without options do not inherit prior settings. Even an explicit neutral value
requires support, rather than silently pretending a custom sink applied it.

Generated audio cannot apply pitch and rejects it before synthesis. The built-in
player supports genuine local volume. A custom player's capability/setVolume check
occurs after generation but before play; missing support or false rejects playback.
Asynchronously discovered unsupported options produce identity-bearing terminal
failed events with typed `controlError` and human-readable `error`, not ignored
parameters or localized-text parsing. Existing custom sinks default unsupported.
No provider generation options or pitch-shifted generated audio are invented.

Four additional injection tests cover actual utterance pitch/volume values,
seek/default reset, boundary values, NaN/infinity/out-of-range rejection without
cancelling active playback, unsupported native sinks, pre-generation pitch rejection,
and unsupported/declined player volume. The production audio sink's injected engine
also verifies volume forwarding and invalid-value rejection before platform calls.

## UTF-16 and replacement ownership

Seek uses an offset into the exact **original** request, not a normalized copy,
audio time, byte offset, character count or fraction. It rejects negative/out-of-range
values, surrogate/grapheme interiors, end-of-text and whitespace-only remaining
suffixes without cancelling current playback. A valid seek cancels the old
session and starts its suffix with a new generation, even if previously paused.
Voice/speed and original request text remain unchanged. Repeated seek offsets
remain original-relative, not relative to the preceding suffix.

Native utterance-relative word ranges are shifted by that session's start offset.
Bounds, positive length, overflow and UTF-16 scalar boundaries are checked before
emission. A regression initially demonstrated that Foundation's NSRange conversion
could accept a half-surrogate index; explicit code-unit boundary validation now
rejects it. A cached suffix/code-unit view avoids reconstructing the whole text
for every word callback. No range is fabricated from generated audio duration,
text length, TTS provider scores or proportional mapping.

Ranges anticipate the spoken word, not a measured audio clock or forced alignment.
Use them against the same original string. Apple documents the underlying
[will-speak range callback](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:willspeakrangeofspeechstring:utterance:)),
[pause](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/pausespeaking(at:)) and
[continue](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/continuespeaking()) surfaces.

All scoped controls and system callbacks require matching request **and** generation.
A reused request ID is not permission to mutate its replacement. An awaiting pause
cannot update a later session. Queued production pause/continue re-check the live
generation before reaching AVFoundation. A late old-generation stop no longer
uses retained old utterance metadata as permission to globally stop a new one.
Stop/cancel/new-request/seek retain one terminal event per replaced generation.

The controller cannot retract events already emitted into a caller's UI queue.
Re-check identity after that queue/actor hop; use status to reconcile current state.
Application queueing, interruptions, audio-session policy and background permissions
remain application-owned. Do not share one mutable playback sink between controllers.

## Native streaming Simulator guard

Production `NativeStreamingASR` inventory now excludes Simulator, including ARM64.
Production install/preload fail before model work there. Physical iOS 17.4+ is the
native Unified target; this change does not claim iOS device accuracy, latency,
placement or footprint. The injected pipeline test seam remains available without
models, downloads or ANE hardware. Parakeet v3 remains the file policy.

## Verification

- **289 Swift Testing cases** plus XCTest suites pass; 15 new tests cover readout
  controls/sink scheduling and production streaming availability.
- **50 strict cooperative focused tests** pass. Existing source-compatible injected
  sinks and enqueue-window cancellation tests continue to pass.
- New public-only Swift 5-language-mode `examples/apple-readout` imports `VoxCore`, `VoxEngine` and
  `VoxAppleSpeech`, owns no direct Speech/AVSpeechSynthesizer and compiles for ARM64
  iOS Simulator. It exercises exported start/control/status/range contract types
  and production streaming inventory at compile time. It is a CI step.
- **61 Bun tests pass / 8 opt-in skips**; generated docs pass consistency checks
  (existing aggregate documentation score 99/100).
- Tests use injected synthesis/player engines, not audible system playback or paid
  APIs. No device/simulator app was installed, no installed service was changed,
  no native ASR model was loaded/downloaded/deleted, and no normal-Agent window started.

The Unicode tests include emoji/skin-tone/ZWJ sequences, decomposed accents and CJK.
They verify repeated original-relative seeking, invalid offset non-mutation,
rejected/unsupported controls, delayed acknowledgements, mismatched request IDs,
reused IDs/new generations, stale controls/events, pending-pause replacement,
one terminal event and generated-audio non-fabrication.

This is source/injection/compilation evidence, not a physical-iOS audible acceptance
test, voice-specific behavior guarantee, audio-interruption guarantee or benchmark.
CI retains existing isolated loopback annotation/TTS regressions; this readout
contract does not alter vendor generation/annotation or private transports.
