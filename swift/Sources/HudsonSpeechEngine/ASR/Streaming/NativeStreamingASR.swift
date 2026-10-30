import Foundation
import VoxCore

public struct NativeStreamingStatus: Codable, Sendable, Equatable {
  public let modelId: String?
  public let loadingModelId: String?
  public let placement: CoreMLPlacement?
  public let activeSessionId: UUID?
  public let clientId: String?
  public let idleUnloadSeconds: Double
}

/// Process-wide native streaming ASR. One loaded pipeline, one session owner, bounded PCM input.
/// Apps with several processes should share this instance through voxd's authenticated Unix transport.
public actor NativeStreamingASR: ASRProvider {
  public static let shared = NativeStreamingASR()
  private var pipeline: (any StreamingPipeline)?
  private var language = "en-US"
  private var flight:
    (id: UUID, modelId: String, language: String, directory: URL?, task: Task<Void, Error>)?
  private var idleTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var idleSeconds: Double
  private var owner: (id: UUID, clientId: String, started: Date, route: String)?
  private let performance = PerformanceRecorder()
  private let loadPipeline:
    @Sendable (StreamingModelSpec, URL, String) async throws -> any StreamingPipeline
  private let ensureInstalled:
    @Sendable (StreamingModelSpec, @escaping @Sendable (ModelProgress) -> Void) async throws -> Void
  private let managesResidency: Bool
  private var inferenceMs = 0.0
  private var residencyLease: UUID?

  private init() {
    loadPipeline = { try await StreamingCoreMLPipeline.load(spec: $0, directory: $1, language: $2) }
    ensureInstalled = { try await StreamingModelStore(spec: $0).install(progress: $1) }
    managesResidency = true
    let configured =
      ProcessInfo.processInfo.environment["VOX_ASR_IDLE_SECONDS"].flatMap(Double.init)
      ?? StreamingASRDefaults.idleUnloadSeconds
    idleSeconds =
      configured.isFinite && configured >= 0 ? configured : StreamingASRDefaults.idleUnloadSeconds
  }

  /// Test seam: use the production lifecycle without downloading or compiling models.
  init(
    idleSeconds: Double = 60,
    loadPipeline:
      @escaping @Sendable (StreamingModelSpec, URL, String) async throws -> any StreamingPipeline,
    ensureInstalled:
      @escaping @Sendable (StreamingModelSpec, @escaping @Sendable (ModelProgress) -> Void)
      async throws -> Void = { _, _ in }
  ) {
    self.idleSeconds = idleSeconds
    self.loadPipeline = loadPipeline
    self.ensureInstalled = ensureInstalled
    managesResidency = false
  }

  public func status() -> NativeStreamingStatus {
    NativeStreamingStatus(
      modelId: pipeline?.spec.id, loadingModelId: flight?.modelId, placement: pipeline?.placement,
      activeSessionId: owner?.id, clientId: owner?.clientId, idleUnloadSeconds: idleSeconds)
  }

  /// Zero disables idle eviction. Active sessions and warmup are never evicted.
  public func setIdleUnload(seconds: Double) throws {
    guard seconds.isFinite, seconds >= 0 else {
      throw StreamingASRError.unavailable("Invalid idle unload timeout")
    }
    idleSeconds = seconds
    scheduleIdle()
  }

  public func models() async -> [ASRModelInfo] {
    StreamingModelSpec.all.map { spec in
      ASRModelInfo(
        id: spec.id, name: spec.name, backend: "coreml-streaming",
        installed: StreamingModelStore(spec: spec).isInstalled(),
        preloaded: pipeline?.spec.id == spec.id, available: Self.available,
        computePlacement: pipeline?.spec.id == spec.id ? pipeline?.placement : nil)
    }
  }

  private static var available: Bool {
    #if arch(arm64)
      if #available(macOS 14.4, iOS 17.4, *) { return true }
    #endif
    return false
  }

  public func install(modelId: String, progress: @escaping @Sendable (ModelProgress) -> Void)
    async throws -> ASRModelInfo
  {
    try await warm(
      modelId: modelId, language: "en-US", directory: nil, installOnly: true, progress: progress)
  }
  public func preload(modelId: String, progress: @escaping @Sendable (ModelProgress) -> Void)
    async throws -> ASRModelInfo
  {
    try await warm(
      modelId: modelId, language: "en-US", directory: nil, installOnly: false, progress: progress)
  }
  /// Explicit offline bundle support. No download takes place when directory is supplied.
  public func preload(
    modelId: String = StreamingASRDefaults.modelId, directory: URL? = nil,
    language: String = "en-US", progress: @escaping @Sendable (ModelProgress) -> Void = { _ in }
  ) async throws -> ASRModelInfo {
    try await warm(
      modelId: modelId, language: language, directory: directory, installOnly: false,
      progress: progress)
  }

  private func warm(
    modelId: String, language: String, directory: URL?, installOnly: Bool,
    progress: @escaping @Sendable (ModelProgress) -> Void
  ) async throws -> ASRModelInfo {
    guard !managesResidency || Self.available else {
      throw StreamingASRError.unavailable(
        "Native streaming requires Apple Silicon and macOS 14.4 / iOS 17.4")
    }
    let spec = try StreamingModelSpec.resolve(modelId)
    guard owner == nil else { throw StreamingASRError.busy }
    idleTask?.cancel()
    idleTask = nil
    if let current = flight {
      guard current.modelId == modelId, current.language == language, current.directory == directory
      else { throw StreamingASRError.busy }
      try await current.task.value
      try Task.checkCancellation()
      if flight?.id == current.id { flight = nil }
      if installOnly || (pipeline?.spec.id == modelId && self.language == language) {
        scheduleIdle()
        return ASRModelInfo(
          id: modelId, name: spec.name, backend: "coreml-streaming", installed: true,
          preloaded: pipeline?.spec.id == modelId, available: true,
          computePlacement: pipeline?.spec.id == modelId ? pipeline?.placement : nil)
      }
      // An install-only flight is not a preload: re-check readiness after joining.
      return try await warm(
        modelId: modelId, language: language, directory: directory, installOnly: installOnly,
        progress: progress)
    }
    if !installOnly, pipeline?.spec.id == modelId, self.language == language {
      progress(ModelProgress(modelId: modelId, progress: 1, status: "ready"))
      scheduleIdle()
      return ASRModelInfo(
        id: modelId, name: spec.name, backend: "coreml-streaming", installed: true, preloaded: true,
        available: true, computePlacement: pipeline?.spec.id == modelId ? pipeline?.placement : nil)
    }
    let flightID = UUID()
    let task = Task {
      try await self.initialize(
        spec: spec, directory: directory, language: language, installOnly: installOnly,
        progress: progress)
    }
    flight = (flightID, modelId, language, directory, task)
    do {
      try await task.value
      if flight?.id == flightID { flight = nil }
      scheduleIdle()
      try Task.checkCancellation()
      return ASRModelInfo(
        id: modelId, name: spec.name, backend: "coreml-streaming", installed: true,
        preloaded: pipeline?.spec.id == modelId, available: true,
        computePlacement: pipeline?.spec.id == modelId ? pipeline?.placement : nil)
    } catch {
      if flight?.id == flightID { flight = nil }
      scheduleIdle()
      throw error
    }
  }

  private func initialize(
    spec: StreamingModelSpec, directory: URL?, language: String, installOnly: Bool,
    progress: @escaping @Sendable (ModelProgress) -> Void
  ) async throws {
    let store = StreamingModelStore(spec: spec)
    if directory == nil { try await ensureInstalled(spec, progress) }
    if installOnly {
      progress(ModelProgress(modelId: spec.id, progress: 1, status: "installed"))
      return
    }
    let lease =
      managesResidency
      ? try await NativeASRResidency.shared.acquire(
        modelId: spec.id, unload: { [weak self] in await self?.evict() }) : nil
    do {
      // Clear the prior model before loading another one. Never hold two encoder instances.
      pipeline = nil
      progress(ModelProgress(modelId: spec.id, progress: 0.85, status: "loading"))
      let loaded = try await loadPipeline(spec, directory ?? store.directory, language)
      progress(ModelProgress(modelId: spec.id, progress: 0.95, status: "warming"))
      try loaded.prime()
      pipeline = loaded
      self.language = language
      progress(ModelProgress(modelId: spec.id, progress: 1, status: "ready"))
      if let lease { await NativeASRResidency.shared.release(lease) }
    } catch {
      if let lease { await NativeASRResidency.shared.release(lease) }
      throw error
    }
  }

  private func evict() {
    idleTask?.cancel()
    idleTask = nil
    pipeline = nil
  }

  /// Requires explicit preload, does not download or warm a model as a launch side effect.
  public func begin(
    clientId: String, modelId: String = StreamingASRDefaults.modelId,
    route: String = "transcribe.streaming"
  ) async throws -> UUID {
    guard owner == nil, flight == nil else { throw StreamingASRError.busy }
    guard pipeline?.spec.id == modelId else { throw StreamingASRError.notReady }
    idleTask?.cancel()
    idleTask = nil
    let lease: UUID?
    do {
      lease =
        managesResidency
        ? try await NativeASRResidency.shared.acquire(
          modelId: modelId, unload: { [weak self] in await self?.evict() }) : nil
    } catch {
      scheduleIdle()
      throw error
    }
    guard let pipeline, pipeline.spec.id == modelId else {
      if let lease { await NativeASRResidency.shared.release(lease) }
      throw StreamingASRError.notReady
    }
    do { try pipeline.reset() } catch {
      if let lease { await NativeASRResidency.shared.release(lease) }
      throw error
    }
    residencyLease = lease
    idleTask?.cancel()
    idleTask = nil
    let id = UUID()
    owner = (id, clientId, Date(), route)
    inferenceMs = 0
    // Orphaned embedded sessions cannot retain the model indefinitely.
    timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(120))
        await self?.expire(id: id)
      } catch {}
    }
    return id
  }

  public func append(sessionId: UUID, clientId: String, samples: [Float]) throws
    -> [StreamingASRUpdate]
  {
    try requireOwner(sessionId, clientId)
    guard !samples.isEmpty, samples.count <= 16000, samples.allSatisfy(\.isFinite) else {
      throw StreamingASRError.invalidAudio
    }
    let updates = try pipeline!.append(samples)
    inferenceMs += updates.reduce(0) { $0 + $1.chunkLatencyMs }
    return updates
  }

  public func finish(sessionId: UUID, clientId: String, recordPerformance: Bool = true) async throws
    -> StreamingASRUpdate
  {
    try requireOwner(sessionId, clientId)
    let current = owner!
    let modelId = pipeline!.spec.id
    let samples = pipeline!.receivedSamples
    let start = Date()
    let update: StreamingASRUpdate
    do { update = try pipeline!.finish() } catch {
      await clearOwner()
      throw error
    }
    inferenceMs += Date().timeIntervalSince(start) * 1000
    let metrics = TranscriptionMetrics(
      traceId: sessionId.uuidString, audioDurationMs: samples / 16, inputBytes: samples * 4,
      wasPreloaded: true, fileCheckMs: 0, modelCheckMs: 0, modelLoadMs: 0, audioLoadMs: 0,
      audioPrepareMs: 0, inferenceMs: Int(inferenceMs),
      totalMs: Int(Date().timeIntervalSince(current.started) * 1000))
    await clearOwner()
    if recordPerformance {
      await performance.record(
        PerformanceSample(
          clientId: clientId, route: current.route, modelId: modelId, outcome: "ok",
          textLength: update.text.count, metrics: metrics.performanceMetrics))
    }
    return update
  }

  /// Discards pending PCM and text. Does not flush or emit a final transcript.
  public func cancel(sessionId: UUID, clientId: String) async throws {
    try requireOwner(sessionId, clientId)
    await clearOwner()
  }
  public func unload() throws {
    guard owner == nil, flight == nil else { throw StreamingASRError.busy }
    idleTask?.cancel()
    idleTask = nil
    pipeline = nil
  }
  private func requireOwner(_ id: UUID, _ clientId: String) throws {
    guard owner?.id == id, owner?.clientId == clientId else {
      throw StreamingASRError.invalidSession
    }
  }
  private func clearOwner() async {
    timeoutTask?.cancel()
    timeoutTask = nil
    owner = nil
    do { try pipeline?.reset() } catch { pipeline = nil }
    if let lease = residencyLease {
      residencyLease = nil
      await NativeASRResidency.shared.release(lease)
    }
    scheduleIdle()
  }
  private func expire(id: UUID) async {
    guard owner?.id == id else { return }
    VoxLog.engine.warning(
      "Native streaming session timed out session=\(id) client=\(owner!.clientId) model=\(pipeline?.spec.id ?? "unknown") route=\(owner!.route)"
    )
    await clearOwner()
  }
  private func scheduleIdle() {
    idleTask?.cancel()
    idleTask = nil
    guard idleSeconds > 0, owner == nil, flight == nil, pipeline != nil else { return }
    let seconds = idleSeconds
    idleTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(seconds))
        try await self?.unload()
      } catch {}
    }
  }

  public func transcribe(url: URL, modelId: String) async throws -> TranscriptionOutput {
    let totalStarted = Date()
    let wasPreloaded = pipeline?.spec.id == modelId
    let loaded = try ParakeetAudioLoader().load(from: url)
    let loadStarted = Date()
    _ = try await preload(modelId: modelId, progress: { _ in })
    let modelLoadMs = wasPreloaded ? 0 : Int(Date().timeIntervalSince(loadStarted) * 1000)
    let id = try await begin(clientId: "file", modelId: modelId, route: "transcribe.file")
    do {
      let start = Date()
      for offset in stride(from: 0, to: loaded.samples.count, by: 16000) {
        _ = try append(
          sessionId: id, clientId: "file",
          samples: Array(loaded.samples[offset..<min(offset + 16000, loaded.samples.count)]))
      }
      let result = try await finish(sessionId: id, clientId: "file", recordPerformance: false)
      let elapsed = Int(Date().timeIntervalSince(start) * 1000)
      let metrics = TranscriptionMetrics(
        traceId: id.uuidString, audioDurationMs: loaded.audioDurationMs,
        inputBytes: loaded.inputBytes, wasPreloaded: wasPreloaded, fileCheckMs: 0, modelCheckMs: 0,
        modelLoadMs: modelLoadMs, audioLoadMs: loaded.audioLoadMs, audioPrepareMs: 0, inferenceMs: elapsed,
        totalMs: Int(Date().timeIntervalSince(totalStarted) * 1000))
      return TranscriptionOutput(
        modelId: modelId, text: result.text, elapsedMs: metrics.totalMs, metrics: metrics,
        words: result.words)
    } catch {
      try? await cancel(sessionId: id, clientId: "file")
      throw error
    }
  }
}
