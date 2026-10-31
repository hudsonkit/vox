import Foundation
import Testing
import VoxCore

@testable import HudsonSpeechEngine

private final class TestPipeline: StreamingPipeline, @unchecked Sendable {
  let spec: StreamingModelSpec
  let placement = CoreMLPlacement(
    neuralEngineOperations: 100, cpuOperations: 2, gpuOperations: 0, unknownOperations: 0,
    neuralEngineComputeOperations: 10)
  var receivedSamples = 0
  var resets = 0
  var primes = 0
  init(_ spec: StreamingModelSpec) { self.spec = spec }
  func reset() {
    receivedSamples = 0
    resets += 1
  }
  func prime() { primes += 1 }
  func append(_ samples: [Float]) -> [StreamingASRUpdate] {
    receivedSamples += samples.count
    return []
  }
  func finish() -> StreamingASRUpdate {
    StreamingASRUpdate(
      text: "hello", words: [WordTiming(word: "hello", start: 0, end: 0.1, confidence: 0.9)],
      endOfUtterance: false, endpointSource: nil, processedAudioMs: receivedSamples / 16,
      chunkLatencyMs: 0)
  }
}
private actor PipelineLoader {
  var loads = 0
  var installs = 0
  var pipeline: TestPipeline?
  func load(_ spec: StreamingModelSpec) async throws -> any StreamingPipeline {
    loads += 1
    try await Task.sleep(for: .milliseconds(30))
    let pipeline = TestPipeline(spec)
    self.pipeline = pipeline
    return pipeline
  }
  func install() { installs += 1 }
  func counts() -> (Int, Int) { (loads, installs) }
}

struct NativeStreamingASRTests {
  @Test("Production streaming inventory requires actual ANE hardware, never Simulator")
  func platformAvailability() async {
    let models = await NativeStreamingASR.shared.models()
    #expect(!models.isEmpty)
    #if arch(arm64) && !targetEnvironment(simulator)
    if #available(macOS 14.4, iOS 17.4, *) { #expect(models.allSatisfy { $0.available }) }
    else { #expect(models.allSatisfy { !$0.available }) }
    #else
    #expect(models.allSatisfy { !$0.available })
    #endif
  }

  @Test("Inventory and warmup report the actual configured idle policy")
  func idlePolicyInventory() async throws {
    let loader = PipelineLoader()
    let engine = NativeStreamingASR(
      idleSeconds: 45, loadPipeline: { spec, _, _ in try await loader.load(spec) })
    #expect(await engine.models().allSatisfy { $0.idleUnloadSeconds == 45 })
    try await engine.setIdleUnload(seconds: 0)
    let installed = try await engine.install(modelId: StreamingASRDefaults.modelId, progress: { _ in })
    #expect(installed.idleUnloadSeconds == 0)
    let ready = try await engine.preload(modelId: StreamingASRDefaults.modelId, progress: { _ in })
    #expect(ready.idleUnloadSeconds == 0)
    #expect(await engine.status().idleUnloadSeconds == 0)
    #expect(await engine.models().allSatisfy { $0.idleUnloadSeconds == 0 })
    try await engine.unload()
  }

  @Test("Concurrent explicit warmups join one install/load/prime flight")
  func serializedWarmup() async throws {
    let loader = PipelineLoader()
    let engine = NativeStreamingASR(
      loadPipeline: { spec, _, _ in try await loader.load(spec) },
      ensureInstalled: { _, _ in await loader.install() })
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<12 {
        group.addTask {
          _ = try await engine.preload(modelId: StreamingASRDefaults.modelId, progress: { _ in })
        }
      }
      try await group.waitForAll()
    }
    let (loads, installs) = await loader.counts()
    #expect(loads == 1)
    #expect(installs == 1)
    #expect(await engine.status().placement?.verified == true)
    try await engine.unload()
  }

  @Test("Install is disk-only; begin never implicitly loads")
  func explicitPreload() async throws {
    let loader = PipelineLoader()
    let engine = NativeStreamingASR(
      loadPipeline: { spec, _, _ in try await loader.load(spec) },
      ensureInstalled: { _, _ in await loader.install() })
    let info = try await engine.install(modelId: StreamingASRDefaults.modelId, progress: { _ in })
    #expect(!info.preloaded)
    #expect(await loader.counts().0 == 0)
    await #expect(throws: StreamingASRError.self) { try await engine.begin(clientId: "talkie") }
  }

  @Test("One owner, foreign finish/cancel rejected, stop flushes, cancel discards")
  func sessionOwnership() async throws {
    let loader = PipelineLoader()
    let engine = NativeStreamingASR(loadPipeline: { spec, _, _ in try await loader.load(spec) })
    _ = try await engine.preload(modelId: StreamingASRDefaults.modelId, progress: { _ in })
    let id = try await engine.begin(clientId: "talkie")
    await #expect(throws: StreamingASRError.self) { try await engine.begin(clientId: "other") }
    await #expect(throws: StreamingASRError.self) {
      try await engine.cancel(sessionId: id, clientId: "other")
    }
    await #expect(throws: StreamingASRError.self) { try await engine.unload() }
    await #expect(throws: StreamingASRError.self) {
      try await engine.preload(modelId: "parakeet:eou-320ms", progress: { _ in })
    }
    _ = try await engine.append(sessionId: id, clientId: "talkie", samples: [0.1, 0.2])
    let final = try await engine.finish(sessionId: id, clientId: "talkie")
    #expect(final.text == "hello")
    await #expect(throws: StreamingASRError.self) {
      try await engine.append(sessionId: id, clientId: "talkie", samples: [0.1])
    }
    let second = try await engine.begin(clientId: "other")
    try await engine.cancel(sessionId: second, clientId: "other")
    #expect(await engine.status().activeSessionId == nil)
    try await engine.unload()
  }

  @Test("PCM is finite and bounded; an invalid packet does not steal ownership")
  func packetBounds() async throws {
    let loader = PipelineLoader()
    let engine = NativeStreamingASR(loadPipeline: { spec, _, _ in try await loader.load(spec) })
    _ = try await engine.preload(modelId: StreamingASRDefaults.modelId, progress: { _ in })
    let id = try await engine.begin(clientId: "test")
    for samples: [Float] in [[], [.nan], [.infinity], Array(repeating: 0, count: 16001)] {
      await #expect(throws: StreamingASRError.self) {
        try await engine.append(sessionId: id, clientId: "test", samples: samples)
      }
    }
    #expect(await engine.status().activeSessionId == id)
    try await engine.cancel(sessionId: id, clientId: "test")
    try await engine.unload()
  }

  @Test("Idle eviction unloads; active sessions are pinned")
  func idleEviction() async throws {
    let loader = PipelineLoader()
    let engine = NativeStreamingASR(
      idleSeconds: 0.05, loadPipeline: { spec, _, _ in try await loader.load(spec) })
    _ = try await engine.preload(modelId: StreamingASRDefaults.modelId, progress: { _ in })
    let id = try await engine.begin(clientId: "test")
    try await Task.sleep(for: .milliseconds(90))
    #expect(await engine.status().modelId != nil)
    try await engine.cancel(sessionId: id, clientId: "test")
    try await Task.sleep(for: .milliseconds(150))
    #expect(await engine.status().modelId == nil)
    await #expect(throws: StreamingASRError.self) { try await engine.begin(clientId: "test") }
  }

  @Test("A single native residency slot evicts before switching, and refuses to steal a lease")
  func modelResidency() async throws {
    let slot = NativeASRResidency()
    actor Counter {
      var value = 0
      func increment() { value += 1 }
    }
    let counter = Counter()
    let a = try await slot.acquire(modelId: "batch", unload: { await counter.increment() })
    await #expect(throws: StreamingASRError.self) {
      try await slot.acquire(modelId: "streaming", unload: {})
    }
    #expect(await counter.value == 0)
    await slot.release(a)
    let b = try await slot.acquire(modelId: "streaming", unload: {})
    #expect(await counter.value == 1)
    await slot.release(a)  // stale release cannot unlock b
    await #expect(throws: StreamingASRError.self) {
      try await slot.acquire(modelId: "batch", unload: {})
    }
    await slot.release(b)
  }

  @Test("ANE placement requires compute on ANE, not just a cast or reshape")
  func placementPolicy() {
    #expect(
      !CoreMLPlacement(
        neuralEngineOperations: 10, cpuOperations: 100, gpuOperations: 0, unknownOperations: 0
      ).verified)
    #expect(
      !CoreMLPlacement(
        neuralEngineOperations: 100, cpuOperations: 1, gpuOperations: 0, unknownOperations: 0,
        neuralEngineComputeOperations: 10, cpuComputeOperations: 1
      ).verified)
    #expect(
      CoreMLPlacement(
        neuralEngineOperations: 100, cpuOperations: 60, gpuOperations: 0, unknownOperations: 0,
        neuralEngineComputeOperations: 342, cpuComputeOperations: 2,
        neuralEngineEstimatedCost: 0.99, cpuEstimatedCost: 0.01
      ).verified)
    #expect(
      !CoreMLPlacement(
        neuralEngineOperations: 100, cpuOperations: 60, gpuOperations: 0, unknownOperations: 0,
        neuralEngineComputeOperations: 342, cpuComputeOperations: 2, neuralEngineEstimatedCost: 0.5,
        cpuEstimatedCost: 0.5
      ).verified)
    #expect(
      CoreMLPlacement(
        neuralEngineOperations: 100, cpuOperations: 2, gpuOperations: 0, unknownOperations: 3,
        neuralEngineComputeOperations: 10
      ).verified)
  }
}
