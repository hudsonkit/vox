/** @type {import('@arach/dewey').DeweyConfig} */
export default {
  project: {
    name: "vox",
    tagline: "Local-first voice stack for Apple apps, web companions, and developer tools",
    type: "monorepo",
    version: "0.1.0",
  },

  agent: {
    criticalContext: [
      "Always solve root cause before looking for workarounds and quick fixes.",
      "Vox is an Apple-platform voice stack: Swift owns the embeddable engine surface and the companion transport surface.",
      "The Bun workspace contains the CLI and TypeScript clients, which communicate with voxd in companion mode.",
      "Performance instrumentation is first-class: preserve clientId, route, and modelId dimensions in telemetry.",
      "Warm-up semantics are part of the public runtime surface and should remain usable for multi-client integrations.",
    ],

    entryPoints: {
      "daemon": "swift/Sources/voxd/main.swift",
      "service": "swift/Sources/VoxService/",
      "engine": "swift/Sources/VoxEngine/",
      "appleSpeech": "swift/Sources/VoxAppleSpeech/",
      "core": "swift/Sources/VoxCore/",
      "sdk": "packages/client/src/",
      "cli": "packages/cli/src/index.ts",
      "docs": "docs/",
      "site": "site/",
    },

    rules: [
      { pattern: "swift/Sources/VoxEngine/*", instruction: "Keep instrumentation and model lifecycle explicit; do not hide warm-up cost in opaque helpers." },
      { pattern: "swift/Sources/VoxService/*", instruction: "Preserve multi-client semantics; clientId should remain available anywhere latency or session ownership matters." },
      { pattern: "packages/client/*", instruction: "SDK APIs should expose the runtime capabilities directly, including metrics and warm-up surfaces." },
      { pattern: "packages/cli/*", instruction: "CLI commands are also operator tools; prefer clear terminal output and measurable benchmarks." },
      { pattern: "site/*", instruction: "Maintain the clean, restrained Vox visual language. Avoid generic startup landing page patterns." },
    ],

    sections: ["start", "start-mac", "start-swift", "start-node", "start-browser", "start-agent", "overview", "quickstart", "apple-embed", "runtime", "models", "providers", "sdk", "web-integration", "observability", "architecture", "api", "agents", "skill"],
  },

  docs: {
    path: "./docs",
    output: "./",
    required: ["overview", "quickstart", "runtime", "providers", "sdk", "observability"],
  },

  install: {
    objective: "Clone Vox, build the runtime, start the companion daemon, and verify local speech on macOS.",
    doneWhen: {
      command: "node packages/cli/dist/index.js doctor",
      expectedOutput: "ready: true",
    },
    prerequisites: [
      "macOS 14+",
      "Bun",
      "Swift 6.2+",
      "Microphone permission if testing live transcription",
    ],
    steps: [
      { description: "Clone the repository", command: "git clone https://github.com/hudsonkit/vox.git && cd vox" },
      { description: "Install dependencies", command: "bun install" },
      { description: "Build the SDK, CLI, and daemon", command: "bun run build" },
      { description: "Run tests", command: "bun run test" },
      { description: "Start the companion daemon", command: "node packages/cli/dist/index.js daemon start" },
      { description: "Verify runtime health", command: "node packages/cli/dist/index.js doctor" },
    ],
  },
}
