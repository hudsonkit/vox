import Foundation
import VoxCore

protocol ParakeetRuntime: Sendable {
    var isAvailable: Bool { get }
    func beginUse() async
    func endUse() async
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
    let idleUnloadSeconds: Double
}

struct ParakeetInferenceResult: Sendable {
    let text: String
    let words: [WordTiming]
}
