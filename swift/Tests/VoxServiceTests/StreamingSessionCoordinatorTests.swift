import Foundation
import Testing
import VoxCore

@testable import VoxService

private actor FakeStreamingEngine: StreamingSessionEngine {
  var id: UUID?
  var cancelled = 0
  func begin(clientId: String, modelId: String, route: String) -> UUID {
    let id = UUID()
    self.id = id
    return id
  }
  func append(sessionId: UUID, clientId: String, samples: [Float]) -> [StreamingASRUpdate] { [] }
  func finish(sessionId: UUID, clientId: String) -> StreamingASRUpdate {
    id = nil
    return StreamingASRUpdate(
      text: "final", words: [], endOfUtterance: false, endpointSource: nil, processedAudioMs: 0,
      chunkLatencyMs: 0)
  }
  func cancel(sessionId: UUID, clientId: String) {
    id = nil
    cancelled += 1
  }
  func activeSessionID() -> UUID? { id }
}
struct StreamingSessionCoordinatorTests {
  @Test("Connection AND client own PCM streaming; sequence acknowledgements enforce backpressure")
  func ownershipAndSequence() async throws {
    let engine = FakeStreamingEngine()
    let coordinator = StreamingSessionCoordinator(engine: FakeStreamingEngine())
    let id = try await coordinator.start(connectionID: "a", clientId: "talkie", modelId: "test")
    await #expect(throws: StreamingASRError.self) {
      try await coordinator.start(connectionID: "b", clientId: "other", modelId: "test")
    }
    await #expect(throws: StreamingASRError.self) {
      try await coordinator.append(
        id: id, connectionID: "b", clientId: "talkie", sequence: 0, samples: [0.1])
    }
    await #expect(throws: StreamingASRError.self) {
      try await coordinator.finish(id: id, connectionID: "a", clientId: "other")
    }
    _ = try await coordinator.append(
      id: id, connectionID: "a", clientId: "talkie", sequence: 0, samples: [0.1])
    await #expect(throws: StreamingASRError.self) {
      try await coordinator.append(
        id: id, connectionID: "a", clientId: "talkie", sequence: 0, samples: [0.1])
    }
    _ = try await coordinator.append(
      id: id, connectionID: "a", clientId: "talkie", sequence: 1, samples: [0.1])
    let final = try await coordinator.finish(id: id, connectionID: "a", clientId: "talkie")
    #expect(final.text == "final")
    _ = engine
  }
  @Test("Disconnect cancels only its own session and releases the model lease")
  func disconnect() async throws {
    let engine = FakeStreamingEngine()
    let coordinator: StreamingSessionCoordinator
    coordinator = StreamingSessionCoordinator(engine: engine)
    let id = try await coordinator.start(connectionID: "a", clientId: "talkie", modelId: "test")
    await coordinator.disconnect(connectionID: "b")
    #expect(await engine.activeSessionID() == id)
    await coordinator.disconnect(connectionID: "a")
    #expect(await engine.activeSessionID() == nil)
    #expect(await engine.cancelled == 1)
    _ = try await coordinator.start(connectionID: "b", clientId: "other", modelId: "test")
    await coordinator.shutdown()
    #expect(await engine.cancelled == 2)
  }
  @Test("Wire PCM validates length, endianness, finite samples, and a one-second bound")
  func pcm() throws {
    #expect(try StreamingPCM.decode("AACAPwAAAL8=") == [1, -0.5])
    for invalid in [
      "", "invalid!", "AA==", Data(repeating: 0, count: 64004).base64EncodedString(), "AADAfw==",
    ] {
      #expect(throws: StreamingASRError.self) { try StreamingPCM.decode(invalid) }
    }
  }
}
