# Swift embed

A small command-line program that runs Vox inside its own process, the same way an app does. Read along with [Vox in your app](../../docs/start-swift.md).

```bash
swift run vox-embed-demo warmup               # download and load the model
swift run vox-embed-demo listen 5             # record 5 seconds, print the text
swift run vox-embed-demo transcribe clip.wav
swift run vox-embed-demo speak "Hello from Vox"
```

Each transcription prints the model and timings, and writes a row to `~/.vox/performance.jsonl` under the client id `vox-embed-demo`.

`speak` uses the system voice. Set `OPENAI_API_KEY` to use `gpt-4o-mini-tts` instead; see `Speech.swift` for how the key reaches the engine.

The first `warmup` downloads the speech model, about 500 MB. macOS asks for microphone access the first time `listen` runs; the terminal app is what gets the permission.

- `Sources/VoxEmbedDemo/main.swift`: dictation with `VoxDictation`.
- `Sources/VoxEmbedDemo/Speech.swift`: choosing a speech output model.

This example depends on `../../swift` so it builds against your checkout. In your own project, depend on `https://github.com/hudsonkit/vox` instead.
