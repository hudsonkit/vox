import Foundation
import VoxCore

public final class ParakeetProvider: @unchecked Sendable, ASRProvider {
    private let log = VoxLog.engine
    private let manifests: [ParakeetModelManifest]
    private let audioLoader: ParakeetAudioLoader
    private let catalogStore: ModelCatalogStore?
    private var engines: [String: Engine] = [:]
    private let engineLock = NSLock()

    private struct Engine: Sendable {
        let manifest: ParakeetModelManifest
        let store: ParakeetModelStore
        let runtime: any ParakeetRuntime
        let operations = ParakeetOperations()
    }

    private final class SharedEngines: @unchecked Sendable {
        let lock = NSLock()
        var engines: [String: Engine] = [:]
    }
    private static let sharedEngines = SharedEngines()

    public init(catalogStore: ModelCatalogStore = .shared) {
        self.catalogStore = catalogStore
        let catalogManifests = catalogStore.parakeetManifests()
        self.manifests = catalogManifests.isEmpty ? ParakeetModelManifest.builtin : catalogManifests
        self.audioLoader = ParakeetAudioLoader()
    }

    init(
        manifest: ParakeetModelManifest = .v3,
        store: ParakeetModelStore? = nil,
        runtime: (any ParakeetRuntime)? = nil,
        audioLoader: ParakeetAudioLoader = ParakeetAudioLoader()
    ) {
        self.catalogStore = nil
        self.manifests = [manifest]
        self.audioLoader = audioLoader
        self.engines = [
            manifest.modelId: Engine(
                manifest: manifest,
                store: store ?? ParakeetModelStore(manifest: manifest),
                runtime: runtime ?? ParakeetCoreMLRuntime(manifest: manifest)
            )
        ]
    }

    /// Fixture seam for proving multiple provider owners share one lifecycle gate.
    init(sharing other: ParakeetProvider) {
        self.catalogStore = nil; self.manifests = other.manifests; self.audioLoader = other.audioLoader
        self.engines = other.engineLock.withLock { other.engines }
    }

    public func models() async -> [ASRModelInfo] {
        var infos: [ASRModelInfo] = []
        for manifest in resolvedManifests() {
            infos.append(await modelInfo(for: engine(for: manifest)))
        }
        return infos
    }

    /// Download/validate only. Core ML load and priming belong to explicit preload.
    public func install(modelId: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ASRModelInfo {
        let engine = try resolveEngine(modelId: modelId)
        return try await engine.operations.withUse(runtime: engine.runtime) {
            _ = try await engine.operations.installed(engine.store, progress: progress)
            progress(ModelProgress(modelId: modelId, progress: 1, status: "installed"))
            return await self.modelInfo(for: engine)
        }
    }
    public func preload(modelId: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ASRModelInfo {
        let engine = try resolveEngine(modelId: modelId)
        return try await engine.operations.withUse(runtime: engine.runtime) { try await self.ensureLoaded(engine: engine, progress: progress) }
    }
    /// Read-only location of this engine's Vox-owned revision. Does not create files.
    public func modelDirectory(modelId: String) throws -> URL {
        try resolveEngine(modelId: modelId).store.ownedDirectory()
    }
    /// Release the shared model session, not merely this provider's local reference.
    public func unload(modelId: String) async throws -> ASRModelInfo {
        let engine = try resolveEngine(modelId: modelId)
        return try await engine.operations.withExclusive {
            try await engine.runtime.unload()
            return await self.modelInfo(for: engine)
        }
    }
    /// Unload then delete only this owned revision. Never deletes the store root,
    /// other models, external FluidAudio caches, or Core ML's system caches.
    public func deleteModel(modelId: String) async throws -> ASRModelInfo {
        let engine = try resolveEngine(modelId: modelId)
        return try await engine.operations.withExclusive {
            try await engine.runtime.unload()
            try engine.store.removeInstallation()
            return await self.modelInfo(for: engine)
        }
    }
    /// Zero disables idle unloading. Does not cancel an admitted operation.
    public func setIdleUnload(modelId: String, seconds: Double) async throws {
        let engine = try resolveEngine(modelId: modelId)
        try await engine.operations.withUse(runtime: engine.runtime) { try await engine.runtime.setIdleUnload(seconds: seconds) }
    }

    public func transcribe(url: URL, modelId: String) async throws -> TranscriptionOutput {
        let engine = try resolveEngine(modelId: modelId)
        return try await engine.operations.withUse(runtime: engine.runtime) { try await self.transcribe(url: url, engine: engine) }
    }

    private func transcribe(url: URL, engine: Engine) async throws -> TranscriptionOutput {
        let trace = TranscriptionTrace()

        trace.begin("file_check")
        try validateAudioFile(url: url)
        let inputBytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue) ?? 0
        trace.end("\(inputBytes) bytes")

        trace.begin("model_check")
        let wasPreloaded = await engine.runtime.isPreloaded()
        trace.end(wasPreloaded ? "already loaded" : "needs load")

        if !wasPreloaded {
            trace.begin("model_load")
        }
        _ = try await ensureLoaded(engine: engine) { _ in }
        if !wasPreloaded {
            trace.end("initialized")
        }

        trace.begin("audio_load")
        let loadedInput = try audioLoader.load(from: url)
        _ = trace.end("\(loadedInput.samples.count) samples")

        trace.begin("audio_prepare")
        let prepared = ParakeetSamplePreparer.ensureMinimumDuration(samples: loadedInput.samples)
        trace.end(prepared.wasPadded ? "padded" : "unchanged")

        trace.begin("inference")
        let result = try await engine.runtime.transcribe(samples: prepared.samples)
        let inferenceMs = trace.end("\(result.text.count) chars")

        let metrics = TranscriptionMetrics(
            traceId: trace.traceId,
            audioDurationMs: loadedInput.audioDurationMs,
            inputBytes: loadedInput.inputBytes,
            wasPreloaded: wasPreloaded,
            fileCheckMs: trace.durationMs(for: "file_check"),
            modelCheckMs: trace.durationMs(for: "model_check"),
            modelLoadMs: trace.durationMs(for: "model_load"),
            audioLoadMs: loadedInput.audioLoadMs,
            audioPrepareMs: trace.durationMs(for: "audio_prepare"),
            inferenceMs: inferenceMs,
            totalMs: trace.elapsedMs
        )

        log.info("Trace complete \(trace.summary)")
        return TranscriptionOutput(
            modelId: engine.manifest.modelId,
            text: result.text,
            elapsedMs: metrics.totalMs,
            metrics: metrics,
            words: result.words
        )
    }

    func validateAudioFile(url: URL) throws {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "VoxEngine", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Audio file not found at \(path)"
            ])
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw NSError(domain: "VoxEngine", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Expected an audio file but found a directory at \(path)"
            ])
        }

        guard FileManager.default.isReadableFile(atPath: path) else {
            throw NSError(domain: "VoxEngine", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Audio file is not readable at \(path)"
            ])
        }
    }

    private func resolvedManifests() -> [ParakeetModelManifest] {
        if let catalogStore {
            let catalogManifests = catalogStore.parakeetManifests()
            if !catalogManifests.isEmpty {
                return catalogManifests
            }
        }
        return manifests
    }

    private func resolveEngine(modelId: String) throws -> Engine {
        guard let manifest = resolvedManifests().first(where: { $0.modelId == modelId }) else {
            throw NSError(domain: "VoxEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported model: \(modelId)"
            ])
        }
        return engine(for: manifest)
    }

    private func engine(for manifest: ParakeetModelManifest) -> Engine {
        engineLock.lock()
        defer { engineLock.unlock() }
        if let existing = engines[manifest.modelId] {
            return existing
        }
        Self.sharedEngines.lock.lock()
        defer { Self.sharedEngines.lock.unlock() }
        if let shared = Self.sharedEngines.engines[manifest.modelId] { return shared }
        let created = Engine(
            manifest: manifest,
            store: ParakeetModelStore(manifest: manifest),
            runtime: ParakeetCoreMLRuntime(manifest: manifest)
        )
        Self.sharedEngines.engines[manifest.modelId] = created
        engines[manifest.modelId] = created
        return created
    }

    private func ensureLoaded(
        engine: Engine,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        guard engine.runtime.isAvailable else { throw StreamingASRError.unavailable("Parakeet ANE inference requires supported Apple hardware, not Simulator") }
        let installedDirectory = try await engine.operations.installed(engine.store, progress: progress)
        try await engine.runtime.load(from: installedDirectory, progress: progress)
        log.info("\(engine.manifest.name) loaded")
        return await modelInfo(for: engine)
    }

    private func modelInfo(for engine: Engine) async -> ASRModelInfo {
        let snapshot = await engine.runtime.snapshot()
        return ASRModelInfo(
            id: engine.manifest.modelId,
            name: engine.manifest.name,
            backend: engine.manifest.backend,
            installed: engine.store.isInstalled(),
            preloaded: snapshot.preloaded,
            available: engine.runtime.isAvailable,
            computePlacement: snapshot.placement,
            idleUnloadSeconds: snapshot.idleUnloadSeconds
        )
    }
}

struct ParakeetSamplePreparationResult {
    let samples: [Float]
    let wasPadded: Bool
}

enum ParakeetSamplePreparer {
    private static let minimumDurationSeconds: Double = 1.5
    private static let sampleRate: Double = 16_000

    static func ensureMinimumDuration(samples: [Float]) -> ParakeetSamplePreparationResult {
        let minimumSamples = Int((minimumDurationSeconds * sampleRate).rounded(.up))
        guard samples.count < minimumSamples else {
            return ParakeetSamplePreparationResult(samples: samples, wasPadded: false)
        }

        let padded = samples + Array(repeating: 0, count: minimumSamples - samples.count)
        return ParakeetSamplePreparationResult(samples: padded, wasPadded: true)
    }
}
