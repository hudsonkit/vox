import Foundation
import Testing
import VoxCore
import HudsonSpeechEngine
@testable import VoxService

private actor CancellingTTSProvider: TTSProvider {
    func models() async -> [TTSModelInfo] {
        [
            TTSModelInfo(
                id: "mock-tts:v1",
                name: "Mock TTS",
                backend: "mock",
                installed: true,
                preloaded: true,
                available: true
            )
        ]
    }

    func voices(modelId: String?) async throws -> [TTSVoiceInfo] { [] }

    func preload(
        modelId: String,
        voiceId: String?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo {
        throw CancellationError()
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput {
        throw CancellationError()
    }
}

private actor MockTTSProvider: TTSProvider {
    private let modelId: String
    private let voiceId: String
    private var capturedRequest: SynthesisRequest?
    private var voiceCredentials: [String: String] = [:]

    init(modelId: String = "mock-tts:v1", voiceId: String = "voice-mock") {
        self.modelId = modelId
        self.voiceId = voiceId
    }

    func models() async -> [TTSModelInfo] {
        [
            TTSModelInfo(
                id: modelId,
                name: "Mock TTS",
                backend: "mock",
                installed: true,
                preloaded: true,
                available: true
            )
        ]
    }

    func voices(modelId: String?, providerCredentials: [String: String]) async throws -> [TTSVoiceInfo] {
        voiceCredentials = providerCredentials
        return try await voices(modelId: modelId)
    }
    func lastVoiceCredentials() -> [String: String] { voiceCredentials }

    func voices(modelId: String?) async throws -> [TTSVoiceInfo] {
        [
            TTSVoiceInfo(
                id: voiceId,
                name: "Mock Voice",
                language: "en-US",
                backend: "mock",
                modelId: modelId ?? self.modelId,
                available: true,
                isDefault: true
            )
        ]
    }

    func preload(
        modelId: String,
        voiceId: String?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo {
        progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
        return TTSModelInfo(
            id: modelId,
            name: "Mock TTS",
            backend: "mock",
            installed: true,
            preloaded: true,
            available: true
        )
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput {
        capturedRequest = request

        let bytes = Data([0x52, 0x49, 0x46, 0x46])
        let metrics = SynthesisMetrics(
            traceId: "mock-trace",
            characterCount: request.text.count,
            audioDurationMs: 320,
            outputBytes: bytes.count,
            wasPreloaded: true,
            modelCheckMs: 1,
            modelLoadMs: 0,
            voiceResolveMs: 1,
            synthesisMs: 12,
            totalMs: 16
        )

        return SynthesisOutput(
            modelId: request.modelId,
            voiceId: request.voiceId ?? voiceId,
            format: request.format,
            contentType: "audio/wav",
            audioData: bytes,
            elapsedMs: 16,
            metrics: metrics
        )
    }

    func lastRequest() -> SynthesisRequest? {
        capturedRequest
    }
}

private actor MockSpeechTimingASRProvider: ASRProvider {
    private var transcribeCalls = 0

    func models() async -> [ASRModelInfo] {
        [
            ASRModelInfo(
                id: "mock-asr:v1",
                name: "Mock ASR",
                backend: "mock",
                installed: true,
                preloaded: true,
                available: true
            )
        ]
    }

    func install(
        modelId: String,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
        return ASRModelInfo(
            id: modelId,
            name: "Mock ASR",
            backend: "mock",
            installed: true,
            preloaded: true,
            available: true
        )
    }

    func preload(
        modelId: String,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
        return ASRModelInfo(
            id: modelId,
            name: "Mock ASR",
            backend: "mock",
            installed: true,
            preloaded: true,
            available: true
        )
    }

    func transcribe(url: URL, modelId: String) async throws -> TranscriptionOutput {
        transcribeCalls += 1

        let metrics = TranscriptionMetrics(
            traceId: "mock-asr-trace",
            audioDurationMs: 1200,
            inputBytes: 4,
            wasPreloaded: true,
            fileCheckMs: 1,
            modelCheckMs: 1,
            modelLoadMs: 0,
            audioLoadMs: 1,
            audioPrepareMs: 1,
            inferenceMs: 25,
            totalMs: 30
        )

        return TranscriptionOutput(
            modelId: modelId,
            text: "First step. Second step.",
            elapsedMs: 30,
            metrics: metrics,
            words: [
                WordTiming(word: "First", start: 0.0, end: 0.18, confidence: 0.99),
                WordTiming(word: "step", start: 0.18, end: 0.4, confidence: 0.96),
                WordTiming(word: "Second", start: 0.52, end: 0.74, confidence: 0.98),
                WordTiming(word: "step", start: 0.74, end: 1.0, confidence: 0.95)
            ]
        )
    }

    func callCount() -> Int {
        transcribeCalls
    }
}

struct SynthesisRouteTests {
    @Test("synthesize.generate helper returns audio metadata and metrics")
    func synthesizeGenerateReturnsStructuredOutput() async throws {
        let service = VoxRuntimeService(ttsEngine: TTSEngineManager(provider: MockTTSProvider()))

        let output = try await service.performSynthesizeGenerate(params: [
            "text": "hello world",
            "modelId": "mock-tts:v1",
            "voiceId": "voice-mock",
            "format": "wav"
        ])

        #expect(output.modelId == "mock-tts:v1")
        #expect(output.voiceId == "voice-mock")
        #expect(output.audioData == Data([0x52, 0x49, 0x46, 0x46]))
        #expect(output.metrics.synthesisMs == 12)
    }

    @Test("synthesize.voices helper returns the provider voice list")
    func synthesizeVoicesReturnsProviderVoices() async throws {
        let service = VoxRuntimeService(ttsEngine: TTSEngineManager(provider: MockTTSProvider()))

        let voices = try await service.performSynthesizeVoices(params: [
            "modelId": "mock-tts:v1"
        ])

        #expect(voices.count == 1)
        #expect(voices.first?.id == "voice-mock")
        #expect(voices.first?.modelId == "mock-tts:v1")
        #expect(voices.first?.isDefault == true)
    }

    @Test("synthesize.generate uses speech preferences when model and voice are omitted")
    func synthesizeGenerateUsesPreferredModelAndVoice() async throws {
        let service = VoxRuntimeService(
            ttsEngine: TTSEngineManager(provider: MockTTSProvider(
                modelId: "mock-tts:v2",
                voiceId: "voice-preferred"
            )),
            preferencesLoader: {
                VoxPreferences(
                    speech: VoxSpeechPreferences(
                        preferredSynthesisModelId: "mock-tts:v2",
                        preferredSynthesisVoiceId: "voice-preferred"
                    )
                )
            }
        )

        let output = try await service.performSynthesizeGenerate(params: [
            "text": "hello world"
        ])

        #expect(output.modelId == "mock-tts:v2")
        #expect(output.voiceId == "voice-preferred")
    }

    @Test("synthesize.generate uses configured default model when preferences are omitted")
    func synthesizeGenerateUsesConfiguredDefaultModel() async throws {
        let service = VoxRuntimeService(
            ttsEngine: TTSEngineManager(provider: MockTTSProvider(
                modelId: "mock-tts:local",
                voiceId: "voice-local"
            )),
            defaultSynthesisModelId: "mock-tts:local",
            preferencesLoader: {
                VoxPreferences()
            }
        )

        let output = try await service.performSynthesizeGenerate(params: [
            "text": "hello world"
        ])

        #expect(output.modelId == "mock-tts:local")
        #expect(output.voiceId == "voice-local")
    }

    @Test("synthesize.generate forwards explicit provider credentials")
    func synthesizeGenerateForwardsExplicitProviderCredentials() async throws {
        let provider = MockTTSProvider()
        let service = VoxRuntimeService(ttsEngine: TTSEngineManager(provider: provider))

        _ = try await service.performSynthesizeGenerate(params: [
            "text": "hello world",
            "modelId": "mock-tts:v1",
            "credentials": [
                "OPENAI_API_KEY": "sk-test-lent",
                "ignored": "not-forwarded"
            ]
        ])

        let request = await provider.lastRequest()
        #expect(request?.providerCredentials == ["OPENAI_API_KEY": "sk-test-lent"])
    }

    @Test("synthesize.generate forwards ElevenLabs, NVIDIA, Groq, and Gemini credentials and drops unsupported keys")
    func synthesizeGenerateForwardsRemoteProviderCredentials() async throws {
        let provider = MockTTSProvider()
        let service = VoxRuntimeService(ttsEngine: TTSEngineManager(provider: provider))

        _ = try await service.performSynthesizeGenerate(params: [
            "text": "hello world",
            "modelId": "mock-tts:v1",
            "credentials": [
                "NV_API_KEY": " nv-lent ",
                "NVIDIA_API_KEY": "nvidia-alias",
                "GROQ_API_KEY": "groq-lent",
                "GEMINI_API_KEY": "gemini-lent",
                "GOOGLE_API_KEY": "google-lent",
                "ELEVENLABS_API_KEY": " eleven-lent ",
                "ignored": "not-forwarded"
            ]
        ])

        let request = await provider.lastRequest()
        #expect(request?.providerCredentials["NV_API_KEY"] == "nv-lent")
        #expect(request?.providerCredentials["NVIDIA_API_KEY"] == "nvidia-alias")
        #expect(request?.providerCredentials["GROQ_API_KEY"] == "groq-lent")
        #expect(request?.providerCredentials["GEMINI_API_KEY"] == "gemini-lent")
        #expect(request?.providerCredentials["GOOGLE_API_KEY"] == "google-lent")
        #expect(request?.providerCredentials["ELEVENLABS_API_KEY"] == "eleven-lent")
        #expect(request?.providerCredentials["ignored"] == nil)
    }

    @Test("synthesize.voices forwards scoped ElevenLabs keys without changing the next request")
    func synthesizeVoicesForwardsScopedCredentials() async throws {
        let provider = MockTTSProvider()
        let service = VoxRuntimeService(ttsEngine: TTSEngineManager(provider: provider))
        _ = try await service.performSynthesizeVoices(params: ["modelId": "mock-tts:v1",
            "credentials": ["ELEVENLABS_API_KEY": " selected-account ", "ignored": "drop"]])
        #expect(await provider.lastVoiceCredentials() == ["ELEVENLABS_API_KEY": "selected-account"])
        _ = try await service.performSynthesizeVoices(params: ["modelId": "mock-tts:v1"])
        #expect(await provider.lastVoiceCredentials().isEmpty)
        await #expect(throws: TTSVoiceCredentialsError.self) {
            try await service.performSynthesizeVoices(params: ["credentials": ["ELEVENLABS_API_KEY": "selected-account"]])
        }
    }

    @Test("synthesize.generate preserves CancellationError instead of mapping it to failure")
    func synthesizeGeneratePreservesCancellation() async {
        let service = VoxRuntimeService(
            ttsEngine: TTSEngineManager(provider: CancellingTTSProvider())
        )
        do {
            _ = try await service.performSynthesizeGenerate(params: [
                "text": "hello world",
                "modelId": "mock-tts:v1"
            ])
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected: callers record/reply cancelled rather than a failure string.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test("synthesize.generate adds optional speech timing from ASR over synthesized audio")
    func synthesizeGenerateAddsSpeechTimingWhenRequested() async throws {
        let asrProvider = MockSpeechTimingASRProvider()
        let service = VoxRuntimeService(
            engine: EngineManager(provider: asrProvider),
            ttsEngine: TTSEngineManager(provider: MockTTSProvider())
        )

        let output = try await service.performSynthesizeGenerate(params: [
            "text": "First step. Second step.",
            "modelId": "mock-tts:v1",
            "voiceId": "voice-mock",
            "speechTiming": [
                "enabled": true,
                "modelId": "mock-asr:v1",
                "cues": [
                    [
                        "id": "first",
                        "textStart": 0,
                        "textEnd": 10
                    ],
                    [
                        "id": "second",
                        "text": "Second step"
                    ]
                ]
            ]
        ])

        let speechTiming = try #require(output.speechTiming)
        #expect(speechTiming.source == "asr")
        #expect(speechTiming.modelId == "mock-asr:v1")
        #expect(speechTiming.words.count == 4)
        #expect(speechTiming.words.first?.sourceTextStart == 0)
        #expect(speechTiming.cues.count == 2)
        #expect(speechTiming.cues[0].id == "first")
        #expect(speechTiming.cues[0].startMs == 0)
        #expect(speechTiming.cues[0].endMs == 400)
        #expect(speechTiming.cues[0].source == "asr")
        #expect(speechTiming.cues[1].id == "second")
        #expect(speechTiming.cues[1].startMs == 520)
        #expect(speechTiming.cues[1].endMs == 1000)

        let payload = output.dictionaryValue()
        #expect(payload["speechTiming"] != nil)
        #expect(payload["alignment"] == nil)
        #expect(await asrProvider.callCount() == 1)
    }

    @Test("synthesize.generate keeps fast path when speech timing is omitted")
    func synthesizeGenerateSkipsSpeechTimingByDefault() async throws {
        let asrProvider = MockSpeechTimingASRProvider()
        let service = VoxRuntimeService(
            engine: EngineManager(provider: asrProvider),
            ttsEngine: TTSEngineManager(provider: MockTTSProvider())
        )

        let output = try await service.performSynthesizeGenerate(params: [
            "text": "First step. Second step.",
            "modelId": "mock-tts:v1",
            "voiceId": "voice-mock"
        ])

        #expect(output.speechTiming == nil)
        #expect(output.dictionaryValue()["speechTiming"] == nil)
        #expect(await asrProvider.callCount() == 0)
    }
}
