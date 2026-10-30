import Foundation

public struct CoreMLPlacement: Codable, Sendable, Equatable {
  public let neuralEngineOperations: Int
  public let cpuOperations: Int
  public let gpuOperations: Int
  public let unknownOperations: Int
  public let neuralEngineComputeOperations: Int
  public let cpuComputeOperations: Int
  public let neuralEngineEstimatedCost: Double
  public let cpuEstimatedCost: Double
  public var neuralEngineCostFraction: Double? {
    let total = neuralEngineEstimatedCost + cpuEstimatedCost
    return total > 0 ? neuralEngineEstimatedCost / total : nil
  }
  /// Small CPU pre-encode convolutions are valid; reject a mostly-CPU encoder.
  public var verified: Bool {
    neuralEngineComputeOperations > 0 && gpuOperations == 0
      && (cpuComputeOperations == 0 || (neuralEngineCostFraction ?? 0) >= 0.95)
  }

  public init(
    neuralEngineOperations: Int, cpuOperations: Int, gpuOperations: Int, unknownOperations: Int,
    neuralEngineComputeOperations: Int = 0, cpuComputeOperations: Int = 0,
    neuralEngineEstimatedCost: Double = 0, cpuEstimatedCost: Double = 0
  ) {
    self.neuralEngineOperations = neuralEngineOperations
    self.cpuOperations = cpuOperations
    self.gpuOperations = gpuOperations
    self.unknownOperations = unknownOperations
    self.neuralEngineComputeOperations = neuralEngineComputeOperations
    self.cpuComputeOperations = cpuComputeOperations
    self.neuralEngineEstimatedCost = neuralEngineEstimatedCost
    self.cpuEstimatedCost = cpuEstimatedCost
  }
  public func dictionaryValue() -> [String: Any] {
    [
      "neuralEngineOperations": neuralEngineOperations,
      "cpuOperations": cpuOperations,
      "gpuOperations": gpuOperations,
      "unknownOperations": unknownOperations,
      "neuralEngineComputeOperations": neuralEngineComputeOperations,
      "cpuComputeOperations": cpuComputeOperations,
      "neuralEngineEstimatedCost": neuralEngineEstimatedCost,
      "cpuEstimatedCost": cpuEstimatedCost,
      "verified": verified,
    ]
  }

}
