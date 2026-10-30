import { describe, expect, it } from "bun:test";
import { VoxClient } from "../src/client.ts";

describe("native PCM streaming", () => {
  it("preserves client/session identity, sequence and little-endian PCM", async () => {
    const client = new VoxClient({ clientId: "talkie" });
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    (client as any).transport = { call: async (method: string, params: Record<string, unknown>) => {
      calls.push({ method, params });
      if (method.endsWith("start")) return { sessionId: "a", nextSequence: 0 };
      if (method.endsWith("append")) return { sessionId: "a", nextSequence: 1, updates: [] };
      if (method.endsWith("finish")) return { result: { text: "hello", words: [], endOfUtterance: false } };
      return {};
    } };
    await client.startPCMStream();
    await client.appendPCMStream("a", 0, new Float32Array([1, -0.5]));
    expect((await client.finishPCMStream("a")).text).toBe("hello");
    await client.cancelPCMStream("a");
    expect(calls[0]).toEqual({ method: "transcribe.stream.start", params: { clientId: "talkie", modelId: "nemotron:unified-560ms" } });
    expect(calls[1]).toEqual({ method: "transcribe.stream.append", params: { clientId: "talkie", sessionId: "a", sequence: 0, audioBase64: "AACAPwAAAL8=" } });
    expect(calls[3]).toEqual({ method: "transcribe.stream.cancel", params: { clientId: "talkie", sessionId: "a" } });
  });
  it("rejects empty, overlong and nonfinite audio before transport", async () => {
    const client = new VoxClient();
    for (const samples of [new Float32Array(), new Float32Array(16001), new Float32Array([NaN]), new Float32Array([Infinity])]) {
      await expect(client.appendPCMStream("a", 0, samples)).rejects.toThrow("finite");
    }
  });
});
