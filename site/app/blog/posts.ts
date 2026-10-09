export interface BlogPost {
  slug: string;
  title: string;
  date: string;
  summary: string;
  content: string;
}

export const posts: BlogPost[] = [
  {
    slug: "why-vox",
    title: "Why I Built Vox",
    date: "2026-03-15",
    summary:
      "I kept rebuilding the same voice plumbing for every project. Vox is the shared local stack that came out of that repetition.",
    content: `I was building a macOS app that needed voice input. Mic permissions, audio capture, model loading, keeping things warm so the first command doesn't lag. Then the app needed spoken output. Then I needed the same capabilities in a browser surface and a local tool. Each time I was solving the same runtime problems again.

So I pulled the runtime out into its own thing. That's Vox.

## The interesting part isn't the runtime

There are already strong speech models. What's less fun is everything around them: permissions, capture, playback, model lifecycle, warm-up, multi-client ownership, and figuring out where latency actually went.

These are solved problems individually, but every product assembles them again. Vox puts the Apple-native engine surface in Swift, exposes the same lifecycle through Vox Companion for browser and local-tool integrations, and keeps warm-up and telemetry visible across both modes.

## Why open source it

Honestly, I'd use it myself either way. But it seemed like the kind of thing that might save someone else a few weekends. If you're building a voice feature, the runtime should not be the hard part. The hard part should be whatever you're actually making.

The internals are intentionally visible. Warm-up is a public API. Stage timings come back with transcription and synthesis. Client identity flows through telemetry so you can tell which integration is slow.

## Where it's going

Vox supports multiple ASR and TTS providers. The provider protocol lets external processes report models, preload them, transcribe files, list voices, and synthesize audio without taking on runtime or session ownership.

I don't have grand plans for this. If people find it useful, great. If not, I'll keep using it for my own projects. The code is open source and the docs are up.

## Get started

\`\`\`bash
git clone https://github.com/hudsonkit/vox.git && cd vox
bun install && bun run build
node packages/cli/dist/index.js daemon start
node packages/cli/dist/index.js doctor
\`\`\`

Four commands, a working local runtime. The docs cover the Swift embed, browser, SDK, provider, and observability paths.`,
  },
  {
    slug: "provider-protocol",
    title: "The Provider Protocol: Bring Your Own Speech Engine",
    date: "2026-03-17",
    summary:
      "Vox is a runtime, not a model. Any executable that speaks newline-delimited JSON-RPC can provide ASR or TTS.",
    content: `Vox handles runtime concerns such as audio capture, playback handoff, sessions, warm-up scheduling, multi-client coordination, and telemetry. Speech engines stay behind a small provider protocol.

Some teams need a different ASR model. Others want system speech, a local MLX voice, or a remote TTS provider. The right abstraction is not one blessed model. It is a stable runtime around whichever model fits the product.

## What a provider is

A provider is an executable that reads newline-delimited JSON-RPC from stdin and writes responses to stdout. Vox spawns it on first use and keeps it alive for the daemon lifetime.

An ASR provider receives an audio-file path and returns text, word timing, and metrics. A TTS provider receives text and returns encoded audio plus metrics. Providers do not own WebSocket connections, app sessions, microphone permissions, or playback.

## The protocol surface

All providers can expose \`models\`, \`install\`, and \`preload\`. ASR providers add \`transcribe\`. TTS providers add \`voices\` and \`synthesize\`.

Every transcription or synthesis result includes stage metrics. \`totalMs\` is required for both paths, and ASR also requires \`inferenceMs\`. Those measurements feed the same Vox telemetry tagged by model, route, client, and voice.

## Registration

Register providers in \`~/.vox/providers.json\`:

\`\`\`json
{
  "providers": [
    {
      "id": "whisper-cpp",
      "kind": "asr",
      "command": ["/usr/local/bin/vox-whisper", "--threads", "4"],
      "models": ["whisper-large-v3"]
    },
    {
      "id": "my-tts",
      "kind": "tts",
      "command": ["bun", "run", "/path/to/provider.ts"],
      "models": ["my-tts:v1"]
    }
  ]
}
\`\`\`

Register ASR and TTS as separate entries, even when one executable serves both. Vox routes by model ID and provider kind. The \`models\` field is optional when a provider reports models dynamically.

## Response shape

The important part of a minimal ASR response looks like this:

\`\`\`typescript
respond(req.id, {
  modelId: req.params.modelId,
  text: "transcribed text goes here",
  elapsedMs: elapsed,
  metrics: {
    inferenceMs: elapsed,
    totalMs: elapsed,
  },
});
\`\`\`

Keep stdout reserved for protocol messages. Logs belong on stderr.

## Telemetry across providers

The \`metrics\` object gives Vox the provider-side stage breakdown. Vox records the complete request as a tagged sample in \`performance.jsonl\`. The format and dashboard stay consistent across built-in and external providers.

The \`inferenceMs\` or \`synthesisMs\` value comes from the provider, while \`totalMs\` captures the whole provider request. Keep both honest so cold starts and steady-state inference remain distinguishable.

## Start from the canonical contract

The current protocol covers both speech directions, dynamic model discovery, preload progress, voice discovery, and explicit metrics. The canonical contract and a runnable template live in the Provider Protocol documentation and \`examples/provider-template/\`.`,
  },
];

export function getPost(slug: string): BlogPost | undefined {
  return posts.find((p) => p.slug === slug);
}
