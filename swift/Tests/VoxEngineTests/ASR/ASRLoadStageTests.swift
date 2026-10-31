import Foundation
import Testing
@testable import HudsonSpeechEngine

private final class LoadEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ASRLoadStage.Event] = []
    func append(_ event: ASRLoadStage.Event) { lock.withLock { stored.append(event) } }
    var value: [ASRLoadStage.Event] { lock.withLock { stored } }
}

struct ASRLoadStageTests {
    private enum Failure: Error { case fixture }

    @Test("Component load stages record begin/completion and separate encoder model-load from compute-plan")
    func completed() async throws {
        let events = LoadEvents()
        let value = ASRLoadStage(modelId: "parakeet:v3", component: "decoder", phase: "model-load", observe: events.append).sync { 42 }
        #expect(value == 42)
        let encoder = ASRLoadStage(modelId: "parakeet:v3", component: "encoder", phase: "compute-plan", attempt: 2, observe: events.append)
        let planned = try await encoder.measureAsync { try await Task.sleep(for: .milliseconds(1)); return true }
        #expect(planned)
        #expect(events.value.map(\.state) == ["started", "completed", "started", "completed"])
        #expect(events.value.map(\.phase) == ["model-load", "model-load", "compute-plan", "compute-plan"])
        #expect(events.value.map(\.attempt) == [1, 1, 2, 2])
        #expect(events.value.allSatisfy { $0.elapsedMs >= 0 && $0.modelId == "parakeet:v3" })
    }

    @Test("Failed sync and async phases record failure and rethrow without reflecting error bodies")
    func failed() async {
        let events = LoadEvents()
        #expect(throws: Failure.fixture) {
            try ASRLoadStage(modelId: "fixture", component: "decoder", phase: "model-load", observe: events.append).sync { throw Failure.fixture }
        }
        await #expect(throws: Failure.fixture) {
            try await ASRLoadStage(modelId: "fixture", component: "encoder", phase: "compute-plan", observe: events.append).measureAsync { throw Failure.fixture }
        }
        #expect(events.value.map(\.state) == ["started", "failed", "started", "failed"])
    }
}
