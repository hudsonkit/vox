import Foundation
import Testing
import VoxCore
import HudsonSpeechEngine
@testable import VoxService

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ModelProgress] = []

    func record(_ update: ModelProgress) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    func snapshot() -> [ModelProgress] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

private actor MockASRProvider: ASRProvider {
    private let modelId: String
    private var isPreloaded = false
    private var preloadCalls = 0

    init(modelId: String = "parakeet:v3") {
        self.modelId = modelId
    }

    func evict() { isPreloaded = false }

    func models() async -> [ASRModelInfo] {
        [
            ASRModelInfo(
                id: modelId,
                name: "Mock Parakeet",
                backend: "mock-parakeet",
                installed: true,
                preloaded: isPreloaded,
                available: true
            )
        ]
    }

    func install(
        modelId: String,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        progress(ModelProgress(modelId: modelId, progress: 0.25, status: "starting"))
        isPreloaded = true
        progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
        return try await resolvedModelInfo(for: modelId)
    }

    func preload(
        modelId: String,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        preloadCalls += 1
        progress(ModelProgress(modelId: modelId, progress: 0.6, status: "warming"))
        isPreloaded = true
        progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
        return try await resolvedModelInfo(for: modelId)
    }

    func transcribe(url: URL, modelId: String) async throws -> TranscriptionOutput {
        guard modelId == self.modelId else {
            throw NSError(domain: "MockASRProvider", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported model: \(modelId)"
            ])
        }

        let metrics = TranscriptionMetrics(
            traceId: "mock-asr-trace",
            audioDurationMs: 2400,
            inputBytes: 8192,
            wasPreloaded: isPreloaded,
            fileCheckMs: 2,
            modelCheckMs: 1,
            modelLoadMs: isPreloaded ? 0 : 7,
            audioLoadMs: 3,
            audioPrepareMs: 4,
            inferenceMs: 90,
            totalMs: 107
        )

        return TranscriptionOutput(
            modelId: modelId,
            text: "transcribed \(url.lastPathComponent)",
            elapsedMs: 107,
            metrics: metrics,
            words: [
                WordTiming(word: "transcribed", start: 0.0, end: 0.5, confidence: 0.98),
                WordTiming(word: url.deletingPathExtension().lastPathComponent, start: 0.5, end: 1.2, confidence: 0.93)
            ]
        )
    }

    func preloadCallCount() -> Int {
        preloadCalls
    }

    private func resolvedModelInfo(for modelId: String) async throws -> ASRModelInfo {
        guard modelId == self.modelId else {
            throw NSError(domain: "MockASRProvider", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported model: \(modelId)"
            ])
        }

        return ASRModelInfo(
            id: modelId,
            name: "Mock Parakeet",
            backend: "mock-parakeet",
            installed: true,
            preloaded: true,
            available: true
        )
    }
}

private actor EmptyTTSProvider: TTSProvider {
    func models() async -> [TTSModelInfo] { [] }
    func voices(modelId: String?) async throws -> [TTSVoiceInfo] { [] }

    func preload(
        modelId: String,
        voiceId: String?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo {
        throw NSError(domain: "EmptyTTSProvider", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "No TTS models"
        ])
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput {
        throw NSError(domain: "EmptyTTSProvider", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "No TTS models"
        ])
    }
}

struct ASRRouteTests {
    @Test("models.install helper returns model info and forwards progress updates")
    func modelsInstallReturnsStructuredModelAndProgress() async throws {
        let provider = MockASRProvider()
        let collector = ProgressCollector()
        let service = VoxRuntimeService(
            engine: EngineManager(provider: provider),
            ttsEngine: TTSEngineManager(provider: EmptyTTSProvider())
        )

        let model = try await service.performModelsInstall(params: [
            "modelId": "parakeet:v3"
        ]) { update in
            collector.record(update)
        }

        let updates = collector.snapshot()
        #expect(model.id == "parakeet:v3")
        #expect(model.backend == "mock-parakeet")
        #expect(model.preloaded)
        #expect(updates.count == 2)
        #expect(updates.first?.modelId == "parakeet:v3")
        #expect(updates.last?.progress == 1.0)
        #expect(updates.last?.status == "ready")
    }

    @Test("models.preload helper returns model info and forwards progress updates")
    func modelsPreloadReturnsStructuredModelAndProgress() async throws {
        let provider = MockASRProvider()
        let collector = ProgressCollector()
        let service = VoxRuntimeService(
            engine: EngineManager(provider: provider),
            ttsEngine: TTSEngineManager(provider: EmptyTTSProvider())
        )

        let model = try await service.performModelsPreload(params: [
            "modelId": "parakeet:v3"
        ]) { update in
            collector.record(update)
        }

        let updates = collector.snapshot()
        #expect(model.id == "parakeet:v3")
        #expect(model.preloaded)
        #expect(updates.count == 2)
        #expect(updates.first?.status == "warming")
        #expect(updates.last?.status == "ready")
    }

    @Test("transcribe.file helper returns structured output and tagged performance sample")
    func transcribeFileReturnsStructuredOutputAndPerformanceSample() async throws {
        let provider = MockASRProvider()
        let service = VoxRuntimeService(
            engine: EngineManager(provider: provider),
            ttsEngine: TTSEngineManager(provider: EmptyTTSProvider())
        )
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let result = try await service.performTranscribeFile(params: [
            "path": audioURL.path,
            "modelId": "parakeet:v3",
            "clientId": "menu-bar"
        ])

        #expect(result.output.modelId == "parakeet:v3")
        #expect(result.output.text.contains(audioURL.lastPathComponent))
        #expect(result.output.elapsedMs == 107)
        #expect(result.output.metrics.traceId == "mock-asr-trace")
        #expect(result.output.metrics.audioPrepareMs == 4)
        #expect(result.output.words.count == 2)
        #expect(result.output.words.first?.word == "transcribed")
        #expect(result.performanceSample.clientId == "menu-bar")
        #expect(result.performanceSample.route == "transcribe.file")
        #expect(result.performanceSample.modelId == "parakeet:v3")
        #expect(result.performanceSample.outcome == "ok")
        #expect(result.performanceSample.textLength == result.output.text.count)
        #expect(result.performanceSample.metrics?.inputBytes == 8192)
        #expect(result.performanceSample.metrics?.audioPrepareMs == 4)
    }

    @Test("transcribe.file uses the user preference when modelId is omitted")
    func transcribeFileUsesPreferredModelWhenOmitted() async throws {
        let provider = MockASRProvider(modelId: "mock-asr:v2")
        let service = VoxRuntimeService(
            engine: EngineManager(provider: provider),
            ttsEngine: TTSEngineManager(provider: EmptyTTSProvider()),
            preferencesLoader: {
                VoxPreferences(
                    speech: VoxSpeechPreferences(preferredTranscriptionModelId: "mock-asr:v2")
                )
            }
        )
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let result = try await service.performTranscribeFile(params: [
            "path": audioURL.path,
            "clientId": "menu-bar"
        ])

        #expect(result.output.modelId == "mock-asr:v2")
        #expect(result.performanceSample.modelId == "mock-asr:v2")
    }

    @Test("install, preload, and warmup helpers use the user preference when modelId is omitted")
    func modelHelpersUsePreferredModelWhenOmitted() async throws {
        let provider = MockASRProvider(modelId: "mock-asr:v2")
        let collector = ProgressCollector()
        let service = VoxRuntimeService(
            engine: EngineManager(provider: provider),
            ttsEngine: TTSEngineManager(provider: EmptyTTSProvider()),
            preferencesLoader: {
                VoxPreferences(
                    speech: VoxSpeechPreferences(preferredTranscriptionModelId: "mock-asr:v2")
                )
            }
        )

        let installed = try await service.performModelsInstall(params: nil) { update in
            collector.record(update)
        }
        let preloaded = try await service.performModelsPreload(params: nil) { update in
            collector.record(update)
        }
        let scheduled = await service.performWarmupSchedule(params: [
            "clientId": "voice-loop",
            "delayMs": 0
        ])

        #expect(installed.id == "mock-asr:v2")
        #expect(preloaded.id == "mock-asr:v2")
        #expect(scheduled.modelId == "mock-asr:v2")
        #expect(scheduled.requestedBy == "voice-loop")
        #expect(collector.snapshot().contains(where: { $0.modelId == "mock-asr:v2" }))

        let ready = try await eventuallyWarmStatus(from: service, modelId: "mock-asr:v2")
        #expect(ready.state == "ready")
        #expect(await provider.preloadCallCount() >= 1)
    }

    @Test("warmup helpers preserve requestedBy, scheduling, and readiness for ASR models")
    func warmupHelpersPreserveRouteContract() async throws {
        let provider = MockASRProvider()
        let service = VoxRuntimeService(
            engine: EngineManager(provider: provider),
            ttsEngine: TTSEngineManager(provider: EmptyTTSProvider())
        )

        let scheduled = await service.performWarmupSchedule(params: [
            "modelId": "parakeet:v3",
            "clientId": "voice-loop",
            "delayMs": 25
        ])
        #expect(scheduled.modelId == "parakeet:v3")
        #expect(scheduled.state == "scheduled")
        #expect(scheduled.requestedBy == "voice-loop")
        #expect(scheduled.scheduledFor != nil)

        let ready = try await eventuallyWarmStatus(from: service, modelId: "parakeet:v3")
        #expect(ready.state == "ready")
        #expect(ready.requestedBy == "voice-loop")
        #expect(ready.completedAt != nil)
        #expect(await provider.preloadCallCount() == 1)
    }

    @Test("Warmup status becomes idle after model eviction")
    func warmupStatusAfterEviction() async throws {
        let provider = MockASRProvider()
        let service = VoxRuntimeService(engine: EngineManager(provider: provider), ttsEngine: TTSEngineManager(provider: EmptyTTSProvider()))
        _ = try await service.performModelsPreload(params: ["modelId": "parakeet:v3"]) { _ in }
        #expect(await service.performWarmupStatus(params: ["modelId": "parakeet:v3"]).state == "ready")
        await provider.evict()
        #expect(await service.performWarmupStatus(params: ["modelId": "parakeet:v3"]).state == "idle")
    }

    private func eventuallyWarmStatus(
        from service: VoxRuntimeService,
        modelId: String,
        timeoutMs: Int = 500
    ) async throws -> WarmupStatus {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            let status = await service.performWarmupStatus(params: [
                "modelId": modelId
            ])
            if status.state == "ready" || status.state == "failed" {
                return status
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        return await service.performWarmupStatus(params: [
            "modelId": modelId
        ])
    }
}
