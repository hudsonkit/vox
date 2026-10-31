import { parseAttributedWordTimings, parseSpeakerSegments } from "../src/annotation.ts";
import { parseAnnotationMetrics, parseTranscriptionMetrics } from "../src/metrics.ts";
import { parseWordTimings } from "../src/words.ts";

describe("parseTranscriptionMetrics", () => {
  it("uses the elapsed fallback when totalMs is missing", () => {
    expect(
      parseTranscriptionMetrics(
        {
          traceId: "trace-1",
          audioDurationMs: 2400,
          inputBytes: 8192,
          wasPreloaded: true,
          fileCheckMs: 2,
          modelCheckMs: 1,
          modelLoadMs: 0,
          audioLoadMs: 3,
          audioPrepareMs: 4,
          inferenceMs: 90,
        },
        107,
      ),
    ).toEqual({
      traceId: "trace-1",
      audioDurationMs: 2400,
      inputBytes: 8192,
      wasPreloaded: true,
      fileCheckMs: 2,
      modelCheckMs: 1,
      modelLoadMs: 0,
      audioLoadMs: 3,
      audioPrepareMs: 4,
      inferenceMs: 90,
      totalMs: 107,
      realtimeFactor: 0,
    });
  });

  it("returns undefined for non-object values", () => {
    expect(parseTranscriptionMetrics(undefined, 50)).toBeUndefined();
    expect(parseTranscriptionMetrics("oops", 50)).toBeUndefined();
  });
});

describe("parseWordTimings", () => {
  it("filters empty words and defaults missing numeric fields", () => {
    expect(
      parseWordTimings([
        { word: "hello", start: 0.01, end: 0.2, confidence: 0.98 },
        { word: "", start: 0.21, end: 0.4, confidence: 0.91 },
        { start: 0.41, end: 0.8 },
        { word: "world" },
      ]),
    ).toEqual([
      { word: "hello", start: 0.01, end: 0.2, confidence: 0.98 },
      { word: "world", start: 0, end: 0, confidence: 0 },
    ]);
  });

  it("returns an empty array for non-array values", () => {
    expect(parseWordTimings(undefined)).toEqual([]);
    expect(parseWordTimings({ word: "hello" })).toEqual([]);
  });
});

describe("parseAnnotationMetrics", () => {
  it("uses the elapsed fallback when totalMs is missing", () => {
    expect(
      parseAnnotationMetrics(
        {
          traceId: "trace-2",
          audioDurationMs: 5100,
          inputBytes: 16384,
          wasPreloaded: false,
          fileCheckMs: 1,
          modelCheckMs: 2,
          modelLoadMs: 10,
          audioLoadMs: 4,
          audioPrepareMs: 5,
          diarizationMs: 120,
        },
        165,
      ),
    ).toEqual({
      traceId: "trace-2",
      audioDurationMs: 5100,
      inputBytes: 16384,
      wasPreloaded: false,
      fileCheckMs: 1,
      modelCheckMs: 2,
      modelLoadMs: 10,
      audioLoadMs: 4,
      audioPrepareMs: 5,
      diarizationMs: 120,
      totalMs: 165,
      realtimeFactor: 0,
    });
  });
});

describe("parseAttributedWordTimings", () => {
  it("parses words and preserves optional speaker ids", () => {
    expect(
      parseAttributedWordTimings([
        { word: "hello", start: 0.01, end: 0.2, confidence: 0.98, speakerId: "speaker-0" },
        { word: "world", start: 0.21, end: 0.4, confidence: 0.91 },
        { word: "" },
      ]),
    ).toEqual([
      { word: "hello", start: 0.01, end: 0.2, confidence: 0.98, logProbability: null, speakerConfidence: null, speakerId: "speaker-0" },
      { word: "world", start: 0.21, end: 0.4, confidence: 0.91, logProbability: null, speakerConfidence: null, speakerId: null },
    ]);
  });
});

describe("parseSpeakerSegments", () => {
  it("parses speaker segments and filters blank speaker ids", () => {
    expect(
      parseSpeakerSegments([
        { speakerId: "speaker-0", start: 0.0, end: 1.2, confidence: 0.87 },
        { speakerId: "speaker-1", start: 1.2, end: 2.1 },
        { speakerId: "" },
      ]),
    ).toEqual([
      { speakerId: "speaker-0", start: 0, end: 1.2, confidence: 0.87 },
      { speakerId: "speaker-1", start: 1.2, end: 2.1, confidence: null },
    ]);
  });
});

it("preserves absent annotation scores as null and rejects fabricated intervals", () => {
  expect(parseAttributedWordTimings([{ word: "test", start: 0, end: 1, logProbability: -0.2 }])[0])
    .toMatchObject({ confidence: null, logProbability: -0.2, speakerConfidence: null });
  expect(() => parseAttributedWordTimings([{ word: "test" }])).toThrow("Invalid annotation interval");
});
