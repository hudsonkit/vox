import Foundation
import VoxCore

public protocol ASRProvider: Sendable {
    func models() async -> [ASRModelInfo]
    func install(modelId: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ASRModelInfo
    func preload(modelId: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ASRModelInfo
    func transcribe(url: URL, modelId: String) async throws -> TranscriptionOutput
}

public actor EngineManager {
    private let provider: any ASRProvider

    public init(provider: any ASRProvider = NativeASRProvider()) {
        self.provider = provider
    }

    public func models() async -> [ASRModelInfo] {
        await provider.models()
    }

    public func install(
        modelId: String,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        try await provider.install(modelId: modelId, progress: progress)
    }

    public func preload(
        modelId: String,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        try await provider.preload(modelId: modelId, progress: progress)
    }

    public func transcribe(url: URL, modelId: String) async throws -> TranscriptionOutput {
        try await provider.transcribe(url: url, modelId: modelId)
    }
}

/// Default embedded native engine: batch Parakeet for files; explicit streaming models for live PCM.
public struct NativeASRProvider: ASRProvider {
    private let batch = ParakeetProvider()
    public init() {}
    private func provider(_ modelId: String) -> any ASRProvider {
        if StreamingModelSpec.all.contains(where: { $0.id == modelId }) { return NativeStreamingASR.shared }
        return batch
    }
    public func models() async -> [ASRModelInfo] { await batch.models() + NativeStreamingASR.shared.models() }
    public func install(modelId: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ASRModelInfo {
        try await provider(modelId).install(modelId: modelId, progress: progress)
    }
    public func preload(modelId: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws -> ASRModelInfo {
        try await provider(modelId).preload(modelId: modelId, progress: progress)
    }
    public func transcribe(url: URL, modelId: String) async throws -> TranscriptionOutput { try await provider(modelId).transcribe(url: url, modelId: modelId) }
}
