import Foundation
import Testing
import VoxCore
import HudsonSpeechEngine
@testable import VoxService

private actor MockAnnotationProvider: AnnotationProvider {
    private var requests: [AnnotationRequest] = []

    func annotate(request: AnnotationRequest) async throws -> AnnotationOutput {
        requests.append(request)

        let metrics = AnnotationMetrics(
            traceId: "mock-annotation-trace",
            audioDurationMs: 3600,
            inputBytes: 16_384,
            wasPreloaded: true,
            fileCheckMs: 2,
            modelCheckMs: 1,
            modelLoadMs: 0,
            audioLoadMs: 4,
            audioPrepareMs: 6,
            diarizationMs: 120,
            totalMs: 133
        )

        return AnnotationOutput(
            modelId: request.modelId,
            text: request.transcription?.text,
            elapsedMs: 133,
            metrics: metrics,
            words: [
                AttributedWordTiming(word: "hello", start: 0.0, end: 0.4, confidence: 0.97, speakerId: "speaker_0"),
                AttributedWordTiming(word: "there", start: 0.4, end: 0.9, confidence: 0.95, speakerId: "speaker_1")
            ],
            speakers: [
                SpeakerSegment(speakerId: "speaker_0", start: 0.0, end: 1.2, confidence: 0.91),
                SpeakerSegment(speakerId: "speaker_1", start: 1.2, end: 2.1, confidence: 0.88)
            ]
        )
    }

    func lastRequest() -> AnnotationRequest? {
        requests.last
    }
}

private actor EmptyASRProvider: ASRProvider {
    func models() async -> [ASRModelInfo] { [] }

    func install(
        modelId: String,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        throw NSError(domain: "EmptyASRProvider", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "No ASR models"
        ])
    }

    func preload(
        modelId: String,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        throw NSError(domain: "EmptyASRProvider", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "No ASR models"
        ])
    }

    func transcribe(url: URL, modelId: String) async throws -> TranscriptionOutput {
        throw NSError(domain: "EmptyASRProvider", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "No ASR models"
        ])
    }
}

private actor EmptyAnnotationTTSProvider: TTSProvider {
    func models() async -> [TTSModelInfo] { [] }
    func voices(modelId: String?) async throws -> [TTSVoiceInfo] { [] }

    func preload(
        modelId: String,
        voiceId: String?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo {
        throw NSError(domain: "EmptyAnnotationTTSProvider", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "No TTS models"
        ])
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput {
        throw NSError(domain: "EmptyAnnotationTTSProvider", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "No TTS models"
        ])
    }
}

struct AnnotationRouteTests {
    @Test("annotate.file helper forwards transcript hints and tags performance samples")
    func annotateFileReturnsStructuredOutputAndPerformanceSample() async throws {
        let provider = MockAnnotationProvider()
        let service = VoxRuntimeService(
            engine: EngineManager(provider: EmptyASRProvider()),
            annotationEngine: AnnotationManager(provider: provider),
            ttsEngine: TTSEngineManager(provider: EmptyAnnotationTTSProvider())
        )
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let result = try await service.performAnnotateFile(params: [
            "path": audioURL.path,
            "modelId": "speaker-diarization:v1",
            "clientId": "talkie",
            "credentials": ["ELEVENLABS_API_KEY": " scoped-fixture ", "OTHER": "ignored"],
            "diarize": false, "tagAudioEvents": true, "languageCode": "eng", "numSpeakers": 2,
            "text": "hello there",
            "words": [
                [
                    "word": "hello",
                    "start": 0.0,
                    "end": 0.4,
                    "confidence": 0.97
                ],
                [
                    "word": "there",
                    "start": 0.4,
                    "end": 0.9,
                    "confidence": 0.95
                ]
            ]
        ])

        let capturedRequest = await provider.lastRequest()
        #expect(capturedRequest?.providerCredentials == ["ELEVENLABS_API_KEY": "scoped-fixture"])
        #expect(capturedRequest?.diarize == false && capturedRequest?.tagAudioEvents == true)
        #expect(capturedRequest?.languageCode == "eng" && capturedRequest?.numSpeakers == 2)
        #expect(capturedRequest?.url == audioURL)
        #expect(capturedRequest?.modelId == "speaker-diarization:v1")
        #expect(capturedRequest?.transcription?.text == "hello there")
        #expect(capturedRequest?.transcription?.words.count == 2)
        #expect(capturedRequest?.transcription?.words.first?.word == "hello")

        #expect(result.output.modelId == "speaker-diarization:v1")
        #expect(result.output.text == "hello there")
        #expect(result.output.elapsedMs == 133)
        #expect(result.output.metrics.traceId == "mock-annotation-trace")
        #expect(result.output.metrics.audioPrepareMs == 6)
        #expect(result.output.metrics.diarizationMs == 120)
        #expect(result.output.words.count == 2)
        #expect(result.output.words.first?.speakerId == "speaker_0")
        #expect(result.output.speakers.count == 2)
        #expect(result.output.speakers.last?.speakerId == "speaker_1")

        #expect(result.performanceSample.clientId == "talkie")
        #expect(result.performanceSample.route == "annotate.file")
        #expect(result.performanceSample.modelId == "speaker-diarization:v1")
        #expect(result.performanceSample.outcome == "ok")
        #expect(result.performanceSample.textLength == "hello there".count)
        #expect(result.performanceSample.metrics?.inputBytes == 16_384)
        #expect(result.performanceSample.metrics?.audioPrepareMs == 6)
        #expect(result.performanceSample.metrics?.inferenceMs == 120)
    }
}
