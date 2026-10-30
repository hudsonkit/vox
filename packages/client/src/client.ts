import { RuntimeDiscovery } from "./discovery.ts";
import { DEFAULT_HOST, STREAM_TIMEOUT_MS } from "./constants.ts";
import { parseAnnotationMetrics, parseSynthesisMetrics, parseTranscriptionMetrics } from "./metrics.ts";
import { WebSocketTransport } from "./transport.ts";
import { VoxLiveSession } from "./live.ts";
import { parseAttributedWordTimings, parseSpeakerSegments } from "./annotation.ts";
import { parseWordTimings } from "./words.ts";
import type {
  DoctorReport,
  NativeStreamingStatus,
  PCMStreamingSession,
  StreamingASRUpdate,
  FileAnnotationResult,
  FileTranscriptionResult,
  HistoryListOptions,
  HistoryListResult,
  LiveSessionStatus,
  ModelInfo,
  ModelProgress,
  SpeechModelCatalog,
  SynthesisOptions,
  SynthesisResult,
  SessionFinalEvent,
  SpeechHistoryRecord,
  SpeechTiming,
  StopLiveSessionResult,
  VoiceInfo,
  WarmupStatus,
  VoxClientOptions,
} from "./types.ts";

export class VoxClient {
  private readonly discovery = new RuntimeDiscovery();
  private readonly transport = new WebSocketTransport();
  private readonly clientId: string;
  private resolvedPort: number | null = null;

  constructor(private readonly options: VoxClientOptions = {}) {
    this.clientId = options.clientId ?? "vox-client";
  }

  get connected(): boolean {
    return this.transport.isConnected;
  }

  async connect(): Promise<void> {
    this.resolvedPort = this.discovery.resolvePort(this.options.port);
    const host = this.options.host ?? DEFAULT_HOST;
    await this.transport.connect(this.resolvedPort, host);
  }

  disconnect(): void {
    this.transport.disconnect();
  }

  async call(
    method: string,
    params?: Record<string, unknown>,
  ): Promise<Record<string, unknown>> {
    return this.transport.call(method, { clientId: this.clientId, ...params });
  }

  async callStreaming(
    method: string,
    params: Record<string, unknown> | undefined,
    onProgress: (event: string, data: Record<string, unknown>) => void,
  ): Promise<Record<string, unknown>> {
    return this.transport.callStreaming(
      method,
      { clientId: this.clientId, ...params },
      onProgress,
    );
  }

  /** Capture belongs to the app. Explicitly preload a live model before starting. */
  async startPCMStream(modelId = "nemotron:streaming-560ms"): Promise<PCMStreamingSession> {
    return await this.call("transcribe.stream.start", { modelId }) as unknown as PCMStreamingSession;
  }

  /** Await each acknowledgement before sending the next packet. Never retry an uncertain packet. */
  async appendPCMStream(sessionId: string, sequence: number, samples: Float32Array): Promise<{ sessionId: string; nextSequence: number; updates: StreamingASRUpdate[] }> {
    if (samples.length === 0 || samples.length > 16000 || !samples.every(Number.isFinite)) {
      throw new Error("Expected 1–16000 finite mono 16 kHz float32 samples");
    }
    const bytes = Buffer.alloc(samples.length * 4);
    for (let i = 0; i < samples.length; i++) bytes.writeFloatLE(samples[i]!, i * 4);
    return await this.call("transcribe.stream.append", { sessionId, sequence, audioBase64: bytes.toString("base64") }) as unknown as { sessionId: string; nextSequence: number; updates: StreamingASRUpdate[] };
  }

  async finishPCMStream(sessionId: string): Promise<StreamingASRUpdate> {
    const result = await this.call("transcribe.stream.finish", { sessionId });
    return result.result as unknown as StreamingASRUpdate;
  }

  async cancelPCMStream(sessionId: string): Promise<void> {
    await this.call("transcribe.stream.cancel", { sessionId });
  }

  async nativeStreamingStatus(): Promise<NativeStreamingStatus> {
    return await this.call("transcribe.stream.status") as unknown as NativeStreamingStatus;
  }

  async health(): Promise<Record<string, unknown>> {
    return this.call("health");
  }

  async doctor(): Promise<DoctorReport> {
    const result = await this.call("doctor.run");
    return {
      ready: Boolean(result.ready),
      checks: (result.checks as DoctorReport["checks"]) ?? [],
    };
  }

  async listModels(): Promise<ModelInfo[]> {
    const result = await this.call("models.list");
    return (result.models as ModelInfo[]) ?? [];
  }

  async listCatalog(): Promise<SpeechModelCatalog> {
    const result = await this.call("models.catalog");
    return parseCatalog(result);
  }

  async refreshCatalog(): Promise<SpeechModelCatalog> {
    const result = await this.call("models.refreshCatalog");
    return parseCatalog(result);
  }

  async listVoices(modelId?: string): Promise<VoiceInfo[]> {
    const result = await this.call("synthesize.voices", modelId ? { modelId } : undefined);
    return (result.voices as VoiceInfo[]) ?? [];
  }

  async installModel(
    modelId?: string,
    onProgress?: (event: ModelProgress) => void,
  ): Promise<ModelInfo> {
    const params = modelId ? { modelId } : undefined;
    const result = await this.callStreaming("models.install", params, (event, data) => {
      if (event === "models.progress" && onProgress) {
        onProgress({
          modelId: String(data.modelId ?? modelId ?? ""),
          progress: Number(data.progress ?? 0),
          status: String(data.status ?? ""),
        });
      }
    });
    return result.model as ModelInfo;
  }

  async preloadModel(
    modelId?: string,
    onProgress?: (event: ModelProgress) => void,
  ): Promise<ModelInfo> {
    const params = modelId ? { modelId } : undefined;
    const result = await this.callStreaming("models.preload", params, (event, data) => {
      if (event === "models.progress" && onProgress) {
        onProgress({
          modelId: String(data.modelId ?? modelId ?? ""),
          progress: Number(data.progress ?? 0),
          status: String(data.status ?? ""),
        });
      }
    });
    return result.model as ModelInfo;
  }

  async getWarmupStatus(modelId?: string): Promise<WarmupStatus> {
    const result = await this.call("warmup.status", modelId ? { modelId } : undefined);
    return result.warmup as WarmupStatus;
  }

  async startWarmup(modelId?: string): Promise<WarmupStatus> {
    const result = await this.call("warmup.start", modelId ? { modelId } : undefined);
    return result.warmup as WarmupStatus;
  }

  async scheduleWarmup(modelId?: string, delayMs = 0): Promise<WarmupStatus> {
    const params: Record<string, unknown> = { delayMs };
    if (modelId) {
      params.modelId = modelId;
    }
    const result = await this.call("warmup.schedule", params);
    return result.warmup as WarmupStatus;
  }

  async transcribeFile(path: string, modelId?: string): Promise<FileTranscriptionResult> {
    const params: Record<string, unknown> = { clientId: this.clientId, path };
    if (modelId) {
      params.modelId = modelId;
    }
    const result = await this.transport.call(
      "transcribe.file",
      params,
      STREAM_TIMEOUT_MS,
    );
    return {
      modelId: String(result.modelId ?? modelId ?? ""),
      text: String(result.text ?? ""),
      elapsedMs: Number(result.elapsedMs ?? 0),
      metrics: parseTranscriptionMetrics(result.metrics, Number(result.elapsedMs ?? 0)),
      words: parseWordTimings(result.words),
      historyId: optionalString(result.historyId) ?? undefined,
    };
  }

  async annotateFile(
    path: string,
    options: {
      modelId?: string;
      text?: string;
      words?: Array<{
        word: string;
        start: number;
        end: number;
        confidence: number;
      }>;
    } = {},
  ): Promise<FileAnnotationResult> {
    const modelId = options.modelId ?? "speaker-diarization:v1";
    const result = await this.transport.call(
      "annotate.file",
      {
        clientId: this.clientId,
        path,
        modelId,
        text: options.text,
        words: options.words,
      },
      STREAM_TIMEOUT_MS,
    );

    return {
      modelId: String(result.modelId ?? modelId),
      text: typeof result.text === "string" ? result.text : undefined,
      elapsedMs: Number(result.elapsedMs ?? 0),
      metrics: parseAnnotationMetrics(result.metrics, Number(result.elapsedMs ?? 0)),
      words: parseAttributedWordTimings(result.words),
      speakers: parseSpeakerSegments(result.speakers),
    };
  }

  async synthesize(text: string, options: SynthesisOptions = {}): Promise<SynthesisResult> {
    const params: Record<string, unknown> = {
      clientId: this.clientId,
      text,
      format: options.format ?? "wav",
      speed: options.speed,
      instructions: options.instructions,
    };
    if (options.modelId) {
      params.modelId = options.modelId;
    }
    if (options.voiceId) {
      params.voiceId = options.voiceId;
    }
    if (options.credentials) {
      params.credentials = options.credentials;
    }
    if (options.speechTiming !== undefined) {
      params.speechTiming = options.speechTiming;
    }

    const result = await this.transport.call(
      "synthesize.generate",
      params,
      STREAM_TIMEOUT_MS,
    );

    const audioBase64 = String(result.audioBase64 ?? "");
    const audio = Buffer.from(audioBase64, "base64");
    return {
      modelId: String(result.modelId ?? options.modelId ?? ""),
      voiceId: String(result.voiceId ?? options.voiceId ?? ""),
      format: String(result.format ?? options.format ?? "wav"),
      contentType: String(result.contentType ?? "audio/wav"),
      audio: new Uint8Array(audio),
      audioBytes: Number(result.audioBytes ?? audio.length),
      elapsedMs: Number(result.elapsedMs ?? 0),
      metrics: parseSynthesisMetrics(result.metrics, Number(result.elapsedMs ?? 0)),
      speechTiming: parseSpeechTiming(result.speechTiming),
    };
  }

  async listHistory(options: HistoryListOptions = {}): Promise<HistoryListResult> {
    const result = await this.transport.call("history.list", compactRecord(options));
    return {
      records: Array.isArray(result.records) ? result.records.map(parseHistoryRecord) : [],
      nextCursor: optionalString(result.nextCursor) ?? undefined,
    };
  }

  async getHistoryRecord(id: string): Promise<SpeechHistoryRecord | null> {
    const result = await this.transport.call("history.get", { id });
    const raw = result.record;
    if (!raw || typeof raw !== "object") {
      return null;
    }
    return parseHistoryRecord(raw);
  }

  async deleteHistoryRecord(id: string): Promise<boolean> {
    const result = await this.transport.call("history.delete", { id });
    return Boolean(result.deleted);
  }

  async getLiveSessionStatus(): Promise<LiveSessionStatus | null> {
    const result = await this.call("transcribe.sessionStatus");
    const raw = result.session;
    if (!raw || typeof raw !== "object") {
      return null;
    }

    const session = raw as Record<string, unknown>;
    return {
      sessionId: String(session.sessionId ?? ""),
      connectionId: String(session.connectionId ?? ""),
      clientId: String(session.clientId ?? ""),
      modelId: String(session.modelId ?? ""),
      startedAt: String(session.startedAt ?? ""),
      state: String(session.state ?? "error") as LiveSessionStatus["state"],
    };
  }

  async stopLiveSession(sessionId?: string): Promise<StopLiveSessionResult> {
    const result = await this.call("transcribe.stopSession", sessionId ? { sessionId } : undefined);
    const rawResult = result.result;
    return {
      stopped: Boolean(result.stopped),
      sessionId: String(result.sessionId ?? sessionId ?? ""),
      historyId: optionalString(result.historyId) ?? undefined,
      result: rawResult && typeof rawResult === "object" ? parseSessionFinalEvent(rawResult) : undefined,
    };
  }

  async cancelLiveSession(sessionId?: string): Promise<{ cancelled: boolean; sessionId: string }> {
    const result = await this.call("transcribe.cancelSession", sessionId ? { sessionId } : undefined);
    return {
      cancelled: Boolean(result.cancelled),
      sessionId: String(result.sessionId ?? sessionId ?? ""),
    };
  }

  createLiveSession(): VoxLiveSession {
    return new VoxLiveSession(this);
  }
}

function parseSessionFinalEvent(value: unknown): SessionFinalEvent {
  const raw = isRecord(value) ? value : {};
  return {
    sessionId: String(raw.sessionId ?? ""),
    text: String(raw.text ?? ""),
    elapsedMs: Number(raw.elapsedMs ?? 0),
    metrics: parseTranscriptionMetrics(raw.metrics, Number(raw.elapsedMs ?? 0)),
    words: parseWordTimings(raw.words),
    historyId: optionalString(raw.historyId) ?? undefined,
  };
}

function parseHistoryRecord(value: unknown): SpeechHistoryRecord {
  const raw = isRecord(value) ? value : {};
  const elapsedMs = Number(raw.elapsedMs ?? 0);
  const kind = String(raw.kind ?? "transcription") as SpeechHistoryRecord["kind"];
  return {
    schemaVersion: Number(raw.schemaVersion ?? 1),
    id: String(raw.id ?? ""),
    kind,
    source: (optionalString(raw.source) as SpeechHistoryRecord["source"]) ?? undefined,
    route: String(raw.route ?? ""),
    sessionId: optionalString(raw.sessionId) ?? undefined,
    requestId: optionalString(raw.requestId) ?? undefined,
    clientId: String(raw.clientId ?? ""),
    originAppId: optionalString(raw.originAppId) ?? undefined,
    modelId: String(raw.modelId ?? ""),
    voiceId: optionalString(raw.voiceId) ?? undefined,
    text: optionalString(raw.text) ?? undefined,
    textLength: Number(raw.textLength ?? 0),
    words: parseWordTimings(raw.words),
    elapsedMs,
    metrics: kind === "synthesis"
      ? parseSynthesisMetrics(raw.metrics, elapsedMs)
      : parseTranscriptionMetrics(raw.metrics, elapsedMs),
    outcome: String(raw.outcome ?? ""),
    error: optionalString(raw.error) ?? undefined,
    startedAt: optionalString(raw.startedAt) ?? undefined,
    completedAt: String(raw.completedAt ?? ""),
    metadata: isRecord(raw.metadata) ? Object.fromEntries(
      Object.entries(raw.metadata).map(([key, value]) => [key, String(value)]),
    ) : undefined,
  };
}

function compactRecord(value: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(
    Object.entries(value).filter(([, entry]) => entry !== undefined && entry !== null && entry !== ""),
  );
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") {
    return null;
  }
  return value.length > 0 ? value : null;
}

function parseSpeechTiming(value: unknown): SpeechTiming | undefined {
  if (!isRecord(value)) {
    return undefined;
  }

  return {
    source: String(value.source ?? ""),
    modelId: String(value.modelId ?? ""),
    elapsedMs: Number(value.elapsedMs ?? 0),
    words: parseSpeechTimingWords(value.words),
    cues: parseSpeechTimingCues(value.cues),
  };
}

function parseSpeechTimingWords(value: unknown): SpeechTiming["words"] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((entry) => {
    const fields = isRecord(entry) ? entry : {};
    return {
      word: String(fields.word ?? ""),
      startMs: Number(fields.startMs ?? 0),
      endMs: Number(fields.endMs ?? 0),
      confidence: Number(fields.confidence ?? 0),
      sourceTextStart: optionalNumber(fields.sourceTextStart),
      sourceTextEnd: optionalNumber(fields.sourceTextEnd),
    };
  }).filter((word) => word.word.length > 0);
}

function parseSpeechTimingCues(value: unknown): SpeechTiming["cues"] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.map((entry) => {
    const fields = isRecord(entry) ? entry : {};
    return {
      id: String(fields.id ?? ""),
      startMs: Number(fields.startMs ?? 0),
      endMs: Number(fields.endMs ?? 0),
      confidence: Number(fields.confidence ?? 0),
      source: String(fields.source ?? ""),
    };
  }).filter((cue) => cue.id.length > 0);
}

function parseCatalog(result: Record<string, unknown>): SpeechModelCatalog {
  const models = Array.isArray(result.models) ? result.models : [];
  const plugins = Array.isArray(result.plugins) ? result.plugins : [];
  return {
    version: Number(result.version ?? 1),
    updatedAt: String(result.updatedAt ?? ""),
    models: models.map((entry) => {
      const fields = isRecord(entry) ? entry : {};
      const source = isRecord(fields.source) ? fields.source : null;
      const capabilities = isRecord(fields.capabilities) ? fields.capabilities : null;
      return {
        id: String(fields.id ?? ""),
        kind: String(fields.kind ?? "asr"),
        family: String(fields.family ?? ""),
        name: String(fields.name ?? fields.id ?? ""),
        vendor: fields.vendor ? String(fields.vendor) : undefined,
        runtime: fields.runtime ? String(fields.runtime) : undefined,
        status: String(fields.status ?? "ready"),
        default: Boolean(fields.default),
        languages: fields.languages ? String(fields.languages) : undefined,
        notes: fields.notes ? String(fields.notes) : undefined,
        requires: Array.isArray(fields.requires)
          ? fields.requires.map((value) => String(value))
          : undefined,
        platforms: Array.isArray(fields.platforms)
          ? fields.platforms.map((value) => String(value))
          : undefined,
        architectures: Array.isArray(fields.architectures)
          ? fields.architectures.map((value) => String(value))
          : undefined,
        capabilities: capabilities
          ? {
              fileTranscription: Boolean(capabilities.fileTranscription),
              liveTranscription: Boolean(capabilities.liveTranscription),
              onDevice: Boolean(capabilities.onDevice),
              wordTimestamps: Boolean(capabilities.wordTimestamps),
            }
          : undefined,
        plugin: fields.plugin ? String(fields.plugin) : undefined,
        source: source
          ? {
              type: String(source.type ?? ""),
              repo: source.repo ? String(source.repo) : undefined,
            }
          : undefined,
      };
    }),
    plugins: plugins.map((entry) => {
      const fields = isRecord(entry) ? entry : {};
      const install = isRecord(fields.install) ? fields.install : null;
      return {
        id: String(fields.id ?? ""),
        kind: String(fields.kind ?? "asr"),
        name: String(fields.name ?? fields.id ?? ""),
        status: String(fields.status ?? "ready"),
        command: Array.isArray(fields.command) ? fields.command.map((value) => String(value)) : undefined,
        notes: fields.notes ? String(fields.notes) : undefined,
        install: install
          ? {
              kind: String(install.kind ?? ""),
              id: install.id ? String(install.id) : undefined,
              package: install.package ? String(install.package) : undefined,
            }
          : undefined,
      };
    }),
  };
}

function optionalNumber(value: unknown): number | null {
  if (value === null || value === undefined) {
    return null;
  }
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
