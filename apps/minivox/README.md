# Minivox

A tiny macOS menu-bar app for fast, local dictation.

Minivox deliberately does one thing:

1. record a short voice note;
2. transcribe it locally with Parakeet through `VoxEngine`;
3. copy the finished text to the clipboard.

There is no `voxd`, browser bridge, reply engine, or text-to-speech step. The app keeps warm-up visible and shows transcription timing without turning dictation into a dashboard.

## Install and dictate

```bash
npx -y @voxd/cli@latest install mini
```

The installer opens Minivox automatically. Look for the waveform in the menu bar, then:

1. Put the text cursor where you want your dictation.
2. Press **Right ⌘M** to start and allow microphone and Accessibility access if asked.
3. Press **Right ⌘M** again to stop. Minivox copies the text and pastes it when Accessibility access is enabled.

The first dictation may download Parakeet. Run `minivox settings` to change the shortcut or microphone.

## Run

From the repository root:

```bash
swift run --package-path apps/minivox Minivox
```

The first dictation may download and load Parakeet. Minivox asks for microphone access when you record for the first time. Choose a microphone in **Settings**; Minivox shares that input preference with Vox. Use the visible **Warm up Parakeet** control when you want the model ready before you start speaking.

## Package

Create a signed local app bundle and disk image from the repository root:

```bash
bun run minivox:bundle
```

The package is written to `dist/minivox/Minivox.dmg`. Local builds are ad hoc signed and stay out of the website download directory by default. Set `MINIVOX_SIGN_IDENTITY` and `MINIVOX_NOTARY_PROFILE` to create a Developer ID-signed and notarized release.

The app bundle includes a small command helper:

```bash
minivox            # launch the menu-bar app
minivox settings   # open settings
minivox quit       # quit the app
```

The npm installer links the helper under `~/.local/bin`; the Homebrew cask exposes the same helper through Homebrew's bin directory. Add `--quiet` or `--verbose` to `vox install mini` to control installer output.

## Core integration

```swift
let asr = EngineManager()

let transcript = try await asr.transcribe(
    url: recordingURL,
    modelId: "parakeet:v3"
)

NSPasteboard.general.clearContents()
NSPasteboard.general.setString(transcript.text, forType: .string)
```

Minivox is the small, single-purpose Vox app: it owns microphone capture and runs `VoxEngine` in process.
