import Foundation
import Testing

@testable import HudsonSpeechEngine

struct StreamingModelStoreTests {
  @Test(
    "Disk validation rejects missing, truncated, stale and incomplete receipts without compiling Core ML"
  )
  func validation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let spec = try StreamingModelSpec.resolve("nemotron:streaming-560ms")
    let store = StreamingModelStore(spec: spec, root: root)
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    #expect(!store.isInstalled())
    var files: [String: Int] = [:]
    for artifact in spec.artifacts.keys {
      let paths =
        artifact.hasSuffix(".mlmodelc")
        ? ["coremldata.bin", "model.mil", "weights/weight.bin"].map { artifact + "/" + $0 }
        : [artifact]
      for path in paths {
        let url = store.directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2]).write(to: url)
        files[path] = 2
      }
    }
    let receipt = store.directory.appendingPathComponent("vox-install.json")
    func write(revision: String, files: [String: Int]) throws {
      try JSONSerialization.data(withJSONObject: ["revision": revision, "files": files]).write(
        to: receipt)
    }
    try write(revision: spec.revision, files: files)
    #expect(store.isInstalled())  // Placeholder bytes prove this does not compile or load.
    try write(revision: "stale", files: files)
    #expect(!store.isInstalled())
    try write(revision: spec.revision, files: [spec.vocabulary: 2])
    #expect(!store.isInstalled())
    try write(revision: spec.revision, files: files)
    try Data([1]).write(to: store.directory.appendingPathComponent(spec.vocabulary))
    #expect(!store.isInstalled())
  }
}
