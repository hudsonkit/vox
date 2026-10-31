import Darwin
import Foundation
import Testing
import VoxCore
@testable import HudsonSpeechEngine

struct AnnotationStagingTests {
    @Test("OS-granted temporary scope does not require capability-safe filesystem ancestors")
    func grantedRootInsteadOfAncestorWalk() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let ancestor = base.appendingPathComponent("sandbox-ancestor")
        let root = ancestor.appendingPathComponent("granted-tmp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: ancestor.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        // This boundary is intentionally still strict for daemon capability files.
        #expect(throws: POSIXError.self) { try VoxPrivateFiles.prepareDirectory(root.appendingPathComponent("capability")) }
        let staged = try AnnotationStagingFile.create(in: root)
        let fd = try staged.openOutput(); close(fd)
        #expect(try mode(staged.directory) == 0o700)
        #expect(try mode(staged.url) == 0o600)
        staged.remove()
        #expect(try mode(ancestor) == 0o777)
        #expect(try mode(root) == 0o700)
    }

    @Test("Staging only creates its own exclusive private leaf and cleans idempotently")
    func privateLeaf() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try mode(root)
        let stage = try AnnotationStagingFile.create(in: root)
        let fd = try stage.openOutput()
        #expect(write(fd, "test", 4) == 4); close(fd)
        #expect(try Data(contentsOf: stage.url) == Data("test".utf8))
        #expect(try mode(stage.directory) == 0o700 && mode(stage.url) == 0o600)
        #expect(throws: POSIXError.self) { _ = try stage.openOutput() }
        stage.remove(); stage.remove()
        #expect(!FileManager.default.fileExists(atPath: stage.directory.path))
        #expect(try mode(root) == before)
    }

    @Test("Payload symlinks are refused and cleanup unlinks only the alias, never its target")
    func payloadAlias() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("sentinel")
        try Data([42]).write(to: sentinel)
        let stage = try AnnotationStagingFile.create(in: root)
        try FileManager.default.createSymbolicLink(at: stage.url, withDestinationURL: sentinel)
        #expect(throws: POSIXError.self) { _ = try stage.openOutput() }
        stage.remove()
        #expect(try Data(contentsOf: sentinel) == Data([42]))
    }

    @Test("Descriptor cleanup cannot remove a replacement directory at its old path")
    func replacementSafeCleanup() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let stage = try AnnotationStagingFile.create(in: root)
        let fd = try stage.openOutput(); close(fd)
        let moved = root.appendingPathComponent("moved-owned-leaf")
        try FileManager.default.moveItem(at: stage.directory, to: moved)
        try FileManager.default.createDirectory(at: stage.directory, withIntermediateDirectories: false)
        let sentinel = stage.directory.appendingPathComponent("keep")
        try Data([7]).write(to: sentinel)
        stage.remove()
        #expect(try Data(contentsOf: sentinel) == Data([7]))
        #expect(!FileManager.default.fileExists(atPath: moved.appendingPathComponent("upload.bin").path))
    }

    @Test("Staging release cleans payload even when caller abandons the helper")
    func referenceRelease() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var stage: AnnotationStagingFile? = try AnnotationStagingFile.create(in: root)
        let directory = stage!.directory
        let fd = try stage!.openOutput(); close(fd)
        stage = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("The trusted-root leaf cannot itself be a symlink")
    func rootAlias() throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real"), alias = base.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        #expect(throws: POSIXError.self) { _ = try AnnotationStagingFile.create(in: alias) }
    }

    private func fixture() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory
        guard let pointer = realpath(temporary.path, nil) else { throw POSIXError(.EIO) }
        defer { free(pointer) }
        let root = URL(fileURLWithPath: String(cString: pointer), isDirectory: true).appendingPathComponent("vox-staging-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func mode(_ url: URL) throws -> Int {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return (values[.posixPermissions] as! NSNumber).intValue
    }
}
