<p align="center">
  <img src="https://raw.githubusercontent.com/arach/vox/main/assets/readme/cli.svg" alt="Vox CLI — transcribe, speak, and manage Vox from the terminal" width="100%" />
</p>

# @voxd/cli

Transcribe files, generate speech, and manage Vox from the terminal. Installing this package adds the `vox` command.

## Install

```bash
npm install -g @voxd/cli
```

Requires Node 22+ on macOS.

## First-time setup

Install [Vox Companion](https://voxd.cc/download), then connect the CLI to its local service:

```bash
vox install
vox doctor
```

`vox doctor` should finish with `ready: true`.

## Common tasks

```bash
# Transcribe a file
vox warmup start parakeet:v3
vox transcribe file --metrics --timestamps /tmp/sample.wav

# Generate speech
vox voices --model avspeech:system
vox speak --metrics "Hello from Vox"

# Inspect the runtime
vox daemon status
vox perf dashboard
vox logs daemon --tail 80
```

Run `vox help` for the complete command list.

## Install Minivox

Minivox is the small, single-purpose dictation app. Install it without adding another npm package:

```bash
npx -y @voxd/cli@latest install mini
```

The installer opens Minivox automatically. Look for the waveform in the menu bar. Put the cursor where you want text, press **Right ⌘M** to start dictating, then press **Right ⌘M** again to stop. The first use asks for microphone access, and the first dictation may download Parakeet. Minivox always copies the result; grant Accessibility access when prompted if you also want it pasted automatically.

The installer adds `minivox` under `~/.local/bin`. Use `minivox settings` to change the shortcut or microphone. Use `--quiet` for errors-only output or `--verbose` to include Apple verification and disk-image details.

```bash
minivox
minivox settings
minivox quit
```

## Useful command groups

- `vox doctor` — check that Vox is ready
- `vox transcribe` — transcribe files, benchmark, or use the microphone
- `vox speak` and `vox voices` — generate speech
- `vox warmup` and `vox models` — prepare speech models
- `vox history`, `vox logs`, and `vox perf` — inspect activity and timing
- `vox daemon` — start, stop, or check the local service

## Choose the right package

- Terminal: `@voxd/cli`
- Bun or Node: [`@voxd/sdk`](https://www.npmjs.com/package/@voxd/sdk)
- Browser: [`@voxd/client`](https://www.npmjs.com/package/@voxd/client)
- macOS or iOS app: embed `VoxCore` and `VoxEngine`

## Learn more

- [Quickstart](https://voxd.cc/docs/quickstart/)
- [Runtime guide](https://voxd.cc/docs/runtime/)
- [Download Vox Companion](https://voxd.cc/download)

## License

[MIT](./LICENSE)
