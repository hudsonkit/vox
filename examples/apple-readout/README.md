# Embedded Apple readout controls

Public-only Swift 5-language-mode consumer of Swift 6 `VoxCore` + `VoxEngine` + `VoxAppleSpeech`. The app owns one
`ReadoutSurface` per audible surface, not an `AVSpeechSynthesizer` or local daemon.
Initialization and compilation do not start playback or download models.

- `start` returns request/generation identity. Existing `speak(_:)` remains available.
  Its optional pitch/volume parameters become per-request `SpeechOutputOptions`:
  finite pitch 0.5...2.0 and volume 0...1, nil for platform defaults. Invalid values
  throw before replacing playback. System speech supports both and preserves them
  across seek/pause/resume. Generated audio supports player volume, not pitch.
  Observe failed events for unsupported options after asynchronous resolution;
  custom sinks never silently accept controls they cannot apply.
- Wait for `playing`, then use identity-scoped `pause` / `resume`. A system control's
  true return means accepted; `paused` / `resumed` delegate events acknowledge it.
  False means the sink declined. `status()` and events expose actual capabilities.
- `seek` replaces the utterance using an original-text UTF-16 character boundary.
  It returns a new generation with the same request ID. This is text restart,
  not sample-accurate audio seek. The replacement starts playing, even if paused.
- `wordRange` events contain original-request UTF-16 offsets and native will-speak
  evidence. They are not a playback clock or forced alignment. Apply ranges only
  to the exact original text, never markdown-flattened or edited text.
- Generated audio can pause/resume its existing player, but supplies no word ranges
  or text seek. Custom legacy sinks default to unsupported controls unless opted in.
- Stop/cancel/new request fence old callbacks. Keep the returned identity; after
  hopping to a UI queue, discard events whose identity no longer matches the
  current surface. Already emitted events cannot be retracted from a caller queue.
- iOS audio-session configuration stays optional and application-owned. See the
  injectable `AVAudioSessionSpeechConfiguration`; interruptions/permissions and
  background audio policy are not configured implicitly.

Compile for ARM64 iOS Simulator (no install, audio, model load or vendor call):

```sh
xcrun swift build --package-path examples/apple-readout \
  --triple arm64-apple-ios17.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  --scratch-path /private/tmp/vox-readout-ios --jobs 3
```

`nativeStreamingAvailable()` is inventory-only and returns false on Simulator.
Physical iOS 17.4+ and an explicitly installed/preloaded native model are required
for Unified streaming; this example makes no hardware inference/memory claim.
