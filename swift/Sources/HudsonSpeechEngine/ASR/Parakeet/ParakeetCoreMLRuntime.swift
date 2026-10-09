import Foundation
import VoxCore

final class ParakeetCoreMLRuntime: @unchecked Sendable, ParakeetRuntime {
    private let log = VoxLog.engine
    private let modelId: String
    private let modelLoader: ParakeetModelLoader
    private let inferenceConfig: ParakeetInferenceConfig
    private var loadedModels: ParakeetLoadedModels?
    private var singleChunkTranscriber: ParakeetSingleChunkTranscriber?

    init(
        manifest: ParakeetModelManifest = .v3,
        modelLoader: ParakeetModelLoader? = nil
    ) {
        self.modelId = manifest.modelId
        self.modelLoader = modelLoader ?? ParakeetModelLoader(manifest: manifest)
        self.inferenceConfig = manifest.inferenceConfig
    }

    var isAvailable: Bool {
        true
    }

    func isPreloaded() async -> Bool {
        singleChunkTranscriber != nil
    }

    func load(from directory: URL, progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        if singleChunkTranscriber != nil {
            progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
            return
        }

        progress(ModelProgress(modelId: modelId, progress: 0.85, status: "loading"))
        let loadedModels = try modelLoader.loadModels(from: directory)
        self.loadedModels = loadedModels
        self.singleChunkTranscriber = ParakeetSingleChunkTranscriber(
            models: loadedModels,
            config: inferenceConfig
        )
        progress(ModelProgress(modelId: modelId, progress: 0.95, status: "warming"))
        await prime()
        progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
    }

    /// Runs the long-form path once on silence, with every chunk worker busy.
    ///
    /// Loading a model does not prepare it for the Neural Engine. Each parallel
    /// prediction stream is compiled on first use, about 30 s apiece when the
    /// system cache is cold, so without this the first dictation longer than
    /// 15 s pays for every compile while the user waits.
    private func prime() async {
        let started = Date()
        let chunks = max(1, inferenceConfig.parallelChunkConcurrency) + 1
        let silence = [Float](repeating: 0, count: ParakeetConstants.maxModelSamples * chunks)
        do {
            _ = try await transcribe(samples: silence)
            log.info("Parakeet primed in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            log.warning("Parakeet priming failed: \(error.localizedDescription)")
        }
    }

    func transcribe(samples: [Float]) async throws -> ParakeetInferenceResult {
        guard let singleChunkTranscriber else {
            throw NSError(domain: "VoxEngine", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Parakeet runtime is not initialized."
            ])
        }

        if samples.count <= ParakeetConstants.maxModelSamples {
            log.info("Using Vox-owned single-chunk Parakeet runtime")
            return try await singleChunkTranscriber.transcribe(samples: samples)
        }

        guard let loadedModels else {
            throw NSError(domain: "VoxEngine", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Parakeet models are not initialized."
            ])
        }

        log.info("Using Vox-owned long-form Parakeet chunk processor")
        let config = inferenceConfig
        return try await ParakeetChunkProcessor(
            audioSamples: samples,
            workerCount: max(1, config.parallelChunkConcurrency),
            transcriberFactory: {
                ParakeetSingleChunkTranscriber(models: loadedModels, config: config)
            }
        ).process()
    }
}
