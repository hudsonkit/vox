import Foundation
import Testing
@testable import HudsonSpeechEngine

struct ParakeetOwnedStorageTests {
    @Test("Deletion refuses symlinked owned ancestors and leaves the external target intact")
    func parentSymlink() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let sentinel = foreign.appendingPathComponent("keep")
        try Data([7]).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("models"), withDestinationURL: foreign)
        let storage = ParakeetOwnedStorage(anchor: root, parents: ["models"], manifest: .v3)
        #expect(throws: ParakeetLifecycleError.self) { try storage.remove() }
        #expect(throws: ParakeetLifecycleError.self) { try storage.prepare() }
        #expect(try Data(contentsOf: sentinel) == Data([7]))
    }
    @Test("Deletion/installation refuse a symlinked model leaf")
    func leafSymlink() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let foreign = root.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let sentinel = foreign.appendingPathComponent("keep")
        try Data([7]).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(ParakeetModelManifest.v3.cacheDirectoryName), withDestinationURL: foreign)
        let storage = ParakeetOwnedStorage(anchor: root, parents: [], manifest: .v3)
        #expect(throws: ParakeetLifecycleError.self) { try storage.remove() }
        #expect(throws: ParakeetLifecycleError.self) { try storage.prepare() }
        #expect(try Data(contentsOf: sentinel) == Data([7]))
        #expect(!FileManager.default.fileExists(atPath: foreign.appendingPathComponent("vox-parakeet.json").path))
    }
    @Test("Traversal and unknown unreceipted nonempty directories cannot be claimed or deleted")
    func unsafeNamesAndUnownedDirectory() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["..", ".", "../foreign", "/", "bad\\name", "bad\0name"] {
            let storage = ParakeetOwnedStorage(anchor: root, parents: [], manifest: manifest(name))
            #expect(throws: ParakeetLifecycleError.self) { try storage.directory() }
            #expect(throws: ParakeetLifecycleError.self) { try storage.remove() }
        }
        let storage = ParakeetOwnedStorage(anchor: root, parents: [], manifest: manifest("unowned"))
        let dir = try storage.directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sentinel = dir.appendingPathComponent("keep"); try Data([8]).write(to: sentinel)
        #expect(throws: ParakeetLifecycleError.self) { try storage.prepare() }
        #expect(throws: ParakeetLifecycleError.self) { try storage.remove() }
        #expect(try Data(contentsOf: sentinel) == Data([8]))
    }
    @Test("Receipts bind deletion to exact model/repository/revision and reject hard links")
    func receipts() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = ParakeetOwnedStorage(anchor: root, parents: [], manifest: .v3)
        try storage.prepare()
        let receipt = try storage.directory().appendingPathComponent("vox-parakeet.json")
        let original = try Data(contentsOf: receipt)
        let alias = ParakeetOwnedStorage(anchor: root, parents: [], manifest: manifest(ParakeetModelManifest.v3.cacheDirectoryName))
        #expect(throws: ParakeetLifecycleError.self) { try alias.remove() }
        #expect(throws: ParakeetLifecycleError.self) { try alias.prepare() }
        let link = root.appendingPathComponent("receipt-link")
        try FileManager.default.linkItem(at: receipt, to: link)
        #expect(throws: ParakeetLifecycleError.self) { try storage.remove() }
        try FileManager.default.removeItem(at: link)
        try Data("invalid".utf8).write(to: receipt)
        #expect(throws: ParakeetLifecycleError.self) { try storage.remove() }
        try original.write(to: receipt)
        try storage.remove()
        #expect(!FileManager.default.fileExists(atPath: try storage.directory().path))
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func manifest(_ cache: String) -> ParakeetModelManifest {
        ParakeetModelManifest(modelId: "different-model", name: "Fixture", repositoryFolderName: "fixture/repository",
            revision: "different-revision", cacheDirectoryName: cache, requiredModelFiles: [],
            vocabularyFile: "vocab.json", jointFileName: "joint.mlmodelc", tdtConfig: ParakeetTdtConfig(blankId: 0))
    }
}
