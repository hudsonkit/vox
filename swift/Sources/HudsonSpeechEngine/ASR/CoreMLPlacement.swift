@preconcurrency import CoreML
import Foundation
import VoxCore

extension CoreMLPlacement {
  @available(macOS 14.4, iOS 17.4, *)
  static func read(url: URL, configuration: MLModelConfiguration) async throws -> CoreMLPlacement {
    let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
    var ane = 0
    var cpu = 0
    var gpu = 0
    var unknown = 0
    var aneCompute = 0
    var cpuCompute = 0
    var aneCost = 0.0
    var cpuCost = 0.0
    func count(_ usage: MLComputePlan.DeviceUsage?, compute: Bool = false, cost: Double = 0) {
      guard let usage else {
        unknown += 1
        return
      }
      switch usage.preferred {
      case .neuralEngine:
        ane += 1
        aneCost += cost
        if compute { aneCompute += 1 }
      case .cpu:
        cpu += 1
        cpuCost += cost
        if compute { cpuCompute += 1 }
      case .gpu: gpu += 1
      @unknown default: unknown += 1
      }
    }
    func walk(_ block: MLModelStructure.Program.Block) {
      for operation in block.operations {
        // Constants have no scheduled device; do not count them as unknown placement.
        let name =
          operation.operatorName.split(separator: ".").last.map(String.init)
          ?? operation.operatorName
        if name != "const" {
          count(
            plan.deviceUsage(for: operation), compute: ["conv", "linear", "matmul"].contains(name),
            cost: plan.estimatedCost(of: operation)?.weight ?? 0)
        }
        for child in operation.blocks { walk(child) }
      }
    }
    func walkStructure(_ structure: MLModelStructure) {
      switch structure {
      case .program(let program):
        for function in program.functions.values { walk(function.block) }
      case .neuralNetwork(let network):
        for layer in network.layers { count(plan.deviceUsage(for: layer)) }
      case .pipeline(let pipeline):
        for child in pipeline.subModels { walkStructure(child) }
      case .unsupported: unknown += 1
      @unknown default: unknown += 1
      }
    }
    walkStructure(plan.modelStructure)
    return CoreMLPlacement(
      neuralEngineOperations: ane, cpuOperations: cpu, gpuOperations: gpu,
      unknownOperations: unknown, neuralEngineComputeOperations: aneCompute,
      cpuComputeOperations: cpuCompute, neuralEngineEstimatedCost: aneCost,
      cpuEstimatedCost: cpuCost)
  }

  /// Reject CPU fallback, retrying one fresh load before failing closed.
  static func loadEncoder(url: URL, modelId: String) async throws -> (MLModel, CoreMLPlacement) {
    guard #available(macOS 14.4, iOS 17.4, *) else {
      throw StreamingASRError.unavailable(
        "Verified ANE placement requires macOS 14.4 / iOS 17.4 or newer")
    }
    for attempt in 1...2 {
      let config = MLModelConfiguration()
      config.computeUnits = .cpuAndNeuralEngine
      var model: MLModel? = try await ASRLoadStage(modelId: modelId, component: "encoder", phase: "model-load", attempt: attempt).measureAsync {
        try NativePreparationResources.check(modelId: modelId, phase: "encoder-model-load")
        return try await MLModel.load(contentsOf: url, configuration: config)
      }
      let placement = try await ASRLoadStage(modelId: modelId, component: "encoder", phase: "compute-plan", attempt: attempt).measureAsync {
        try NativePreparationResources.check(modelId: modelId, phase: "encoder-compute-plan")
        return try await read(url: url, configuration: config)
      }
      VoxLog.engine.info(
        "CoreML placement model=\(modelId) attempt=\(attempt) ane=\(placement.neuralEngineOperations) cpu=\(placement.cpuOperations) gpu=\(placement.gpuOperations) unknown=\(placement.unknownOperations) aneCompute=\(placement.neuralEngineComputeOperations) cpuCompute=\(placement.cpuComputeOperations) aneCostFraction=\(placement.neuralEngineCostFraction ?? 0)"
      )
      if placement.verified, let model { return (model, placement) }
      model = nil  // Release the failed instance before retrying; never keep a CPU duplicate.
      VoxLog.engine.warning(
        "Encoder ANE placement failed model=\(modelId); \(attempt == 1 ? "retrying" : "refusing CPU fallback")"
      )
    }
    throw StreamingASRError.unavailable(
      "Encoder has no verified Neural Engine placement after two loads: \(modelId)")
  }
}
