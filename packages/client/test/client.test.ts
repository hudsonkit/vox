import { VoxClient } from "../src/client.ts";
import { STREAM_TIMEOUT_MS } from "../src/constants.ts";

describe("VoxClient", () => {
  it("forwards selected-account voice credentials only on that call", async () => {
    const client = new VoxClient({ clientId: "talkie" });
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    (client as any).transport = { call: async (method: string, params: Record<string, unknown>) => {
      calls.push({ method, params }); return { voices: [] };
    } };
    await client.listVoices("eleven_multilingual_v2", { ELEVENLABS_API_KEY: "selected-account-test-key" });
    await client.listVoices("eleven_multilingual_v2");
    expect(calls[0]).toEqual({ method: "synthesize.voices", params: { clientId: "talkie",
      modelId: "eleven_multilingual_v2", credentials: { ELEVENLABS_API_KEY: "selected-account-test-key" } } });
    expect(calls[1]?.params.credentials).toBeUndefined();
  });

  it("uses the streaming timeout budget for file transcription", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown>; timeoutMs: number }> = [];
    const client = new VoxClient({ clientId: "test-client" }) as unknown as {
      transport: {
        call: (
          method: string,
          params: Record<string, unknown>,
          timeoutMs: number,
        ) => Promise<Record<string, unknown>>;
      };
      transcribeFile: (path: string, modelId?: string) => Promise<{ text: string }>;
    };

    client.transport = {
      call: async (method, params, timeoutMs) => {
        calls.push({ method, params, timeoutMs });
        return {
          modelId: "parakeet:v3",
          text: "ok",
          elapsedMs: 12,
          words: [
            { word: "ok", start: 0.01, end: 0.2, confidence: 0.99 },
          ],
        };
      },
    };

    const result = await client.transcribeFile("/tmp/sample.wav");

    expect(result.text).toBe("ok");
    expect(result.words).toEqual([
      { word: "ok", start: 0.01, end: 0.2, confidence: 0.99 },
    ]);
    expect(calls).toEqual([
      {
        method: "transcribe.file",
        params: {
          clientId: "test-client",
          path: "/tmp/sample.wav",
        },
        timeoutMs: STREAM_TIMEOUT_MS,
      },
    ]);
  });

  it("parses the published speech model catalog", async () => {
    const client = new VoxClient({ clientId: "test-client" }) as unknown as {
      call: (method: string) => Promise<Record<string, unknown>>;
      listCatalog: () => Promise<{
        version: number;
        models: Array<{
          id: string;
          family: string;
          default: boolean;
          architectures?: string[];
          capabilities?: { onDevice: boolean; liveTranscription: boolean };
        }>;
      }>;
      refreshCatalog: () => Promise<{ version: number; models: Array<{ id: string }> }>;
    };

    client.call = async (method) => {
      expect(["models.catalog", "models.refreshCatalog"]).toContain(method);
      return {
        version: 1,
        updatedAt: "2026-08-29",
        models: [
          {
            id: "parakeet:v3",
            kind: "asr",
            family: "parakeet-tdt",
            name: "Parakeet TDT v3",
            status: "ready",
            default: true,
            architectures: ["arm64"],
            capabilities: {
              fileTranscription: true,
              liveTranscription: false,
              onDevice: true,
              wordTimestamps: true,
            },
          },
        ],
      };
    };

    const listed = await client.listCatalog();
    expect(listed.version).toBe(1);
    expect(listed.models[0]?.id).toBe("parakeet:v3");
    expect(listed.models[0]?.family).toBe("parakeet-tdt");
    expect(listed.models[0]?.default).toBe(true);
    expect(listed.models[0]?.architectures).toEqual(["arm64"]);
    expect(listed.models[0]?.capabilities).toEqual({
      fileTranscription: true,
      liveTranscription: false,
      onDevice: true,
      wordTimestamps: true,
    });

    const refreshed = await client.refreshCatalog();
    expect(refreshed.models[0]?.id).toBe("parakeet:v3");
  });

  it("parses live session status responses", async () => {
    const client = new VoxClient({ clientId: "test-client" }) as unknown as {
      call: (method: string, params?: Record<string, unknown>) => Promise<Record<string, unknown>>;
      getLiveSessionStatus: () => Promise<unknown>;
    };

    client.call = async (method) => {
      expect(method).toBe("transcribe.sessionStatus");
      return {
        session: {
          sessionId: "session-1",
          connectionId: "conn-1",
          clientId: "openscout-app",
          modelId: "parakeet:v3",
          startedAt: "2026-03-23T16:44:48Z",
          state: "recording",
        },
      };
    };

    expect(await client.getLiveSessionStatus()).toEqual({
      sessionId: "session-1",
      connectionId: "conn-1",
      clientId: "openscout-app",
      modelId: "parakeet:v3",
      startedAt: "2026-03-23T16:44:48Z",
      state: "recording",
    });
  });

  it("uses the explicit cloud annotation timeout budget and parses speaker output", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown>; timeoutMs: number }> = [];
    const client = new VoxClient({ clientId: "test-client" }) as unknown as {
      transport: {
        call: (
          method: string,
          params: Record<string, unknown>,
          timeoutMs: number,
        ) => Promise<Record<string, unknown>>;
      };
      annotateFile: (
        path: string,
        options?: Record<string, unknown>,
      ) => Promise<{ text?: string; speakers: Array<{ speakerId: string }> }>;
    };

    client.transport = {
      call: async (method, params, timeoutMs) => {
        calls.push({ method, params, timeoutMs });
        return {
          modelId: "speaker-diarization:v1",
          text: "hello world",
          elapsedMs: 34,
          words: [
            { word: "hello", start: 0.01, end: 0.2, confidence: 0.98, speakerId: "speaker-0" },
          ],
          speakers: [
            { speakerId: "speaker-0", start: 0, end: 0.4, confidence: 0.87 },
          ],
        };
      },
    };

    const result = await client.annotateFile("/tmp/sample.wav", {
      modelId: "speaker-diarization:v1",
      text: "hello world",
      words: [
        { word: "hello", start: 0.01, end: 0.2, confidence: 0.98 },
      ],
    });

    expect(result.text).toBe("hello world");
    expect(result.speakers).toEqual([
      { speakerId: "speaker-0", start: 0, end: 0.4, confidence: 0.87 },
    ]);
    expect(calls).toEqual([
      {
        method: "annotate.file",
        params: {
          clientId: "test-client",
          path: "/tmp/sample.wav",
          modelId: "speaker-diarization:v1",
          text: "hello world",
          words: [
            { word: "hello", start: 0.01, end: 0.2, confidence: 0.98 },
          ],
        },
        timeoutMs: 3_600_000,
      },
    ]);
  });

  it("cancels the active live session without requiring a session id", async () => {
    const calls: Array<{ method: string; params?: Record<string, unknown> }> = [];
    const client = new VoxClient({ clientId: "test-client" }) as unknown as {
      call: (method: string, params?: Record<string, unknown>) => Promise<Record<string, unknown>>;
      cancelLiveSession: (sessionId?: string) => Promise<unknown>;
    };

    client.call = async (method, params) => {
      calls.push({ method, params });
      return {
        cancelled: true,
        sessionId: "session-1",
      };
    };

    expect(await client.cancelLiveSession()).toEqual({
      cancelled: true,
      sessionId: "session-1",
    });
    expect(calls).toEqual([
      {
        method: "transcribe.cancelSession",
        params: undefined,
      },
    ]);
  });

  it("uses the streaming timeout budget for synthesis and decodes audio bytes", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown>; timeoutMs: number }> = [];
    const client = new VoxClient({ clientId: "test-client" }) as unknown as {
      transport: {
        call: (
          method: string,
          params: Record<string, unknown>,
          timeoutMs: number,
        ) => Promise<Record<string, unknown>>;
      };
      synthesize: (text: string, options?: Record<string, unknown>) => Promise<{ audioBytes: number; voiceId: string }>;
    };

    client.transport = {
      call: async (method, params, timeoutMs) => {
        calls.push({ method, params, timeoutMs });
        return {
          modelId: "avspeech:system",
          voiceId: "com.apple.speech.synthesis.voice.Alex",
          format: "wav",
          contentType: "audio/wav",
          audioBase64: Buffer.from([0x52, 0x49, 0x46, 0x46]).toString("base64"),
          audioBytes: 4,
          elapsedMs: 18,
          metrics: {
            traceId: "trace-1",
            characterCount: 11,
            audioDurationMs: 500,
            outputBytes: 4,
            wasPreloaded: true,
            modelCheckMs: 1,
            modelLoadMs: 0,
            voiceResolveMs: 1,
            synthesisMs: 12,
            totalMs: 18,
          },
          speechTiming: {
            source: "asr",
            modelId: "parakeet:v3",
            elapsedMs: 120,
            words: [
              {
                word: "hello",
                startMs: 0,
                endMs: 180,
                confidence: 0.98,
                sourceTextStart: 0,
                sourceTextEnd: 5,
              },
            ],
            cues: [
              {
                id: "intro",
                startMs: 0,
                endMs: 500,
                confidence: 0.9,
                source: "asr",
              },
            ],
          },
        };
      },
    };

    const result = await client.synthesize("hello world", {
      speechTiming: {
        enabled: true,
        modelId: "parakeet:v3",
        cues: [{ id: "intro", textStart: 0, textEnd: 11 }],
      },
    });

    expect(result.audioBytes).toBe(4);
    expect(result.voiceId).toBe("com.apple.speech.synthesis.voice.Alex");
    expect([...result.audio]).toEqual([0x52, 0x49, 0x46, 0x46]);
    expect(result.speechTiming?.source).toBe("asr");
    expect(result.speechTiming?.words[0]?.sourceTextEnd).toBe(5);
    expect(result.speechTiming?.cues[0]?.id).toBe("intro");
    expect(calls).toEqual([
      {
        method: "synthesize.generate",
        params: {
          clientId: "test-client",
          text: "hello world",
          format: "wav",
          speed: undefined,
          instructions: undefined,
          speechTiming: {
            enabled: true,
            modelId: "parakeet:v3",
            cues: [{ id: "intro", textStart: 0, textEnd: 11 }],
          },
        },
        timeoutMs: STREAM_TIMEOUT_MS,
      },
    ]);
  });

  it("forwards per-request NVIDIA, Groq, and Gemini credentials on synthesize", async () => {
    const calls: Array<{ method: string; params: Record<string, unknown> }> = [];
    const client = new VoxClient({ clientId: "test-client" }) as unknown as {
      transport: {
        call: (
          method: string,
          params: Record<string, unknown>,
          timeoutMs?: number,
        ) => Promise<Record<string, unknown>>;
      };
      synthesize: (text: string, options?: Record<string, unknown>) => Promise<{ audioBytes: number }>;
    };

    client.transport = {
      call: async (method, params) => {
        calls.push({ method, params });
        return {
          modelId: "magpie-tts-multilingual",
          voiceId: "Magpie-Multilingual.EN-US.Aria",
          format: "wav",
          contentType: "audio/wav",
          audioBase64: Buffer.from([0x52, 0x49, 0x46, 0x46]).toString("base64"),
          audioBytes: 4,
          elapsedMs: 12,
        };
      },
    };

    await client.synthesize("hello from lent keys", {
      modelId: "magpie-tts-multilingual",
      credentials: {
        NV_API_KEY: "nv-lent",
        NVIDIA_API_KEY: "nvidia-alias",
        GROQ_API_KEY: "groq-lent",
        GEMINI_API_KEY: "gemini-lent",
        GOOGLE_API_KEY: "google-lent",
      },
    });

    expect(calls).toEqual([
      {
        method: "synthesize.generate",
        params: {
          clientId: "test-client",
          text: "hello from lent keys",
          format: "wav",
          speed: undefined,
          instructions: undefined,
          modelId: "magpie-tts-multilingual",
          credentials: {
            NV_API_KEY: "nv-lent",
            NVIDIA_API_KEY: "nvidia-alias",
            GROQ_API_KEY: "groq-lent",
            GEMINI_API_KEY: "gemini-lent",
            GOOGLE_API_KEY: "google-lent",
          },
        },
      },
    ]);
  });

  it("lists synthesis voices through the daemon route", async () => {
    const client = new VoxClient({ clientId: "test-client" }) as unknown as {
      call: (method: string, params?: Record<string, unknown>) => Promise<Record<string, unknown>>;
      listVoices: (modelId?: string) => Promise<unknown>;
    };

    client.call = async (method, params) => {
      expect(method).toBe("synthesize.voices");
      expect(params).toEqual({ modelId: "avspeech:system" });
      return {
        voices: [
          {
            id: "com.apple.speech.synthesis.voice.Alex",
            name: "Alex",
            modelId: "avspeech:system",
            backend: "avspeech",
            available: true,
            default: true,
          },
        ],
      };
    };

    expect(await client.listVoices("avspeech:system")).toEqual([
      {
        id: "com.apple.speech.synthesis.voice.Alex",
        name: "Alex",
        modelId: "avspeech:system",
        backend: "avspeech",
        available: true,
        default: true,
      },
    ]);
  });
  it("parses history list responses", async () => {
    const calls: Array<{ method: string; params?: Record<string, unknown> }> = [];
    const client = new VoxClient({ clientId: "test-client" }) as unknown as {
      transport: {
        call: (method: string, params?: Record<string, unknown>) => Promise<Record<string, unknown>>;
      };
      listHistory: (options?: Record<string, unknown>) => Promise<{ records: Array<{ id: string; text?: string; words: unknown[] }> }>;
    };

    client.transport = {
      call: async (method, params) => {
        calls.push({ method, params });
        return {
          records: [
            {
              schemaVersion: 1,
              id: "hist-1",
              kind: "transcription",
              source: "file",
              route: "transcribe.file",
              clientId: "menu-bar",
              modelId: "parakeet:v3",
              text: "hello history",
              textLength: 13,
              elapsedMs: 42,
              outcome: "ok",
              completedAt: "2026-06-02T12:00:00Z",
              words: [{ word: "hello", start: 0, end: 0.2, confidence: 0.99 }],
              metrics: { traceId: "trace", audioDurationMs: 500, inferenceMs: 40, totalMs: 42 },
            },
          ],
        };
      },
    };

    const result = await client.listHistory({ kind: "transcription", limit: 10 });

    expect(result.records[0]?.id).toBe("hist-1");
    expect(result.records[0]?.text).toBe("hello history");
    expect(result.records[0]?.words).toEqual([{ word: "hello", start: 0, end: 0.2, confidence: 0.99 }]);
    expect(calls).toEqual([{ method: "history.list", params: { kind: "transcription", limit: 10 } }]);
  });

  it("parses stop live session results", async () => {
    const calls: Array<{ method: string; params?: Record<string, unknown> }> = [];
    const client = new VoxClient({ clientId: "test-client" }) as unknown as {
      call: (method: string, params?: Record<string, unknown>) => Promise<Record<string, unknown>>;
      stopLiveSession: (sessionId?: string) => Promise<{ stopped: boolean; historyId?: string; result?: { text: string; historyId?: string } }>;
    };

    client.call = async (method, params) => {
      calls.push({ method, params });
      return {
        stopped: true,
        sessionId: "session-1",
        historyId: "hist-1",
        result: {
          sessionId: "session-1",
          text: "final text",
          elapsedMs: 25,
          historyId: "hist-1",
          words: [],
        },
      };
    };

    const result = await client.stopLiveSession("session-1");

    expect(result.stopped).toBe(true);
    expect(result.historyId).toBe("hist-1");
    expect(result.result?.text).toBe("final text");
    expect(result.result?.historyId).toBe("hist-1");
    expect(calls).toEqual([{ method: "transcribe.stopSession", params: { sessionId: "session-1" } }]);
  });

});
