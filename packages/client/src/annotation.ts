import type { AttributedWordTiming, SpeakerSegment } from "./types.ts";

export function parseAttributedWordTimings(value: unknown): AttributedWordTiming[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.filter((entry) => typeof entry?.word === "string" && entry.word.length > 0).map((entry) => {
    const word = typeof entry === "object" && entry !== null ? entry : {};
    const fields = word as Record<string, unknown>;
    validateInterval(fields);
    return {
      word: String(fields.word ?? ""),
      start: Number(fields.start ?? 0),
      end: Number(fields.end ?? 0),
      confidence: optionalScore(fields.confidence),
      language: typeof fields.language === "string" ? fields.language : null,
      logProbability: optionalLogProbability(fields.logProbability),
      speakerConfidence: optionalScore(fields.speakerConfidence),
      speakerId:
        typeof fields.speakerId === "string" && fields.speakerId.length > 0
          ? fields.speakerId
          : null,
    } satisfies AttributedWordTiming;
  }).filter((word) => word.word.length > 0);
}

export function parseSpeakerSegments(value: unknown): SpeakerSegment[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.filter((entry) => typeof entry?.speakerId === "string" && entry.speakerId.length > 0).map((entry) => {
    const segment = typeof entry === "object" && entry !== null ? entry : {};
    const fields = segment as Record<string, unknown>;
    validateInterval(fields);
    return {
      speakerId: String(fields.speakerId ?? ""),
      start: Number(fields.start ?? 0),
      end: Number(fields.end ?? 0),
      confidence: optionalScore(fields.confidence),
    } satisfies SpeakerSegment;
  }).filter((segment) => segment.speakerId.length > 0);
}

function validateInterval(fields: Record<string, unknown>): void {
  if (typeof fields.start !== "number" || typeof fields.end !== "number" ||
      !Number.isFinite(fields.start) || !Number.isFinite(fields.end) ||
      fields.start < 0 || fields.end < fields.start) throw new Error("Invalid annotation interval");
}
function optionalScore(value: unknown): number | null {
  if (value == null) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > 1)
    throw new Error("Invalid annotation confidence");
  return value;
}

function optionalLogProbability(value: unknown): number | null {
  if (value == null) return null;
  if (typeof value !== "number" || !Number.isFinite(value) || value > 0)
    throw new Error("Invalid annotation log probability");
  return value;
}
