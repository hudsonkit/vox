import Darwin
import Foundation
import Testing
@testable import VoxCore

struct PrivateRuntimeCapabilityTests {
    private func paths() -> (URL, URL) {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        return (directory, directory.appendingPathComponent("runtime.json"))
    }
    private func runtime(_ directory: URL) -> RuntimeInfo {
        RuntimeInfo(version: "test", serviceName: "Vox", port: 0, pid: getpid(), startedAt: Date(),
                    socketPath: directory.appendingPathComponent("vox.sock").path)
    }

    @Test func privatePublicationRoundTripRedactsSecretsAndHoldsLease() throws {
        let (directory, url) = paths()
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = runtime(directory), token = UUID().uuidString
        let registration = try PrivateRuntimeRegistration(runtime: metadata, authToken: token, url: url)
        defer { registration.invalidate() }
        let capability = try #require(try PrivateRuntimeCapability.read(from: url))
        #expect(capability.runtime == metadata)
        #expect(capability.authToken == token)
        #expect(!String(reflecting: capability).contains(token))
        #expect(!String(describing: metadata.dictionaryValue()).contains(token))
        let data = try Data(contentsOf: url)
        #expect(try JSONDecoder().decode(RuntimeInfo.self, from: data) == metadata)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["transport"] as? String == PrivateRuntimeCapability.transport)
        #expect(json["socketPath"] as? String == metadata.socketPath)
        #expect(json["authToken"] as? String == token)
        #expect(json["port"] as? Int == 0)
        #expect(try mode(url) == 0o600)
        #expect(try mode(directory) == 0o700)
        #expect(throws: (any Error).self) {
            try PrivateRuntimeRegistration(runtime: metadata, authToken: "other", url: url)
        }
        #expect(try PrivateRuntimeCapability.read(from: url)?.instanceId == capability.instanceId)
        registration.invalidate()
        #expect(try PrivateRuntimeCapability.read(from: url) == nil)
        let next = try PrivateRuntimeRegistration(runtime: metadata, authToken: "next", url: url)
        #expect(try PrivateRuntimeCapability.read(from: url)?.instanceId != capability.instanceId)
        next.invalidate()
    }

    @Test func rejectsPublicPermissionsSymlinksHardLinksAndOversizedFiles() throws {
        let (directory, url) = paths()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cap = try PrivateRuntimeCapability(runtime: runtime(directory), authToken: "test")
        try VoxPrivateFiles.write(JSONEncoder().encode(cap), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try PrivateRuntimeCapability.read(from: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: url.path)
        #expect(throws: (any Error).self) { try PrivateRuntimeCapability.read(from: link) }
        #expect(throws: (any Error).self) { try VoxPrivateFiles.write(Data(), to: link) }
        let parentLink = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: parentLink.path, withDestinationPath: directory.path)
        #expect(throws: (any Error).self) { try PrivateRuntimeCapability.read(from: parentLink.appendingPathComponent("runtime.json")) }
        let fifo = directory.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try PrivateRuntimeCapability.read(from: fifo) }
        let hard = directory.appendingPathComponent("hard.json")
        try FileManager.default.linkItem(at: url, to: hard)
        #expect(throws: (any Error).self) { try PrivateRuntimeCapability.read(from: url) }
        #expect(throws: (any Error).self) { try VoxPrivateFiles.write(Data(), to: url) }
        try FileManager.default.removeItem(at: hard)
        try VoxPrivateFiles.write(Data(repeating: 65, count: 65537), to: url)
        #expect(throws: (any Error).self) { try PrivateRuntimeCapability.read(from: url) }
        try VoxPrivateFiles.write(JSONEncoder().encode(cap), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(throws: (any Error).self) { try PrivateRuntimeCapability.read(from: url) }
    }

    @Test func missingMalformedAndChangedOwnerRegistration() throws {
        let (directory, url) = paths()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try PrivateRuntimeCapability.read(from: url) == nil)
        let metadata = runtime(directory)
        #expect(throws: (any Error).self) { try PrivateRuntimeCapability(runtime: metadata, authToken: "") }
        let registration = try PrivateRuntimeRegistration(runtime: metadata, authToken: "first", url: url)
        let other = try PrivateRuntimeCapability(runtime: metadata, authToken: "other")
        try VoxPrivateFiles.write(JSONEncoder().encode(other), to: url)
        registration.invalidate()
        #expect(try PrivateRuntimeCapability.read(from: url) == other, "Cleanup must not remove another instance")
        try VoxPrivateFiles.write(Data("{}".utf8), to: url)
        #expect(throws: (any Error).self) { try PrivateRuntimeCapability.read(from: url) }
        let legacy = try JSONEncoder().encode(metadata)
        try VoxPrivateFiles.write(legacy, to: url)
        #expect(throws: (any Error).self) { try PrivateRuntimeCapability.read(from: url) }
    }
    @Test func legacyMigrationRefusesLiveOwnerAndReplacesOnlyStaleMetadata() throws {
        let (directory, url) = paths()
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = runtime(directory)
        let liveLegacy = RuntimeInfo(version: "old", serviceName: "Vox", port: 42137, pid: getpid(), startedAt: Date())
        let legacyBytes = try JSONEncoder().encode(liveLegacy)
        try VoxPrivateFiles.write(legacyBytes, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try PrivateRuntimeRegistration(runtime: current, authToken: "new-test-token", url: url) }
        #expect(try Data(contentsOf: url) == legacyBytes)
        #expect(try mode(url) == 0o644)
        let staleLegacy = RuntimeInfo(version: "old", serviceName: "Vox", port: 42137, pid: Int32.max, startedAt: Date())
        try JSONEncoder().encode(staleLegacy).write(to: url)
        let registration = try PrivateRuntimeRegistration(runtime: current, authToken: "new-test-token", url: url)
        defer { registration.invalidate() }
        #expect(try mode(url) == 0o600)
        #expect(try PrivateRuntimeCapability.read(from: url)?.authToken == "new-test-token")
    }

    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }
}
