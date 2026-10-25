import Foundation
import VoxCore

actor ParakeetCoreMLRuntime: ParakeetRuntime {
    struct Session: Sendable {
        let transcribe: @Sendable ([Float]) async throws -> ParakeetInferenceResult
    }

    enum Event: String, Sendable {
        case loadRequested, loadStarted, loadJoined, sessionLoaded, primingStarted, primingFinished, ready, loadFailed
        case transcriptionJoinedLoad
    }

    private let log = VoxLog.engine
    private let modelId: String
    private let inferenceConfig: ParakeetInferenceConfig
    private let loadSession: @Sendable (URL) async throws -> Session
    private let observeEvent: @Sendable (Event) -> Void
    private var session: Session?
    private struct LoadFlight {
        let id: UUID
        let task: Task<Void, Error>
        var progress: ModelProgress
        var observers: [@Sendable (ModelProgress) -> Void]
    }
    private var loadFlight: LoadFlight?

    init(
        manifest: ParakeetModelManifest = .v3,
        modelLoader: ParakeetModelLoader? = nil
    ) {
        self.modelId = manifest.modelId
        self.inferenceConfig = manifest.inferenceConfig
        let loader = modelLoader ?? ParakeetModelLoader(manifest: manifest)
        let config = manifest.inferenceConfig
        self.loadSession = { directory in
            let models = try loader.loadModels(from: directory)
            let singleChunkTranscriber = ParakeetSingleChunkTranscriber(models: models, config: config)
            return Session { samples in
                if samples.count <= ParakeetConstants.maxModelSamples {
                    VoxLog.engine.info("Using Vox-owned single-chunk Parakeet runtime")
                    return try await singleChunkTranscriber.transcribe(samples: samples)
                }
                VoxLog.engine.info("Using Vox-owned long-form Parakeet chunk processor")
                return try await ParakeetChunkProcessor(
                    audioSamples: samples,
                    workerCount: max(1, config.parallelChunkConcurrency),
                    transcriberFactory: {
                        ParakeetSingleChunkTranscriber(models: models, config: config)
                    }
                ).process()
            }
        }
        self.observeEvent = { _ in }
    }

    /// Replaces Core ML work while exercising the production runtime lifecycle.
    init(
        manifest: ParakeetModelManifest = .v3,
        loadSession: @escaping @Sendable (URL) async throws -> Session,
        observeEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.modelId = manifest.modelId
        self.inferenceConfig = manifest.inferenceConfig
        self.loadSession = loadSession
        self.observeEvent = observeEvent
    }

    nonisolated var isAvailable: Bool {
        true
    }

    func isPreloaded() async -> Bool {
        session != nil
    }

    func load(from directory: URL, progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        try Task.checkCancellation()
        event(.loadRequested)
        if session != nil {
            progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
            event(.ready)
            return
        }

        let task: Task<Void, Error>
        if var flight = loadFlight {
            flight.observers.append(progress)
            loadFlight = flight
            progress(flight.progress)
            event(.loadJoined)
            task = flight.task
        } else {
            let id = UUID()
            // The shared task owns initialization. Canceling a caller must not
            // cancel another caller's warmup or leave a half-initialized runtime.
            task = Task { try await self.initialize(from: directory, flightID: id) }
            loadFlight = LoadFlight(
                id: id,
                task: task,
                progress: ModelProgress(modelId: modelId, progress: 0.85, status: "loading"),
                observers: [progress]
            )
            event(.loadStarted)
        }
        try await task.value
        try Task.checkCancellation()
    }

    private func initialize(from directory: URL, flightID: UUID) async throws {
        do {
            publishProgress(0.85, status: "loading", flightID: flightID)
            let loadedSession = try await loadSession(directory)
            event(.sessionLoaded)
            publishProgress(0.95, status: "warming", flightID: flightID)
            event(.primingStarted)
            await prime(session: loadedSession)
            event(.primingFinished)
            // Readiness includes priming. Keep the session local across the
            // suspension so another call cannot use or replace it mid-warmup.
            session = loadedSession
            publishProgress(1.0, status: "ready", flightID: flightID)
            loadFlight = nil
            event(.ready)
        } catch {
            loadFlight = nil
            event(.loadFailed)
            throw error
        }
    }

    private func publishProgress(_ value: Double, status: String, flightID: UUID) {
        guard var flight = loadFlight, flight.id == flightID else { return }
        flight.progress = ModelProgress(modelId: modelId, progress: value, status: status)
        loadFlight = flight
        for observer in flight.observers {
            observer(flight.progress)
        }
    }

    /// Runs the long-form path once on silence, with every chunk worker busy.
    ///
    /// Loading a model does not prepare it for the Neural Engine. Each parallel
    /// prediction stream is compiled on first use, about 30 s apiece when the
    /// system cache is cold, so without this the first dictation longer than
    /// 15 s pays for every compile while the user waits.
    private func prime(session: Session) async {
        let started = Date()
        let chunks = max(1, inferenceConfig.parallelChunkConcurrency) + 1
        let silence = [Float](repeating: 0, count: ParakeetConstants.maxModelSamples * chunks)
        do {
            _ = try await session.transcribe(silence)
            log.info("Parakeet primed in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        } catch {
            log.warning("Parakeet priming failed: \(error.localizedDescription)")
        }
    }

    func transcribe(samples: [Float]) async throws -> ParakeetInferenceResult {
        // Providers load first, but direct callers that arrive during warmup
        // must also wait for the complete shared initialization flight.
        if let flight = loadFlight {
            event(.transcriptionJoinedLoad)
            try await flight.task.value
        }
        try Task.checkCancellation()
        guard let session else {
            throw NSError(domain: "VoxEngine", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Parakeet runtime is not initialized."
            ])
        }

        return try await session.transcribe(samples)
    }

    private func event(_ event: Event) {
        log.debug("Parakeet runtime model=\(modelId) event=\(event.rawValue)")
        observeEvent(event)
    }
}
