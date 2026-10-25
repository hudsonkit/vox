import Darwin
import Foundation
import XCTest
@testable import VoxService

final class PrivateTransportTests: XCTestCase {
    func testAdmissionBoundsAndConnectionOwnership() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("voice.sock").path
        let token = String(repeating: "a", count: 43)
        let disconnected = expectation(description: "connection cleanup")
        let bridge = ServiceBridge(port: 0, serviceName: "PrivateTest", authToken: token, socketPath: path)
        bridge.handle("identity") { params, reply in reply(["owner": params?["_connectionID"] as? String ?? ""], nil) }
        bridge.onClientDisconnected = { _ in disconnected.fulfill() }
        try bridge.start()
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(try mode(path), 0o600)
        XCTAssertEqual(try mode(directory.path), 0o700)
        let idle = try connect(path); defer { close(idle) }
        let duplicate = ServiceBridge(port: 0, serviceName: "Duplicate", authToken: token, socketPath: path)
        XCTAssertThrowsError(try duplicate.start())
        for headers in ["", "x-lattices-token: wrong\r\n", "x-lattices-token: \(token)\r\nOrigin: https://evil.test\r\n", "x-lattices-token: \(token)\r\nx-lattices-token: \(token)\r\n", "x-lattices-token: \(token)\r\nContent-Length: 1\r\n"] {
            let fd = try connect(path); defer { close(fd) }
            let response = try upgrade(fd, headers: headers)
            XCTAssertTrue(response.isEmpty || response.hasPrefix("HTTP/1.1 403"))
        }
        let peer = try connect(path)
        XCTAssertTrue(try upgrade(peer, headers: "x-lattices-token: \(token)\r\n").hasPrefix("HTTP/1.1 101"))
        let one = try call(peer)
        let two = try call(peer)
        XCTAssertFalse(one.isEmpty); XCTAssertNotEqual(one, "spoofed"); XCTAssertEqual(one, two)
        assertPrivateDescriptorsCloseOnExec(path, excluding: [idle, peer], minimum: 3)
        let malformed: [UInt8] = [0x81, 0xFF] + Array(repeating: 0xFF, count: 8)
        _ = malformed.withUnsafeBytes { write(peer, $0.baseAddress, $0.count) }
        var byte: UInt8 = 0
        XCTAssertEqual(read(peer, &byte, 1), 0)
        close(peer)
        wait(for: [disconnected], timeout: 2)
        let fresh = try connect(path); defer { close(fresh) }
        XCTAssertTrue(try upgrade(fresh, headers: "x-lattices-token: \(token)\r\n").hasPrefix("HTTP/1.1 101"))
        bridge.onClientDisconnected = nil
    }

    func testStopClosesAcceptedDescriptorsAndAllowsRestart() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let path = directory.appendingPathComponent("voice.sock").path
        let token = String(repeating: "a", count: 43)
        let bridge = ServiceBridge(port: 0, serviceName: "ShutdownTest", authToken: token, socketPath: path)
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        for _ in 0..<3 {
            let disconnected = expectation(description: "shutdown releases session")
            bridge.onClientDisconnected = { _ in disconnected.fulfill() }
            try bridge.start()
            let peer = try connect(path)
            XCTAssertTrue(try upgrade(peer, headers: "x-lattices-token: \(token)\r\n").hasPrefix("HTTP/1.1 101"))
            bridge.stop()
            var byte: UInt8 = 0
            XCTAssertEqual(read(peer, &byte, 1), 0, "Accepted sockets must close even after the server is released")
            close(peer)
            wait(for: [disconnected], timeout: 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testUnsafePathsAndMissingCredentialFailClosed() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try VoxPrivateIPC.prepareDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try VoxPrivateIPC.writePrivateFile(Data("keep".utf8), to: target)
        let link = directory.appendingPathComponent("voice.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let server = ServiceBridge(port: 0, serviceName: "Denied", authToken: String(repeating: "x", count: 43), socketPath: link.path)
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        XCTAssertThrowsError(try VoxPrivateIPC.writePrivateFile(Data("secret".utf8), to: link))
        XCTAssertThrowsError(try ServiceBridge(port: 0, serviceName: "NoAuth", socketPath: directory.appendingPathComponent("new.sock").path).start())
    }

    private func mode(_ path: String) throws -> Int { (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue }
    private func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in path.utf8CString.withUnsafeBytes { dest.copyBytes(from: $0) } }
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }
    private func upgrade(_ fd: Int32, headers: String) throws -> String {
        let request = Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\(headers)\r\n".utf8)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var bytes = [UInt8](repeating: 0, count: 8192); let count = read(fd, &bytes, bytes.count)
        return count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
    }
    private func call(_ fd: Int32) throws -> String {
        let data = Array(#"{"id":"test","method":"identity","params":{"_connectionID":"spoofed"}}"#.utf8)
        let frame: [UInt8] = [0x81, 0x80 | UInt8(data.count), 0, 0, 0, 0] + data
        _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var bytes = [UInt8](repeating: 0, count: 4096); let count = read(fd, &bytes, bytes.count)
        guard count >= 2, bytes[1] < 126 else { throw POSIXError(.EPROTO) }
        let object = try JSONSerialization.jsonObject(with: Data(bytes[2..<count])) as? [String: Any]
        return (object?["result"] as? [String: Any])?["owner"] as? String ?? ""
    }
}

// Inspect live descriptors, including both ends of the real client/server
// transport, so child processes cannot retain its listeners or locks.
private func assertPrivateDescriptorsCloseOnExec(_ path: String, excluding: Set<Int32> = [], minimum: Int = 2) {
    var matching = 0
    var lockInfo = stat()
    let hasLock = lstat(path + ".lock", &lockInfo) == 0
    for fd in 0..<getdtablesize() where !excluding.contains(fd) {
        let flags = fcntl(fd, F_GETFD)
        if flags < 0 { continue }
        var matches = false
        for peer in [false, true] {
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    peer ? getpeername(fd, $0, &length) : getsockname(fd, $0, &length)
                }
            }
            if result == 0, address.sun_family == sa_family_t(AF_UNIX) {
                let name = withUnsafeBytes(of: address.sun_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                matches = matches || name == path
            }
        }
        var info = stat()
        if hasLock, fstat(fd, &info) == 0, info.st_dev == lockInfo.st_dev, info.st_ino == lockInfo.st_ino { matches = true }
        if matches {
            matching += 1
            XCTAssertNotEqual(flags & FD_CLOEXEC, 0, "Private IPC descriptor \(fd) leaks across exec")
        }
    }
    XCTAssertGreaterThanOrEqual(matching, minimum)
}
