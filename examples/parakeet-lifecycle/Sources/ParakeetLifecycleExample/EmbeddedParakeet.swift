import Foundation
import VoxCore
import VoxEngine

/// File ASR inside the Apple app. No daemon, client transport or external loader.
/// This example intentionally fixes batch selection to Parakeet v3.
public actor EmbeddedParakeet {
    public let modelId = "parakeet:v3"
    private let batch = ParakeetProvider()
    public init() {}

    public func inventory() async -> [ASRModelInfo] { await batch.models() }
    public func modelDirectory() throws -> URL { try batch.modelDirectory(modelId: modelId) }
    public func download(progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ASRModelInfo {
        try await batch.install(modelId: modelId, progress: progress)
    }
    public func prepare(progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ASRModelInfo {
        try await batch.preload(modelId: modelId, progress: progress)
    }
    public func transcribe(fileURL: URL) async throws -> TranscriptionOutput {
        try await batch.transcribe(url: fileURL, modelId: modelId)
    }
    public func unload() async throws -> ASRModelInfo { try await batch.unload(modelId: modelId) }
    public func deleteOwnedModel() async throws -> ASRModelInfo { try await batch.deleteModel(modelId: modelId) }
    public func setIdleUnload(seconds: Double) async throws { try await batch.setIdleUnload(modelId: modelId, seconds: seconds) }
}
