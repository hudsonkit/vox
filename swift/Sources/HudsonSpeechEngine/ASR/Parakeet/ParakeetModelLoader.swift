@preconcurrency import CoreML
import Foundation
import VoxCore

struct ParakeetModelURLs: Sendable {
    let preprocessor: URL
    let encoder: URL
    let decoder: URL
    let joint: URL
    let vocabulary: URL
}

struct ParakeetLoadedModels: Sendable {
    let modelId: String
    let preprocessor: MLModel
    let encoder: MLModel
    let decoder: MLModel
    let joint: MLModel
    let configuration: MLModelConfiguration
    let vocabulary: [Int: String]
    let placement: CoreMLPlacement
}

struct ParakeetModelLoader: Sendable {
    let manifest: ParakeetModelManifest

    init(manifest: ParakeetModelManifest = .v3) {
        self.manifest = manifest
    }

    func modelURLs(in directory: URL) -> ParakeetModelURLs {
        ParakeetModelURLs(
            preprocessor: directory.appendingPathComponent("Preprocessor.mlmodelc", isDirectory: true),
            encoder: directory.appendingPathComponent("Encoder.mlmodelc", isDirectory: true),
            decoder: directory.appendingPathComponent("Decoder.mlmodelc", isDirectory: true),
            joint: directory.appendingPathComponent(manifest.jointFileName, isDirectory: true),
            vocabulary: directory.appendingPathComponent(manifest.vocabularyFile)
        )
    }

    func loadModels(from directory: URL) async throws -> ParakeetLoadedModels {
        let urls = modelURLs(in: directory)
        let preprocessor = try ASRLoadStage(modelId: manifest.modelId, component: "preprocessor", phase: "model-load").sync {
            try MLModel(
                contentsOf: urls.preprocessor,
                configuration: modelConfiguration(computeUnits: .cpuOnly)
            )
        }
        let (encoder, placement) = try await CoreMLPlacement.loadEncoder(url: urls.encoder, modelId: manifest.modelId)
        let decoder = try ASRLoadStage(modelId: manifest.modelId, component: "decoder", phase: "model-load").sync {
            try MLModel(
                contentsOf: urls.decoder,
                configuration: modelConfiguration(computeUnits: .cpuAndNeuralEngine)
            )
        }
        let joint = try ASRLoadStage(modelId: manifest.modelId, component: "joint", phase: "model-load").sync {
            try MLModel(
                contentsOf: urls.joint,
                configuration: modelConfiguration(computeUnits: .cpuAndNeuralEngine)
            )
        }
        let vocabulary = try ASRLoadStage(modelId: manifest.modelId, component: "vocabulary", phase: "read").sync {
            try ParakeetVocabulary.load(from: urls.vocabulary)
        }
        let configuration = modelConfiguration(computeUnits: .cpuAndNeuralEngine)

        return ParakeetLoadedModels(
            modelId: manifest.modelId,
            preprocessor: preprocessor,
            encoder: encoder,
            decoder: decoder,
            joint: joint,
            configuration: configuration,
            vocabulary: vocabulary,
            placement: placement
        )
    }

    private func modelConfiguration(computeUnits: MLComputeUnits) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        configuration.allowLowPrecisionAccumulationOnGPU = true
        return configuration
    }
}
