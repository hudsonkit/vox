import Foundation
import VoxCore

/// Instrument public Core ML load/plan phases separately. Never include URL paths,
/// request audio/text, credentials or untrusted underlying error descriptions.
struct ASRLoadStage {
    /// Domain names are allowlisted, not reflected. Error userInfo/descriptions can
    /// contain model paths, input text or credentials and must never enter logs.
    struct Failure: Sendable, Equatable {
        let domain: String
        let code: Int

        static func summarize(_ error: Error) -> [Failure] {
            var result: [Failure] = []
            var current: NSError? = error as NSError
            // Bounded even when an external NSError has a cyclic underlying chain.
            for _ in 0..<3 {
                guard let value = current else { break }
                let domains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                               NSURLErrorDomain, "com.apple.CoreML"]
                result.append(Failure(domain: domains.contains(value.domain) ? value.domain : "other", code: value.code))
                current = value.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            return result
        }
    }

    struct Event: Sendable, Equatable {
        let modelId: String
        let component: String
        let phase: String
        let state: String
        let attempt: Int
        let elapsedMs: Int
        var failures: [Failure] = []
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
            finish("failed", error: error)
            throw error
        }
    }

    func measureAsync<T>(_ body: () async throws -> T) async rethrows -> T {
        do {
            let result = try await body()
            finish("completed")
            return result
        } catch {
            finish("failed", error: error)
            throw error
        }
    }

    private func finish(_ state: String, error: Error? = nil) {
        let elapsed = started.duration(to: .now).components
        let ms = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
        observe(Event(modelId: modelId, component: component, phase: phase, state: state, attempt: attempt, elapsedMs: ms,
                      failures: error.map(Failure.summarize) ?? []))
    }

    private static func log(_ event: Event) {
        VoxLog.engine.info("CoreML load stage model=\(event.modelId) component=\(event.component) phase=\(event.phase) state=\(event.state) attempt=\(event.attempt) elapsedMs=\(event.elapsedMs)")
        for (depth, failure) in event.failures.enumerated() {
            VoxLog.engine.info("CoreML stage failure model=\(event.modelId) component=\(event.component) phase=\(event.phase) attempt=\(event.attempt) depth=\(depth) errorDomain=\(failure.domain) errorCode=\(failure.code)")
        }
    }
}
