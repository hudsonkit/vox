# vox

> Local-first voice stack for Apple apps, web companions, and developer tools

## Critical context

- Always solve root cause before looking for workarounds and quick fixes.
- Swift owns the embeddable Apple engine surface and the companion transport surface.
- Rust is the default for new external ASR provider implementations. Use `providers/vox-provider` for the process protocol and `providers/example` as the starter; keep install and preload explicit.
- Bun/Node clients and the CLI communicate with `voxd` only in companion mode.
- Warm-up is a public capability. Do not hide it in launch side effects or opaque helpers.
- Preserve `clientId`, `route`, `modelId`, and `voiceId` where applicable in telemetry.
- Keep session ownership and stop/cancel semantics explicit in multi-client work.

## Choose the integration mode first

| Caller | Default Vox surface |
|---|---|
| macOS or iOS app process | `VoxCore` + `VoxEngine` (+ optional `VoxAppleSpeech`) |
| Bun or Node tool | `voxd` + `@voxd/sdk` |
| Web app or browser extension | Vox Companion + `@voxd/client` |
| Operator or benchmark workflow | `@voxd/cli` |

Do not put `voxd`, `@voxd/sdk`, or `@voxd/client` inside an Apple app unless the feature is intentionally cross-process. Add `VoxService` or `VoxBridge` to an embed target only when it deliberately owns companion/runtime behavior.

## Project map

| Surface | Path |
|---|---|
| Swift package manifest | `swift/Package.swift` |
| Daemon | `swift/Sources/voxd/main.swift` |
| Runtime service | `swift/Sources/VoxService/` |
| ASR, annotation, and TTS engines | `swift/Sources/VoxEngine/` |
| Optional Apple speech output | `swift/Sources/VoxAppleSpeech/` |
| Shared Swift types and telemetry | `swift/Sources/VoxCore/` |
| Vox companion app | `apps/vox/` |
| Minivox dictation app | `apps/minivox/` |
| Companion TypeScript SDK | `packages/client/src/` |
| Browser client | `packages/web-client/src/` |
| CLI | `packages/cli/src/index.ts` |
| Rust provider protocol and adapters | `providers/` |
| Human docs | `docs/*.md` |
| Compact agent briefs | `docs/agent/*.agent.md` |
| Marketing site | `site/` |
| Docs UI | `docs-site/` |

## Canonical source rules

- CLI syntax: verify `packages/cli/src/index.ts` or run `vox help`.
- Companion SDK methods and shapes: verify `packages/client/src/client.ts` and `packages/client/src/types.ts`.
- Browser methods and HTTP paths: verify `packages/web-client/src/client.ts` and `packages/web-client/src/types.ts`.
- RPC dispatch and session behavior: verify `swift/Sources/VoxService/VoxRuntimeService.swift` and the coordinators beside it.
- Provider behavior: verify the registries and external provider implementations in `swift/Sources/VoxEngine/`.
- Swift products and deployment targets: verify `swift/Package.swift`.

When prose and source disagree, treat source as current and update the relevant human doc plus its agent brief in the same change.

## Area-specific guidance

- `swift/Sources/VoxEngine/`: keep model lifecycle and instrumentation explicit; preserve stage metrics.
- `swift/Sources/VoxService/`: preserve `clientId`, connection ownership, backpressure, and distinct stop/cancel behavior.
- `packages/client/`: expose runtime capabilities and result metrics directly; do not duplicate stale type shapes in callers.
- `packages/web-client/`: keep the HTTP surface narrow, probe before use, preserve origin gating, and leave capture/permissions to the browser app.
- `packages/cli/`: commands are operator tools; output should be actionable and benchmarks reproducible.
- `site/` and `docs-site/`: keep the restrained Vox visual language, valid copyable commands, accessible contrast, and working mobile navigation.

## Agent documentation workflow

Start with `docs/agents.md`, then use the paired brief for the surface you are changing. The rendered docs expose **Copy agent brief** only when a paired `.agent.md` file exists.

- `llms.txt` is the compact routing handoff.
- `llms-full.txt` contains full human docs plus all compact agent briefs.
- `bun run docs:generate` refreshes deterministic handoff artifacts.
- `bun run docs:check` fails when generated artifacts or required docs drift.

Do not hand-edit `llms.txt`, `llms-full.txt`, or `docs.json`.

## Commands

```bash
bun install
bun run build
bun run test
bun run test:e2e
bun run test:providers
bun run build:providers
bun run site:dev
bun run site:build
bun run docs:generate
bun run docs:check
```

Focused checks:

```bash
bun test packages/client/test packages/cli/test packages/web-client/test
swift test --package-path swift
bun run site:lint
```

## Do not assume

- Embed mode records performance samples automatically.
- Apple apps need Vox Companion.
- ASR accepts an in-memory buffer in the public embed surface; the current entrypoint takes a file URL.
- Stop and cancel are interchangeable.
- A proposal document describes shipped behavior without confirmation in source.
- A copied API shape is current without checking the exported source types.
