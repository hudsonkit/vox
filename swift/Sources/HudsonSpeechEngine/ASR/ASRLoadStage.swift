import Foundation
import VoxCore

/// Instrument public Core ML load/plan phases separately. Never include URL paths,
/// request audio/text, credentials or untrusted underlying error descriptions.
struct ASRLoadStage {
    struct Event: Sendable, Equatable {
        let modelId: String
        let component: String
        let phase: String
        let state: String
        let attempt: Int
        let elapsedMs: Int
    }

    private let modelId: String
    private let component: String
    private let phase: String
    private let attempt: Int
    private let started = ContinuousClock.now
    private let observe: @Sendable (Event) -> Void

    init(
        modelId: String, component: String, phase: String, attempt: Int = 1,
        observe: @escaping @Sendable (Event) -> Void = ASRLoadStage.log
    ) {
        self.modelId = modelId
        self.component = component
        self.phase = phase
        self.attempt = attempt
        self.observe = observe
        observe(Event(modelId: modelId, component: component, phase: phase, state: "started", attempt: attempt, elapsedMs: 0))
    }

    func sync<T>(_ body: () throws -> T) rethrows -> T {
        do {
            let result = try body()
            finish("completed")
            return result
        } catch {
            finish("failed")
            throw error
        }
    }

    func measureAsync<T>(_ body: () async throws -> T) async rethrows -> T {
        do {
            let result = try await body()
            finish("completed")
            return result
        } catch {
            finish("failed")
            throw error
        }
    }

    private func finish(_ state: String) {
        let elapsed = started.duration(to: .now).components
        let ms = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        observe(Event(modelId: modelId, component: component, phase: phase, state: state, attempt: attempt, elapsedMs: ms))
    }

    private static func log(_ event: Event) {
        VoxLog.engine.info("CoreML load stage model=\(event.modelId) component=\(event.component) phase=\(event.phase) state=\(event.state) attempt=\(event.attempt) elapsedMs=\(event.elapsedMs)")
    }
}
