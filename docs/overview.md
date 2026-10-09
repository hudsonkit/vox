---
title: Vox Overview
description: Choose the right Vox integration mode and understand the stack's runtime, package, and telemetry surfaces.
---

Vox is a local-first voice stack for macOS and iOS. It supports both speech-to-text (STT / ASR) and text-to-speech (TTS), and you can use it in two main ways:

- Embed mode: Apple apps link Vox's Swift packages directly and keep speech in and speech out in process.
- Companion mode: `voxd` exposes the runtime over local WebSocket JSON-RPC, and `VoxBridge` / `voxbridge` exposes an HTTP bridge for browser clients when web or shared-process access is useful.

Main surfaces:

- Swift packages: `VoxCore` and `VoxEngine` (start with `VoxDictation`), plus optional `VoxAppleSpeech` for speech output, for apps that run Vox in process. `VoxService` and `VoxBridge` are the companion runtime itself, not needed in an app.
- `voxd`: Vox Companion, the Swift daemon. Warm-up, telemetry, bridge transport, shared-process coordination.
- `@voxd/sdk`: TypeScript SDK for Bun/Node and other companion-connected integrations. WebSocket JSON-RPC to `voxd`.
- `@voxd/client`: Browser SDK. HTTP bridge to the Vox Companion for web apps.
- `@voxd/cli`: Node CLI. Health checks, model management, transcription, synthesis, voices, warm-up, and benchmarks.

## Which surface to reach for

- Use the Swift packages when you are modifying a macOS or iOS app and want speech to stay in process.
- Use `@voxd/sdk` when you want a local Bun or Node client to talk to the companion daemon over WebSocket JSON-RPC.
- Use `@voxd/client` when you want a browser app to talk to the local HTTP bridge on the same Mac.
- Use `@voxd/cli` when you want operator commands, warm-up controls, voice listing, or reproducible benchmarks.

## Why it exists

Many voice stacks hide lifecycle, warm-up, and latency. Vox tries to keep those parts visible:

- Model stays local
- STT and TTS stay explicit runtime capabilities instead of hidden backend switches
- Warm-up is an explicit API
- Latency dimensions (`clientId`, `route`, `modelId`) are preserved
- Runtime stays easy to inspect from the start

## Repository layout

- `swift/`: VoxCore, VoxEngine, VoxService, VoxBridge, voxd companion
- `apps/vox/`: full Vox companion app
- `apps/minivox/`: small, single-purpose menu-bar dictation app
- `packages/client/`: `@voxd/sdk` (TypeScript SDK)
- `packages/web-client/`: `@voxd/client` (browser SDK)
- `packages/cli/`: `@voxd/cli` (Node CLI)
- `docs/`: Dewey source content
- `site/`: website and docs UI

## Design principles

1. Root cause over workaround.
2. Warm-up is part of the product, not an implementation detail.
3. Instrumentation is part of the API surface.
4. Multi-client support stays visible in the protocol and telemetry.

## How it fits together

Apple app teams embed the Swift packages directly and keep the same provider, warm-up, and telemetry semantics in process. Bun and Node tools use `@voxd/sdk` against `voxd`, browser apps use `@voxd/client` against the local HTTP bridge, and operators use `vox` to check health, list voices, transcribe, synthesize, warm models, and benchmark both speech paths. Companion mode lets `voxd` stay warm across browser integrations, local tools, and other shared-process clients while the bridge stays narrow and browser-facing.

## Reference implementations

- `apps/minivox/` is the small, single-purpose menu-bar dictation app built on the direct Apple embed path.
- `packages/client/` and `packages/web-client/` are good companion-mode SDK references in the repo.

Install the signed and notarized Minivox app through the existing CLI or Homebrew:

```bash
npx -y @voxd/cli@latest install mini
# or
brew install --cask arach/vox/minivox
```

The installer opens Minivox automatically. Look for the waveform in the menu bar, put the text cursor where you want your dictation, and press **Right ⌘M** to start. Allow microphone access if asked, then press **Right ⌘M** again to stop. Minivox copies the result and pastes it when Accessibility access is enabled. The first dictation may download Parakeet.

Both installers expose a `minivox` command. Run `minivox settings` to change the shortcut or microphone, or `minivox quit` to stop the menu-bar app. The npm installer accepts `--quiet` and `--verbose` to control setup output.

## Workflows

These examples assume `vox` is on your `PATH`. In a repo checkout, replace `vox` with `node packages/cli/dist/index.js` after `bun run build`.

```bash
bun install && bun run build
vox daemon start
vox doctor

vox warmup start parakeet:v3
vox transcribe file --model parakeet:v3 --metrics --timestamps /tmp/sample.wav
vox models catalog

vox voices --model gpt-4o-mini-tts
vox speak --model gpt-4o-mini-tts --metrics "Hello from Vox"

vox transcribe bench --model parakeet:v3 /tmp/sample.wav 5
vox speak bench --model gpt-4o-mini-tts "Hello from Vox" 5
vox perf dashboard --client vox-cli
```

Continue with the [Quickstart](./quickstart.md), [Models and plugins](./models.md), [Swift Embed Guide](./apple-embed.md), or [Web Integration Guide](./web-integration.md) for the surface you chose.
