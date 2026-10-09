import Foundation
import Testing
import VoxCore
import VoxEngine

struct VoxDictationTests {
    @Test("warmUp preloads the configured model and reports ready")
    func warmUpPreloads() async throws {
        let provider = StubASRProvider()
        let dictation = VoxDictation(
            clientId: "test",
            modelId: "stub:v1",
            engine: EngineManager(provider: provider),
            recordsPerformance: false
        )

        #expect(await dictation.isReady == false)
        let info = try await dictation.warmUp()
        #expect(info.id == "stub:v1")
        #expect(await dictation.isReady)
        #expect(await provider.preloadedModels == ["stub:v1"])
    }

    @Test("transcribe(fileURL:) uses the configured model")
    func transcribesFile() async throws {
        let dictation = VoxDictation(
            clientId: "test",
            modelId: "stub:v1",
            engine: EngineManager(provider: StubASRProvider()),
            recordsPerformance: false
        )

        let output = try await dictation.transcribe(fileURL: URL(fileURLWithPath: "/tmp/hello.wav"))
        #expect(output.text == "heard hello.wav")
        #expect(output.modelId == "stub:v1")
    }

    @Test("transcription errors reach the caller")
    func rethrowsErrors() async {
        let dictation = VoxDictation(
            clientId: "test",
            modelId: "missing:v1",
            engine: EngineManager(provider: StubASRProvider()),
            recordsPerformance: false
        )

        await #expect(throws: (any Error).self) {
            try await dictation.transcribe(fileURL: URL(fileURLWithPath: "/tmp/hello.wav"))
        }
    }

    @Test("stop without start throws notListening")
    func stopWithoutStart() async {
        let dictation = VoxDictation(
            clientId: "test",
            engine: EngineManager(provider: StubASRProvider()),
            recordsPerformance: false
        )

        await #expect(throws: VoxDictationError.notListening) {
            try await dictation.stop()
        }
        #expect(await dictation.isListening == false)
    }
}

private actor StubASRProvider: ASRProvider {
    private(set) var preloadedModels: [String] = []

    func models() async -> [ASRModelInfo] {
        [info(preloaded: !preloadedModels.isEmpty)]
    }

    func install(modelId: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ASRModelInfo {
        info(preloaded: false)
    }

    func preload(modelId: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ASRModelInfo {
        preloadedModels.append(modelId)
        return info(preloaded: true)
    }

    func transcribe(url: URL, modelId: String) async throws -> TranscriptionOutput {
        guard modelId == "stub:v1" else {
            throw NSError(domain: "StubASRProvider", code: 404)
        }
        return TranscriptionOutput(
            modelId: modelId,
            text: "heard \(url.lastPathComponent)",
            elapsedMs: 5,
            metrics: TranscriptionMetrics(
                traceId: "stub",
                audioDurationMs: 1000,
                inputBytes: 0,
                wasPreloaded: true,
                fileCheckMs: 0,
                modelCheckMs: 0,
                modelLoadMs: 0,
                audioLoadMs: 0,
                audioPrepareMs: 0,
                inferenceMs: 5,
                totalMs: 5
            )
        )
    }

    private func info(preloaded: Bool) -> ASRModelInfo {
        ASRModelInfo(id: "stub:v1", name: "Stub", backend: "stub", installed: true, preloaded: preloaded, available: true)
    }
}
