import Foundation
import VoxCore

struct StreamingModelSpec: Sendable {
  enum Architecture: Sendable { case nemotron, eou, unified }
  let id: String
  let name: String
  let repository: String
  let revision: String
  let folder: String
  let architecture: Architecture
  let encoder: String
  let windowSamples: Int
  let shiftSamples: Int
  let validFrames: Int
  var isUnified: Bool { architecture == .unified }
  var isEOU: Bool { architecture == .eou }
  var preprocessor: String {
    isEOU ? "parakeet_eou_preprocessor.mlmodelc" : "preprocessor.mlmodelc"
  }
  var vocabulary: String { (isEOU || isUnified) ? "vocab.json" : "tokenizer.json" }
  var joint: String {
    isUnified
      ? "nemotron_unified_joint_decision_single_step.mlmodelc"
      : (isEOU ? "joint_decision.mlmodelc" : "decoder_joint.mlmodelc")
  }
  var decoder: String { isUnified ? "nemotron_unified_decoder.mlmodelc" : "decoder.mlmodelc" }
  var artifacts: [String: String] {
    var files = [
      encoder: "\(folder)/\(encoder)", preprocessor: "\(folder)/\(preprocessor)",
      joint: "\(folder)/\(joint)", vocabulary: "\(folder)/\(vocabulary)",
    ]
    if isEOU {
      files["decoder.mlmodelc"] = "\(folder)/decoder.mlmodelc"
      files[preprocessor] = "160ms/\(preprocessor)"  // identical front-end, only 160 ms bundle includes it
    } else {
      files["metadata.json"] = "\(folder)/metadata.json"
      if isUnified { files[decoder] = "\(folder)/\(decoder)" }
    }
    return files
  }
  static let all: [StreamingModelSpec] = [
    .init(
      id: "nemotron:unified-560ms", name: "Nemotron Labs Unified 560 ms",
      repository: "FluidInference/nemotron-labs-unified-asr-0.6b-coreml",
      revision: "bd13ddde81d3134719c520845346b3252daf3175", folder: "coreml",
      architecture: .unified, encoder: "nemotron_unified_encoder_streaming_70_2_5_int8.mlmodelc",
      windowSamples: 98560, shiftSamples: 2560, validFrames: 2),
    .init(
      id: "nemotron:streaming-560ms", name: "Nemotron 3.5 Streaming Latin 560 ms",
      repository: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
      revision: "1a41b75758b0337ff67db7d5408280aaaf23074e", folder: "latin/560ms",
      architecture: .nemotron, encoder: "encoder.mlmodelc", windowSamples: 8960, shiftSamples: 8960,
      validFrames: 7),
    .init(
      id: "nemotron:en-streaming-560ms", name: "Nemotron English Streaming 560 ms",
      repository: "FluidInference/nemotron-speech-streaming-en-0.6b-coreml",
      revision: "e673531caa6d25ab7baf5a8c14c9b99ba1551838", folder: "nemotron_coreml_560ms",
      architecture: .nemotron, encoder: "encoder/encoder_int8.mlmodelc", windowSamples: 8960,
      shiftSamples: 8960, validFrames: 7),
    .init(
      id: "parakeet:eou-320ms", name: "Parakeet Realtime EOU 120M 320 ms",
      repository: "FluidInference/parakeet-realtime-eou-120m-coreml",
      revision: "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355", folder: "320ms", architecture: .eou,
      encoder: "streaming_encoder.mlmodelc", windowSamples: 10080, shiftSamples: 5120,
      validFrames: 4),
    .init(
      id: "parakeet:eou-160ms", name: "Parakeet Realtime EOU 120M 160 ms",
      repository: "FluidInference/parakeet-realtime-eou-120m-coreml",
      revision: "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355", folder: "160ms", architecture: .eou,
      encoder: "streaming_encoder.mlmodelc", windowSamples: 2560, shiftSamples: 1280, validFrames: 2
    ),
  ]
  static func resolve(_ id: String) throws -> StreamingModelSpec {
    guard let spec = all.first(where: { $0.id == id }) else {
      throw StreamingASRError.unavailable("Unknown native streaming model: \(id)")
    }
    return spec
  }
}

/// Installation checks inspect file metadata only. They never instantiate or compile Core ML models.
struct StreamingModelStore: Sendable {
  let spec: StreamingModelSpec
  private let root: URL?
  init(spec: StreamingModelSpec, root: URL? = nil) {
    self.spec = spec
    self.root = root
  }
  var directory: URL {
    (root ?? RuntimePaths.modelsDirectoryURL())
      .appendingPathComponent(spec.id.replacingOccurrences(of: ":", with: "-"))
  }
  private struct Receipt: Codable {
    let revision: String
    let files: [String: Int]
  }
  private var receipt: URL { directory.appendingPathComponent("vox-install.json") }
  func isInstalled() -> Bool {
    guard let data = try? Data(contentsOf: receipt),
      let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
      receipt.revision == spec.revision, !receipt.files.isEmpty
    else { return false }
    let files = receipt.files
    for artifact in spec.artifacts.keys {
      if artifact.hasSuffix(".mlmodelc") {
        for suffix in ["coremldata.bin", "model.mil", "weights/weight.bin"]
        where files[artifact + "/" + suffix] == nil { return false }
      } else if files[artifact] == nil {
        return false
      }
    }
    return files.allSatisfy { path, bytes in
      guard bytes > 0, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
        let attributes = try? FileManager.default.attributesOfItem(
          atPath: directory.appendingPathComponent(path).path),
        let size = attributes[.size] as? NSNumber
      else { return false }
      return size.intValue == bytes
    }
  }
  func install(progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
    if isInstalled() { return }
    let fm = FileManager.default
    let staging = directory.deletingLastPathComponent().appendingPathComponent(
      ".\(UUID().uuidString)")
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    var files: [(remote: String, local: String, size: Int, repository: String, revision: String)] =
      []
    func walk(remote: String, local: String, repository: String, revision: String) async throws {
      let items = try await VoxModelHub.listDirectory(
        repoPath: repository, path: remote, revision: revision)
      for item in items {
        guard let path = item["path"] as? String, path.hasPrefix(remote + "/"),
          !path.split(separator: "/").contains("..")
        else { throw VoxModelHubError.invalidResponse }
        let relative = local + String(path.dropFirst(remote.count))
        if item["type"] as? String == "directory" {
          try await walk(remote: path, local: relative, repository: repository, revision: revision)
        } else if item["type"] as? String == "file", let size = item["size"] as? Int, size > 0 {
          files.append((path, relative, size, repository, revision))
        }
      }
    }
    for (local, remote) in spec.artifacts.sorted(by: { $0.key < $1.key }) {
      if spec.isUnified && local == spec.preprocessor {
        try await walk(
          remote: "nemotron_coreml_560ms/preprocessor.mlmodelc", local: local,
          repository: "FluidInference/nemotron-speech-streaming-en-0.6b-coreml",
          revision: "e673531caa6d25ab7baf5a8c14c9b99ba1551838")
      } else if local.hasSuffix(".mlmodelc") {
        try await walk(
          remote: remote, local: local, repository: spec.repository, revision: spec.revision)
      } else {
        files.append((remote, local, -1, spec.repository, spec.revision))
      }
    }
    var sizes: [String: Int] = [:]
    for (index, file) in files.enumerated() {
      try Task.checkCancellation()
      let destination = staging.appendingPathComponent(file.local)
      try await VoxModelHub.downloadFile(
        repoPath: file.repository, remotePath: file.remote, to: destination, revision: file.revision
      )
      let size =
        (try fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
      guard size > 0, file.size < 0 || file.size == size else {
        throw VoxModelHubError.invalidResponse
      }
      sizes[file.local] = size
      progress(
        ModelProgress(
          modelId: spec.id, progress: Double(index + 1) / Double(files.count), status: "installing")
      )
    }
    for model in spec.artifacts.keys where model.hasSuffix(".mlmodelc") {
      guard sizes[model + "/coremldata.bin"] != nil, sizes[model + "/model.mil"] != nil,
        sizes[model + "/weights/weight.bin"] != nil
      else { throw VoxModelHubError.modelNotFound(path: model) }
    }
    try JSONEncoder().encode(Receipt(revision: spec.revision, files: sizes)).write(
      to: staging.appendingPathComponent("vox-install.json"), options: .atomic)
    if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
    try fm.moveItem(at: staging, to: directory)
  }
}
