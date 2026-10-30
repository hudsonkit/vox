export interface RuntimeInfo {
  version: string;
  serviceName: string;
  port: number;
  pid: number;
  startedAt: string;
}

export interface RpcRequest {
  id: string;
  method: string;
  params?: Record<string, unknown>;
}

export interface RpcResponse {
  id?: string;
  result?: Record<string, unknown>;
  error?: string;
}

export interface RpcEvent {
  id?: string;
  event: string;
  data?: Record<string, unknown>;
}

export type WireMessage = RpcResponse | RpcEvent;

export interface VoxClientOptions {
  clientId?: string;
  port?: number;
  host?: string;
}

export interface DoctorCheck {
  name: string;
  status: "ok" | "warning" | "error";
  detail: string;
  remediation?: {
    action: string;
    label: string;
    detail: string;
  };
}

export interface DoctorReport {
  ready: boolean;
  checks: DoctorCheck[];
}

export interface ModelInfo {
  computePlacement?: CoreMLPlacement | null;
  id: string;
  name: string;
  backend: string;
  installed: boolean;
  preloaded: boolean;
  available: boolean;
}

export interface SpeechModelCatalogEntry {
  id: string;
  kind: string;
  family: string;
  name: string;
  vendor?: string;
  runtime?: string;
  status: string;
  default: boolean;
  languages?: string;
  notes?: string;
  requires?: string[];
  platforms?: string[];
  architectures?: string[];
  capabilities?: {
    fileTranscription: boolean;
    liveTranscription: boolean;
    onDevice: boolean;
    wordTimestamps: boolean;
  };
  plugin?: string;
  source?: {
    type: string;
    repo?: string;
  revision?: string;
  };
}

export interface SpeechPluginCatalogEntry {
  id: string;
  kind: string;
  name: string;
  status: string;
  command?: string[];
  notes?: string;
  install?: {
    kind: string;
    id?: string;
    package?: string;
  };
}

export interface SpeechModelCatalog {
  version: number;
  updatedAt: string;
  models: SpeechModelCatalogEntry[];
  plugins: SpeechPluginCatalogEntry[];
}

export interface VoiceInfo {
  id: string;
  name: string;
  language?: string | null;
  backend: string;
  modelId: string;
  available: boolean;
  default: boolean;
}

export interface ModelProgress {
  modelId: string;
  progress: number;
  status: string;
}

export interface WarmupStatus {
  modelId: string;
  state: "idle" | "scheduled" | "warming" | "ready" | "failed";
  requestedBy?: string | null;
  scheduledFor?: string | null;
  startedAt?: string | null;
  completedAt?: string | null;
  lastError?: string | null;
}

export interface WordTiming {
  word: string;
  start: number;   // seconds
  end: number;      // seconds
  confidence: number;
}

export interface SpeakerSegment {
  speakerId: string;
  start: number;
  end: number;
  confidence?: number | null;
}

export interface AttributedWordTiming {
  word: string;
  start: number;
  end: number;
  confidence: number;
  speakerId?: string | null;
}

export interface FileTranscriptionResult {
  modelId: string;
  text: string;
  elapsedMs: number;
  metrics?: TranscriptionMetrics;
  words: WordTiming[];
  historyId?: string;
}

export interface AnnotationMetrics {
  traceId: string;
  audioDurationMs: number;
  inputBytes: number;
  wasPreloaded: boolean;
  fileCheckMs: number;
  modelCheckMs: number;
  modelLoadMs: number;
  audioLoadMs: number;
  audioPrepareMs: number;
  diarizationMs: number;
  totalMs: number;
  realtimeFactor: number;
}

export interface FileAnnotationResult {
  modelId: string;
  text?: string;
  elapsedMs: number;
  metrics?: AnnotationMetrics;
  words: AttributedWordTiming[];
  speakers: SpeakerSegment[];
}

export interface TranscriptionMetrics {
  traceId: string;
  audioDurationMs: number;
  inputBytes: number;
  wasPreloaded: boolean;
  fileCheckMs: number;
  modelCheckMs: number;
  modelLoadMs: number;
  audioLoadMs: number;
  audioPrepareMs: number;
  inferenceMs: number;
  totalMs: number;
  realtimeFactor: number;
}

export interface SynthesisOptions {
  modelId?: string;
  voiceId?: string;
  format?: string;
  speed?: number;
  instructions?: string;
  speechTiming?: boolean | SpeechTimingRequest;
  credentials?: {
    OPENAI_API_KEY?: string;
    openaiApiKey?: string;
    openai_api_key?: string;
    NV_API_KEY?: string;
    NVIDIA_API_KEY?: string;
    nvApiKey?: string;
    nvidiaApiKey?: string;
    nv_api_key?: string;
    nvidia_api_key?: string;
    GROQ_API_KEY?: string;
    groqApiKey?: string;
    groq_api_key?: string;
    GEMINI_API_KEY?: string;
    GOOGLE_API_KEY?: string;
    GOOGLE_GENAI_API_KEY?: string;
    geminiApiKey?: string;
    googleApiKey?: string;
    googleGenaiApiKey?: string;
    gemini_api_key?: string;
    google_api_key?: string;
    google_genai_api_key?: string;
  };
}

export interface SpeechTimingCueRequest {
  id: string;
  text?: string;
  textStart?: number;
  textEnd?: number;
}

export interface SpeechTimingRequest {
  enabled?: boolean;
  modelId?: string;
  cues?: SpeechTimingCueRequest[];
}

export interface SpeechTimingWord {
  word: string;
  startMs: number;
  endMs: number;
  confidence: number;
  sourceTextStart?: number | null;
  sourceTextEnd?: number | null;
}

export interface SpeechTimingCue {
  id: string;
  startMs: number;
  endMs: number;
  confidence: number;
  source: "asr" | "native" | "estimated" | string;
}

export interface SpeechTiming {
  source: "asr" | "native" | "estimated" | string;
  modelId: string;
  elapsedMs: number;
  words: SpeechTimingWord[];
  cues: SpeechTimingCue[];
}

export interface SynthesisMetrics {
  traceId: string;
  characterCount: number;
  audioDurationMs: number;
  outputBytes: number;
  wasPreloaded: boolean;
  modelCheckMs: number;
  modelLoadMs: number;
  voiceResolveMs: number;
  synthesisMs: number;
  inferenceMs: number;
  totalMs: number;
  realtimeFactor: number;
}

export interface SynthesisResult {
  modelId: string;
  voiceId: string;
  format: string;
  contentType: string;
  audio: Uint8Array;
  audioBytes: number;
  elapsedMs: number;
  metrics?: SynthesisMetrics;
  speechTiming?: SpeechTiming;
}

export type SessionState =
  | "starting"
  | "recording"
  | "processing"
  | "done"
  | "cancelled"
  | "error";

export interface SessionStateEvent {
  sessionId: string;
  state: SessionState;
  previous?: SessionState | null;
}

export interface LiveSessionStatus {
  sessionId: string;
  connectionId: string;
  clientId: string;
  modelId: string;
  startedAt: string;
  state: SessionState;
}

export interface SessionFinalEvent {
  sessionId: string;
  text: string;
  elapsedMs: number;
  metrics?: TranscriptionMetrics;
  words: WordTiming[];
  historyId?: string;
}

export interface StopLiveSessionResult {
  stopped: boolean;
  sessionId: string;
  historyId?: string;
  result?: SessionFinalEvent;
}

export type SpeechHistoryKind = "transcription" | "synthesis";
export type SpeechHistorySource = "file" | "live";

export interface SpeechHistoryRecord {
  schemaVersion: number;
  id: string;
  kind: SpeechHistoryKind;
  source?: SpeechHistorySource;
  route: string;
  sessionId?: string;
  requestId?: string;
  clientId: string;
  originAppId?: string;
  modelId: string;
  voiceId?: string;
  text?: string;
  textLength: number;
  words: WordTiming[];
  elapsedMs: number;
  metrics?: TranscriptionMetrics | SynthesisMetrics;
  outcome: string;
  error?: string;
  startedAt?: string;
  completedAt: string;
  metadata?: Record<string, string>;
}

export interface HistoryListOptions {
  kind?: SpeechHistoryKind;
  source?: SpeechHistorySource;
  clientId?: string;
  modelId?: string;
  sessionId?: string;
  outcome?: string;
  limit?: number;
  before?: string;
  query?: string;
}

export interface HistoryListResult {
  records: SpeechHistoryRecord[];
  nextCursor?: string;
}

export interface LiveSessionEvents {
  state: SessionStateEvent;
  partial: { sessionId: string; text: string };
  final: SessionFinalEvent;
  error: { error: Error };
}

export interface TransportEvents {
  open: undefined;
  close: { code: number; reason: string };
  event: { event: string; data: Record<string, unknown> };
  error: { error: Error };
}

/** Planned Core ML encoder placement, not a hardware execution trace. */
export interface CoreMLPlacement {
  neuralEngineOperations: number;
  cpuOperations: number;
  gpuOperations: number;
  unknownOperations: number;
  neuralEngineComputeOperations: number;
  cpuComputeOperations: number;
  neuralEngineEstimatedCost: number;
  cpuEstimatedCost: number;
}

export interface StreamingASRUpdate {
  text: string;
  words: WordTiming[];
  endOfUtterance: boolean;
  endpointSource?: "model" | "blank-duration";
  processedAudioMs: number;
  chunkLatencyMs: number;
}

export interface NativeStreamingStatus {
  modelId?: string;
  loadingModelId?: string;
  placement?: CoreMLPlacement;
  activeSessionId?: string;
  clientId?: string;
  idleUnloadSeconds: number;
}

export interface PCMStreamingSession {
  sessionId: string;
  modelId: string;
  sampleRate: 16000;
  channels: 1;
  encoding: "float32le";
  maxPacketSamples: 16000;
  nextSequence: number;
}
