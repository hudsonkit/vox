import Foundation
import HudsonSpeechEngine
import VoxCore

/// App-captured PCM streaming. The authenticated connection AND clientId own the session.
/// One acknowledged packet in flight per session; never enqueue unbounded audio tasks.
protocol StreamingSessionEngine: Sendable {
  func begin(clientId: String, modelId: String, route: String) async throws -> UUID
  func append(sessionId: UUID, clientId: String, samples: [Float]) async throws
    -> [StreamingASRUpdate]
  func finish(sessionId: UUID, clientId: String) async throws -> StreamingASRUpdate
  func cancel(sessionId: UUID, clientId: String) async throws
  func activeSessionID() async -> UUID?
}
extension NativeStreamingASR: StreamingSessionEngine {
  func finish(sessionId: UUID, clientId: String) async throws -> StreamingASRUpdate {
    try await finish(sessionId: sessionId, clientId: clientId, recordPerformance: true)
  }
  func activeSessionID() async -> UUID? { status().activeSessionId }
}

actor StreamingSessionCoordinator {
  private struct Owner {
    let connectionID: String
    let clientId: String
    let generation: UUID
    var id: UUID?
    var sequence = 0
    var inFlight = false
  }
  private var owner: Owner?
  private let engine: any StreamingSessionEngine
  init(engine: any StreamingSessionEngine = NativeStreamingASR.shared) { self.engine = engine }

  func start(connectionID: String, clientId: String, modelId: String) async throws -> UUID {
    // Recover ownership after the engine's bounded orphan-session timeout.
    if let current = owner, current.id != nil, !current.inFlight,
      await engine.activeSessionID() == nil, owner?.generation == current.generation
    {
      owner = nil
    }
    guard owner == nil, !clientId.isEmpty else { throw StreamingASRError.busy }
    let generation = UUID()
    owner = Owner(connectionID: connectionID, clientId: clientId, generation: generation)
    do {
      let id = try await engine.begin(
        clientId: clientId, modelId: modelId, route: "transcribe.streaming")
      guard owner?.generation == generation else {
        try? await engine.cancel(sessionId: id, clientId: clientId)
        throw StreamingASRError.invalidSession
      }
      owner?.id = id
      return id
    } catch {
      if owner?.generation == generation { owner = nil }
      throw error
    }
  }

  func append(id: UUID, connectionID: String, clientId: String, sequence: Int, samples: [Float])
    async throws -> [StreamingASRUpdate]
  {
    try validate(id, connectionID, clientId)
    guard owner?.inFlight == false else { throw StreamingASRError.busy }
    guard owner?.sequence == sequence else {
      throw StreamingASRError.unavailable("streaming_asr_sequence: expected \(owner!.sequence)")
    }
    guard !samples.isEmpty, samples.count <= 16000, samples.allSatisfy(\.isFinite) else {
      throw StreamingASRError.invalidAudio
    }
    owner?.inFlight = true
    do {
      let updates = try await engine.append(sessionId: id, clientId: clientId, samples: samples)
      try validate(id, connectionID, clientId)
      owner?.sequence += 1
      owner?.inFlight = false
      return updates
    } catch {
      if owner?.id == id { owner = nil }
      try? await engine.cancel(sessionId: id, clientId: clientId)
      throw error
    }
  }

  func finish(id: UUID, connectionID: String, clientId: String) async throws -> StreamingASRUpdate {
    try validate(id, connectionID, clientId)
    guard owner?.inFlight == false else { throw StreamingASRError.busy }
    owner?.inFlight = true
    do {
      let result = try await engine.finish(sessionId: id, clientId: clientId)
      try validate(id, connectionID, clientId)
      owner = nil
      return result
    } catch {
      if owner?.id == id { owner = nil }
      throw error
    }
  }

  func cancel(id: UUID, connectionID: String, clientId: String) async throws {
    try validate(id, connectionID, clientId)
    owner = nil
    do { try await engine.cancel(sessionId: id, clientId: clientId) } catch StreamingASRError
      .invalidSession
    {
      // Finish or timeout may have released the native owner across the await.
      // This caller owned the coordinator; clearing it still suppresses a late final.
    }
  }
  func disconnect(connectionID: String) async {
    guard let current = owner, current.connectionID == connectionID else { return }
    owner = nil
    if let id = current.id { try? await engine.cancel(sessionId: id, clientId: current.clientId) }
  }
  func shutdown() async {
    guard let connectionID = owner?.connectionID else { return }
    await disconnect(connectionID: connectionID)
  }
  private func validate(_ id: UUID, _ connectionID: String, _ clientId: String) throws {
    guard owner?.id == id, owner?.connectionID == connectionID, owner?.clientId == clientId else {
      throw StreamingASRError.invalidSession
    }
  }
}

/// Wire audio is explicitly little-endian IEEE float32, not platform-dependent memory layout.
enum StreamingPCM {
  static func decode(_ base64: String) throws -> [Float] {
    guard base64.utf8.count <= 85_336, let data = Data(base64Encoded: base64), !data.isEmpty,
      data.count <= 64_000, data.count.isMultiple(of: 4)
    else { throw StreamingASRError.invalidAudio }
    var samples: [Float] = []
    samples.reserveCapacity(data.count / 4)
    for offset in stride(from: 0, to: data.count, by: 4) {
      let bits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
      let value = Float(bitPattern: UInt32(littleEndian: bits))
      guard value.isFinite else { throw StreamingASRError.invalidAudio }
      samples.append(value)
    }
    return samples
  }
}
