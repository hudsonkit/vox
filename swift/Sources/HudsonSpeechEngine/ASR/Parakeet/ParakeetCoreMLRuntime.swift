import Foundation
import VoxCore

actor ParakeetCoreMLRuntime: ParakeetRuntime {
    struct Session: Sendable {
        let placement: CoreMLPlacement?
        let transcribe: @Sendable ([Float]) async throws -> ParakeetInferenceResult
        init(placement: CoreMLPlacement? = nil, transcribe: @escaping @Sendable ([Float]) async throws -> ParakeetInferenceResult) {
            self.placement = placement; self.transcribe = transcribe
        }
    }

    enum Event: String, Sendable {
        case loadRequested, loadStarted, loadJoined, sessionLoaded, primingStarted, primingFinished, ready, loadFailed
        case transcriptionJoinedLoad, sessionReleased
    }

    private let log = VoxLog.engine
    private let modelId: String
    private let inferenceConfig: ParakeetInferenceConfig
    private let loadSession: @Sendable (URL) async throws -> Session
    private let observeEvent: @Sendable (Event) -> Void
    private var session: Session?
    private var idleTask: Task<Void, Never>?
    private var activeTranscriptions = 0
    private var operationReservations = 0
    private var unloading = false
    private var idleSeconds: Double
    private let managesResidency: Bool
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
            let models = try await loader.loadModels(from: directory)
            let singleChunkTranscriber = ParakeetSingleChunkTranscriber(models: models, config: config)
            return Session(placement: models.placement) { samples in
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
        self.managesResidency = true
        let configured = ProcessInfo.processInfo.environment["VOX_ASR_IDLE_SECONDS"].flatMap(Double.init) ?? StreamingASRDefaults.idleUnloadSeconds
        self.idleSeconds = configured.isFinite && configured >= 0 ? configured : StreamingASRDefaults.idleUnloadSeconds
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
        self.managesResidency = false
        self.idleSeconds = 0
    }

    nonisolated var isAvailable: Bool {
        if !managesResidency { return true } // injected session fixture, not a Core ML capability claim
        #if arch(arm64) && !targetEnvironment(simulator)
        if #available(macOS 14.4, iOS 17.4, *) { return true }
        #endif
        return false
    }

    func isPreloaded() async -> Bool {
        session != nil
    }

    func load(from directory: URL, progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        try Task.checkCancellation()
        guard !unloading else { throw ParakeetLifecycleError.busy }
        guard !managesResidency || isAvailable else { throw StreamingASRError.unavailable("Parakeet ANE inference requires Apple Silicon and macOS 14.4 / iOS 17.4 hardware") }
        event(.loadRequested)
        if session != nil {
            scheduleIdle()
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
        var lease: UUID?
        do {
            if managesResidency {
                lease = try await NativeASRResidency.shared.acquire(modelId: modelId, unload: { [weak self] in await self?.evict() })
            }
            publishProgress(0.85, status: "loading", flightID: flightID)
            var loadedSession: Session? = try await loadSession(directory)
            event(.sessionLoaded)
            publishProgress(0.95, status: "warming", flightID: flightID)
            event(.primingStarted)
            await prime(session: loadedSession!)
            event(.primingFinished)
            // Readiness includes priming. Keep the session local across the
            // suspension so another call cannot use or replace it mid-warmup.
            session = loadedSession
            loadedSession = nil // Only the resident slot owns the model before releasing its lease.
            publishProgress(1.0, status: "ready", flightID: flightID)
            if let lease { await NativeASRResidency.shared.release(lease) }
            loadFlight = nil
            event(.ready)
            scheduleIdle()
        } catch {
            if let lease { await NativeASRResidency.shared.release(lease) }
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
        guard !unloading else { throw ParakeetLifecycleError.busy }
        if let flight = loadFlight {
            event(.transcriptionJoinedLoad)
            try await flight.task.value
        }
        try Task.checkCancellation()
        // Check readiness without capturing a model across a residency-acquire await.
        guard session != nil else { throw notInitialized() }
        idleTask?.cancel(); idleTask = nil
        activeTranscriptions += 1
        var lease: UUID?
        do {
            if managesResidency {
                lease = try await NativeASRResidency.shared.acquire(modelId: modelId, unload: { [weak self] in await self?.evict() })
            }
            guard session != nil else { throw notInitialized() }
            var activeSession = session
            let result = try await activeSession!.transcribe(samples)
            activeSession = nil // Do not retain a second model through the release await.
            activeTranscriptions -= 1
            if let lease { await NativeASRResidency.shared.release(lease) }
            scheduleIdle()
            return result
        } catch {
            activeTranscriptions -= 1
            if let lease { await NativeASRResidency.shared.release(lease) }
            scheduleIdle()
            throw error
        }
    }

    private func notInitialized() -> NSError {
        NSError(domain: "VoxEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "Parakeet runtime is not initialized."])
    }

    func beginUse() async {
        operationReservations += 1
        idleTask?.cancel(); idleTask = nil
    }
    func endUse() async {
        operationReservations -= 1
        scheduleIdle()
    }
    func unload() async throws {
        guard !unloading, operationReservations == 0, activeTranscriptions == 0, loadFlight == nil else { throw ParakeetLifecycleError.busy }
        unloading = true
        idleTask?.cancel(); idleTask = nil
        defer { unloading = false }
        if managesResidency {
            do { try await NativeASRResidency.shared.unload(modelId: modelId) }
            catch { throw ParakeetLifecycleError.busy }
        }
        evict() // Also clear an already nonresident session; metadata actors may stay cached.
    }
    func setIdleUnload(seconds: Double) async throws {
        guard seconds.isFinite, seconds >= 0 else { throw ParakeetLifecycleError.invalidIdleTimeout }
        idleSeconds = seconds
        idleTask?.cancel(); idleTask = nil
        scheduleIdle()
    }

    func snapshot() async -> ParakeetRuntimeSnapshot { ParakeetRuntimeSnapshot(preloaded: session != nil, placement: session?.placement) }
    func computePlacement() async -> CoreMLPlacement? { session?.placement }
    private func evict() {
        let hadSession = session != nil
        idleTask?.cancel(); idleTask = nil; session = nil
        if hadSession { event(.sessionReleased) }
    }
    private func evictIfIdle() {
        guard !unloading, operationReservations == 0, activeTranscriptions == 0, loadFlight == nil else { return }
        evict()
    }
    private func scheduleIdle() {
        guard !unloading, operationReservations == 0, activeTranscriptions == 0, loadFlight == nil, session != nil else { return }
        idleTask?.cancel()
        let seconds = idleSeconds
        guard seconds.isFinite, seconds > 0 else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)); await self?.evictIfIdle() } catch { }
        }
    }

    private func event(_ event: Event) {
        log.debug("Parakeet runtime model=\(modelId) event=\(event.rawValue)")
        observeEvent(event)
    }
}
