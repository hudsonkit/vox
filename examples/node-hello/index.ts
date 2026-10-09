import { writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { VoxClient } from "@voxd/sdk";

// Usage: bun run index.ts [audio-file]
// Needs Vox on your Mac running: open Vox.app, or `vox daemon start`.

const file = process.argv[2];
const vox = new VoxClient({ clientId: "vox-node-hello" });
await vox.connect();

try {
  if (file) {
    // Preload so the first transcription does not pay the model load.
    await vox.preloadModel("parakeet:v3");
    const result = await vox.transcribeFile(resolve(file), "parakeet:v3");
    console.log(result.text);
    console.log(`[${result.modelId} · ${Math.round(result.elapsedMs)} ms]`);
  }

  const speech = await vox.synthesize("Hello from Vox.", {
    modelId: "avspeech:system",
    format: "wav",
  });
  await writeFile("hello.wav", speech.audio);
  console.log(`wrote hello.wav [${speech.modelId} · ${speech.voiceId} · ${Math.round(speech.elapsedMs)} ms]`);
} finally {
  vox.disconnect();
}
