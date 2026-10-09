# Vox

Open-source speech-to-text and text-to-speech for Mac apps.

```swift
let dictation = VoxDictation(clientId: "my-app")
try await dictation.warmUp()
try await dictation.start()
let text = try await dictation.stop().text
```

**Start here: [voxd.cc/docs/start](https://voxd.cc/docs/start)**

- [Try Minivox in 60 seconds](https://voxd.cc/docs/start-mac): `bunx @voxd/cli@latest install mini`
- [Vox in your app](https://voxd.cc/docs/start-swift): dictation and speech output in a Swift app
- [Vox for Node](https://voxd.cc/docs/start-node) and [Vox for the browser](https://voxd.cc/docs/start-browser): use Vox on your Mac from other programs
- [Build with an agent](https://voxd.cc/docs/start-agent): prompts that wire Vox in correctly

This repo brings together the Hudson-powered menu bar app, the Swift runtime, the companion daemon, the TypeScript clients, and the CLI.

- `VoxCore`, `VoxEngine`, `VoxService`, and `VoxBridge`: embeddable Swift packages for macOS and iOS apps.
- `voxd`: Vox Companion, the Swift daemon for web-facing, shared-process, and operator integrations.
- `@voxd/sdk`: TypeScript SDK. Typed JSON-RPC client for Vox Companion integrations.
- `@voxd/client`: Browser SDK. HTTP bridge client for local web integrations.
- `vox`: Node CLI. Health checks, benchmarks, warm-up scheduling, dashboards.
- `Vox.app`: Hudson-based macOS menu bar app, packaged as a signed and notarized DMG by release automation.
- `Minivox`: tiny macOS menu-bar dictation example that embeds Vox directly and copies each transcript.

Apple apps can embed Vox directly. Bun and Node tools can connect to `voxd` over local WebSocket JSON-RPC. Browser clients can connect through the companion HTTP bridge with `@voxd/client`.

## Pick a surface

- Build a native Apple app: start with `VoxDictation` in `VoxCore` + `VoxEngine`; add `VoxService` or `VoxBridge` only for deliberate companion/runtime embedding.
- Build a local tool or companion-connected service: start with `voxd` plus `@voxd/sdk`.
- Build a browser integration: start with `@voxd/client` plus the local bridge path.
- Operate or benchmark Vox itself: start with the `vox` CLI.

## Get Going Fast

Requirements:

- Apple Silicon; Intel Macs are not supported
- macOS 14+ for the Swift transcription packages; macOS 26+ for Minivox, the Hudson menu app and Apple SpeechTranscriber
- Bun 1.2+
- Node 22+
- Swift 6.2+
- `uv` for the MLX-backed demo paths

The built-in ASR shortlist includes CoreML Parakeet and Apple SpeechTranscriber. The optional MLX Audio bridge adds Qwen3-ASR, Cohere Transcribe, Nemotron 3.5 ASR Streaming, Whisper, and MLX Parakeet variants.

### a. dev

To work on Vox:

```bash
git clone https://github.com/hudsonkit/vox.git
cd vox
bun install
bun run build
bun run test
```

Useful loops:

```bash
bun run site:dev
bun run docs:build
swift build --package-path swift
```

### b. client

To use Vox Companion locally from the CLI or SDK:

```bash
git clone https://github.com/hudsonkit/vox.git
cd vox
bun install
bun run build
```

Start the daemon, verify health, then transcribe:

```bash
node packages/cli/dist/index.js daemon start
node packages/cli/dist/index.js doctor
node packages/cli/dist/index.js models preload parakeet:v3
node packages/cli/dist/index.js transcribe file /path/to/audio.wav
```

If you are writing a local client, start here:

- `packages/client/` for the TypeScript SDK
- `packages/web-client/` for the browser SDK
- `swift/` for direct Apple embed mode

### c. Minivox

To run the tiny menu-bar dictation app:

```bash
npx -y @voxd/cli@latest install mini
```

The installer opens Minivox automatically. Look for the waveform in the menu bar, then:

1. Put the text cursor where you want your dictation.
2. Press **Right ⌘M** to start and allow microphone and Accessibility access if asked.
3. Press **Right ⌘M** again to stop. Minivox copies the result and pastes it when Accessibility access is enabled.

Run `minivox settings` to change the shortcut or microphone. The first dictation may download Parakeet.

Or install the same signed and notarized release with Homebrew:

```bash
brew install --cask arach/vox/minivox
```

What Minivox does:

- records locally from the mic
- transcribes with Parakeet
- copies the finished dictation to the clipboard
- keeps Parakeet warm-up and transcription timing visible

Notes:

- The first dictation may download Parakeet.
- The app will ask for microphone access.

Minivox lives in `apps/minivox/` and is the small, single-purpose Vox dictation app.

## Layout

- `swift/` contains `VoxCore`, `VoxEngine`, `VoxService`, and the `voxd` daemon.
- `apps/vox` contains the full Vox companion app.
- `apps/minivox` contains the small menu-bar dictation app.
- `packages/client` contains the TypeScript SDK for talking to `voxd` over local WebSocket JSON-RPC.
- `packages/web-client` contains the browser SDK for talking to the local HTTP bridge.
- `packages/cli` contains the `vox` CLI.
- `docs/` contains Dewey source docs.
- `site/` contains the marketing site, docs route, and OG generation.

## Commands

```bash
bun install
bun run dev
bun run build
bun run build:all
bun run test
bun run test:e2e
bun run site:build
bun run site:og
bun run docs:generate
```

## Telemetry

Each transcription or synthesis request appends a tagged sample to `~/.vox/performance.jsonl` with `clientId`, `route`, `modelId`, and `voiceId` when applicable.

This lets you answer a few practical questions: is the hot model fast, which integration is regressing, and whether latency is in inference, audio prep, or cold runtime work.

### CLI

```bash
vox daemon start
vox doctor
vox models list
vox models catalog
vox models catalog refresh
vox plugins list
vox plugins install mlx-vlm
vox models install
vox warmup start
vox warmup schedule 500
vox logs daemon --tail 80
vox transcribe status
vox transcribe cancel
vox transcribe file --timestamps /path/to/audio.wav
vox transcribe bench /path/to/audio.wav 5
vox perf dashboard
vox transcribe live --timestamps
```

## Companion Runtime

- Runtime discovery: `~/.vox/runtime.json`
- Latency samples: `~/.vox/performance.jsonl`
- Daemon logs: `~/.vox/logs/voxd.log` (written even when `voxd` is auto-started by the CLI)

`voxd` is Vox Companion: the shared-process and web-facing transport for Vox. `bun run test:e2e` is an opt-in macOS integration suite that boots `voxd`, preloads the model, synthesizes speech with `say`, and checks `transcribe file` output against keyword expectations.

Speech synthesis supports Apple system voices locally and OpenAI TTS (`gpt-4o-mini-tts`, `tts-1`, and `tts-1-hd`) when `OPENAI_API_KEY` is configured. The packaged app bundles `voxd` and `voxttsd` so the menu bar app and CLI share the same companion runtime.

## Docs and site

- Dewey source docs: `docs/`
- Generated handoff files: `AGENTS.md`, `llms.txt`, `docs.json`, `install.md`
- Website and `/docs` route: `site/`
- OG image template: `site/og-template.html`
- GitHub social preview: `.github/social-preview.png` (1280×640). Generate with `bun run --cwd site scripts/generate-og.ts --github-only`, then upload the PNG in the repository Settings → Social preview.

## Release automation

- GitHub Pages deploys from `.github/workflows/deploy-pages.yml` to `https://voxd.cc`
- npm publishing runs from `.github/workflows/publish-packages.yml` on `v*` tags and publishes `@voxd/sdk`, `@voxd/client`, and `@voxd/cli`
- DMG builds run from `.github/workflows/release-dmg.yml`. Tag builds create or update the matching GitHub Release and upload `Vox.dmg` and `Minivox.dmg`.
- Manual DMG releases can be started from the workflow page with a version. The workflow validates the repo versions, builds the DMG, signs and notarizes it, creates `v<version>` when needed, creates the GitHub Release, and uploads the installer.

Required release secrets:

- `DEVELOPER_ID_APPLICATION_CERT_BASE64`
- `DEVELOPER_ID_APPLICATION_CERT_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID` and `APP_STORE_CONNECT_ISSUER_ID` as repository variables, or secrets if needed
- `HUDSON_DEPLOY_KEY` for the private SwiftPM dependency used by the macOS app bundles
- `NPM_TOKEN` in the `PRODUCTION` environment for package publishing

The DMG workflow also accepts the older Apple ID notarization secrets (`APPLE_ID`, `APPLE_APP_PASSWORD`, and `APPLE_TEAM_ID`) as a fallback, plus the legacy certificate names (`APPLE_SIGNING_CERT_BASE64` and `APPLE_SIGNING_CERT_PASSWORD`).
