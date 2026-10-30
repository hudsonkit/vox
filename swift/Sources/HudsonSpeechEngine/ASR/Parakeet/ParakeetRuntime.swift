import Foundation
import VoxCore

protocol ParakeetRuntime: Sendable {
    var isAvailable: Bool { get }
    func computePlacement() async -> CoreMLPlacement?
    func isPreloaded() async -> Bool
    func load(from directory: URL, progress: @escaping @Sendable (ModelProgress) -> Void) async throws
    func transcribe(samples: [Float]) async throws -> ParakeetInferenceResult
}

struct ParakeetInferenceResult: Sendable {
    let text: String
    let words: [WordTiming]
}

extension ParakeetRuntime {
    func computePlacement() async -> CoreMLPlacement? { nil }
}
