import Foundation
import VoxCore

protocol ParakeetRuntime: Sendable {
    var isAvailable: Bool { get }
    func snapshot() async -> ParakeetRuntimeSnapshot
    func unload() async throws
    func setIdleUnload(seconds: Double) async throws
    func computePlacement() async -> CoreMLPlacement?
    func isPreloaded() async -> Bool
    func load(from directory: URL, progress: @escaping @Sendable (ModelProgress) -> Void) async throws
    func transcribe(samples: [Float]) async throws -> ParakeetInferenceResult
}

struct ParakeetRuntimeSnapshot: Sendable {
    let preloaded: Bool
    let placement: CoreMLPlacement?
}

struct ParakeetInferenceResult: Sendable {
    let text: String
    let words: [WordTiming]
}

extension ParakeetRuntime {
    func snapshot() async -> ParakeetRuntimeSnapshot {
        ParakeetRuntimeSnapshot(preloaded: await isPreloaded(), placement: await computePlacement())
    }
    func unload() async throws { throw ParakeetLifecycleError.unsupported }
    func setIdleUnload(seconds: Double) async throws { throw ParakeetLifecycleError.unsupported }
    func computePlacement() async -> CoreMLPlacement? { nil }
}
