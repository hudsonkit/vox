import Darwin
import Foundation
import Testing
@testable import VoxClient
import VoxService

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}

private final class Fixture {
    let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
    let token = UUID().uuidString
    let bridge: ServiceBridge
    var path: String { directory.appendingPathComponent("vox.sock").path }
    init() throws {
        bridge = ServiceBridge(port: 0, serviceName: "ClientTest", authToken: token,
                               socketPath: directory.appendingPathComponent("vox.sock").path)
        try bridge.start()
    }
    var endpoint: VoxEndpoint { .unix(socketPath: path, authToken: token) }
    deinit { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
}

struct VoxClientTests {
    @Test func privateRPCProgressOwnershipAndConcurrentRequests() async throws {
        let f = try Fixture(), events = Recorder()
        f.bridge.handleStreaming("prepare") { params, progress, reply in
            progress("models.progress", ["stage": "loading"])
            reply(["owner": params?["_connectionID"] as? String ?? "", "clientId": params?["clientId"] as? String ?? ""], nil)
        }
        let client = VoxDaemonClient(clientId: "talkie")
        try await client.connect(f.endpoint)
        let first = try await client.call("prepare", params: ["clientId": "spoof", "_connectionID": "spoof"]) {
            events.append($0.event)
        }
        #expect(first["clientId"] == "talkie")
        #expect(first["owner"] != "spoof")
        #expect(events.snapshot == ["models.progress"])
        async let a = client.call("prepare")
        async let b = client.call("prepare")
        let (second, third) = try await (a, b)
        #expect(first["owner"] == second["owner"])
        #expect(second["owner"] == third["owner"])
        await client.disconnect()
        #expect(await client.isConnected == false)
    }

    @Test func runtimeServicePublishesCapabilityAndRollsBackAConflictingPublisher() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("runtime.json"), token = UUID().uuidString
        let socket = directory.appendingPathComponent("vox.sock").path
        let preferences: @Sendable () -> VoxPreferences = {
            VoxPreferences(speech: VoxSpeechPreferences(modelDownloadPolicy: .never))
        }
        let service = VoxRuntimeService(port: 0, authToken: token, socketPath: socket,
                                        privateCapabilityURL: file, preferencesLoader: preferences)
        try service.start(); defer { service.stop() }
        let endpoint = try VoxEndpoint.discovered(environment: ["VOX_RUNTIME_PATH": file.path])
        let client = VoxDaemonClient(clientId: "talkie")
        try await client.connect(endpoint)
        let status = try await client.nativeStreamingStatus()
        #expect(status.idleUnloadSeconds >= 0)
        let health = try await client.call("health")
        #expect(!String(decoding: try JSONEncoder().encode(health), as: UTF8.self).contains(token))
        let secondSocket = directory.appendingPathComponent("second.sock").path
        let conflict = VoxRuntimeService(port: 0, authToken: "other", socketPath: secondSocket,
                                         privateCapabilityURL: file, preferencesLoader: preferences)
        #expect(throws: (any Error).self) { try conflict.start() }
        conflict.stop()
        #expect(!FileManager.default.fileExists(atPath: secondSocket))
        #expect(try PrivateRuntimeCapability.read(from: file)?.authToken == token)
        _ = try await client.nativeStreamingStatus()
        await client.disconnect()
        service.stop()
        #expect(try PrivateRuntimeCapability.read(from: file) == nil)
    }

    @Test func discoversPrivateCapabilityWithoutLaunchingOrFallingBack() async throws {
        let f = try Fixture()
        f.bridge.handle("identity") { params, reply in reply(["clientId": params?["clientId"] as? String ?? ""], nil) }
        let url = f.directory.appendingPathComponent("runtime.json")
        let runtime = RuntimeInfo(version: "test", serviceName: "Vox", port: 0, pid: getpid(), startedAt: Date(), socketPath: f.path)
        let registration = try PrivateRuntimeRegistration(runtime: runtime, authToken: f.token, url: url)
        defer { registration.invalidate() }
        let endpoint = try VoxEndpoint.discovered(environment: ["VOX_RUNTIME_PATH": url.path])
        let client = VoxDaemonClient(clientId: "talkie")
        try await client.connect(endpoint)
        #expect(try await client.call("identity")["clientId"] == "talkie")
        await client.disconnect()
        for environment in [["VOX_SOCKET_PATH": f.path], ["VOX_AUTH_TOKEN": f.token],
                            ["VOX_RUNTIME_PATH": url.path, "VOX_SOCKET_PATH": "", "VOX_AUTH_TOKEN": f.token]] {
            #expect(throws: VoxClientError.invalidEndpoint) { try VoxEndpoint.discovered(environment: environment) }
        }
        guard case .unix(let path, _) = try VoxEndpoint.discovered(environment: ["VOX_SOCKET_PATH": f.path,
            "VOX_AUTH_TOKEN": f.token, "VOX_RUNTIME_PATH": "/not-used"]) else {
            Issue.record("Explicit host pair must take precedence"); return
        }
        #expect(path == f.path)
        registration.invalidate()
        #expect(throws: VoxClientError.disconnected) { try VoxEndpoint.discovered(environment: ["VOX_RUNTIME_PATH": url.path]) }
    }

    @Test func largeMessagesAndServerShutdownReleasePendingCalls() async throws {
        let f = try Fixture(), calls = Recorder()
        f.bridge.handle("echo") { params, reply in reply(["text": params?["text"] as? String ?? ""], nil) }
        f.bridge.handle("hang") { _, _ in calls.append("hang") }
        let client = VoxDaemonClient(clientId: "talkie")
        try await client.connect(f.endpoint)
        let text = String(repeating: "large-frame", count: 12000)
        #expect(try await client.call("echo", params: ["text": .string(text)])["text"] == .string(text))
        let request = Task { try await client.call("hang") }
        while calls.snapshot.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        f.bridge.stop()
        await #expect(throws: (any Error).self) { try await request.value }
        #expect(await client.isConnected == false)
    }

    @Test func rejectsBadAuthUnsafePathsAndTCPFallback() async throws {
        let f = try Fixture()
        let client = VoxDaemonClient(clientId: "talkie")
        #expect(!String(describing: f.endpoint).contains(f.token))
        #expect(!String(reflecting: f.endpoint).contains(f.token))
        await #expect(throws: (any Error).self) {
            try await client.connect(.unix(socketPath: f.path, authToken: "incorrect"))
        }
        #expect(await client.isConnected == false)
        for token in ["", "a\r\nx-injected: true", "a\u{0}b"] {
            await #expect(throws: (any Error).self) {
                try await client.connect(.unix(socketPath: f.path, authToken: token))
            }
        }
        let link = f.directory.appendingPathComponent("link.sock")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: f.path)
        await #expect(throws: (any Error).self) {
            try await client.connect(.unix(socketPath: link.path, authToken: f.token))
        }
        let info = RuntimeInfo(version: "test", serviceName: "test", port: 9999, pid: 0, startedAt: Date())
        #expect(throws: VoxClientError.tcpNotEnabled) { try VoxEndpoint.runtime(info, authToken: f.token) }
        let privateInfo = RuntimeInfo(version: "test", serviceName: "test", port: 9999, pid: 0,
                                      startedAt: Date(), socketPath: f.path)
        guard case .unix(let path, _) = try VoxEndpoint.runtime(privateInfo, authToken: f.token) else {
            Issue.record("Private metadata must select Unix"); return
        }
        #expect(path == f.path)
        try await client.connect(f.endpoint) // Failed attempts do not poison the actor.
        await client.disconnect()
    }

    @Test func preloadUsesTheCallersExplicitColdReadinessBudget() async throws {
        let f = try Fixture()
        f.bridge.handleStreaming("models.preload") { _, progress, _ in
            progress("models.progress", ["stage": "priming"])
            // Deliberately stay pending: a caller-selected budget must replace the default.
        }
        let client = VoxDaemonClient(clientId: "talkie")
        try await client.connect(f.endpoint)
        await #expect(throws: VoxClientError.timeout) {
            try await client.preloadModel("parakeet:v3", timeout: .milliseconds(150))
        }
        #expect(await client.isConnected == false)
    }

    @Test func timeoutCancellationAndDisconnectDoNotRetry() async throws {
        let f = try Fixture(), calls = Recorder(), disconnects = Recorder()
        f.bridge.handle("hang") { _, _ in calls.append("request") }
        f.bridge.onClientDisconnected = { _ in disconnects.append("disconnect") }
        let client = VoxDaemonClient(clientId: "talkie")
        try await client.connect(f.endpoint)
        await #expect(throws: VoxClientError.timeout) { try await client.call("hang", timeout: .milliseconds(100)) }
        #expect(await client.isConnected == false)
        try await client.connect(f.endpoint)
        let request = Task { try await client.call("hang") }
        while calls.snapshot.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await client.isConnected == false)
        try await client.connect(f.endpoint)
        let pending = Task { try await client.call("hang") }
        while calls.snapshot.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        await client.disconnect()
        await #expect(throws: VoxClientError.disconnected) { try await pending.value }
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.snapshot.count == 3)
        #expect(disconnects.snapshot.count == 3)
    }

    @Test func typedPCMProgressStatusTailAndCancel() async throws {
        let f = try Fixture(), captured = Recorder()
        f.bridge.handle("transcribe.stream.start") { params, reply in
            reply(["sessionId": "session", "modelId": params?["modelId"] as? String ?? "", "sampleRate": 16000,
                   "channels": 1, "encoding": "float32le", "maxPacketSamples": 16000, "nextSequence": 0], nil)
        }
        f.bridge.handle("transcribe.stream.append") { params, reply in
            captured.append(params?["audioBase64"] as? String ?? "")
            reply(["sessionId": "session", "nextSequence": (params?["sequence"] as? Int ?? -1) + 1,
                   "updates": [Self.update("partial")]], nil)
        }
        f.bridge.handle("transcribe.stream.finish") { _, reply in
            reply(["sessionId": "session", "result": Self.update("partial tail")], nil)
        }
        f.bridge.handle("transcribe.stream.cancel") { _, reply in reply(["sessionId": "session", "cancelled": true], nil) }
        f.bridge.handle("transcribe.stream.status") { _, reply in reply(["idleUnloadSeconds": 60], nil) }
        let client = VoxDaemonClient(clientId: "talkie")
        try await client.connect(f.endpoint)
        let session = try await client.startPCMStream()
        #expect(session.modelId == StreamingASRDefaults.modelId)
        let ack = try await client.appendPCMStream(sessionId: session.sessionId, sequence: 0, samples: [1, -2, 0])
        #expect(ack.nextSequence == 1)
        #expect(ack.updates.first?.text == "partial")
        #expect(Data(base64Encoded: captured.snapshot[0]) == Data([0, 0, 128, 63, 0, 0, 0, 192, 0, 0, 0, 0]))
        let final = try await client.finishPCMStream(sessionId: session.sessionId)
        #expect(final.text == "partial tail")
        #expect(final.words.first?.start == 0.1)
        try await client.cancelPCMStream(sessionId: session.sessionId)
        #expect(try await client.nativeStreamingStatus().idleUnloadSeconds == 60)
        let invalidSamples: [[Float]] = [[], [.nan], [.infinity], Array(repeating: 0, count: 16001)]
        for samples in invalidSamples {
            await #expect(throws: VoxClientError.invalidPCM) {
                try await client.appendPCMStream(sessionId: session.sessionId, sequence: 1, samples: samples)
            }
        }
        #expect(captured.snapshot.count == 1)
        await client.disconnect()
    }
    private static func update(_ text: String) -> [String: Any] {
        ["text": text, "words": [["word": "partial", "start": 0.1, "end": 0.2, "confidence": 0.9]],
         "endOfUtterance": false, "processedAudioMs": 160, "chunkLatencyMs": 42.0]
    }

    @Test func pcmBackpressureRejectsOverlappingAppendAndFinish() async throws {
        let f = try Fixture(), calls = Recorder()
        f.bridge.handle("transcribe.stream.append") { _, _ in calls.append("append") }
        let client = VoxDaemonClient(clientId: "talkie")
        try await client.connect(f.endpoint)
        let append = Task { try await client.appendPCMStream(sessionId: "s", sequence: 0, samples: [0]) }
        while calls.snapshot.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await #expect(throws: VoxClientError.streamBusy) {
            try await client.appendPCMStream(sessionId: "s", sequence: 1, samples: [0])
        }
        await #expect(throws: VoxClientError.streamBusy) { try await client.finishPCMStream(sessionId: "s") }
        await client.disconnect()
        await #expect(throws: VoxClientError.disconnected) { try await append.value }
        #expect(calls.snapshot.count == 1)
    }

    @Test func explicitTCPAuthenticatesAndDispatches() async throws {
        // No discovery or TCP fallback: caller deliberately selects the endpoint.
        let port = UInt16.random(in: 49152...65535)
        let bridge = ServiceBridge(port: port, serviceName: "TCPClientTest", authToken: "test-token")
        bridge.handle("echo") { params, reply in reply(["clientId": params?["clientId"] as? String ?? ""], nil) }
        try bridge.start(); defer { bridge.stop() }
        let client = VoxDaemonClient(clientId: "talkie")
        try await client.connect(.tcp(host: "127.0.0.1", port: port, authToken: "test-token"))
        #expect(try await client.call("echo")["clientId"] == "talkie")
        await client.disconnect()
        try await client.connect(.tcp(host: "127.0.0.1", port: port, authToken: "wrong"))
        await #expect(throws: VoxClientError.server("Unauthorized")) { try await client.call("echo") }
        await client.disconnect()
    }
}

struct WebSocketCodecTests {
    @Test func upgradeValidatesAcceptAndRejectsDuplicateHeaders() throws {
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
        try UnixWebSocket.validateUpgrade(Array(response.utf8), key: "dGhlIHNhbXBsZSBub25jZQ==")
        #expect(throws: (any Error).self) { try UnixWebSocket.validateUpgrade(Array(response.utf8), key: "wrong") }
        let duplicate = response.replacingOccurrences(of: "\r\n\r\n", with: "\r\nUpgrade: websocket\r\n\r\n")
        #expect(throws: (any Error).self) { try UnixWebSocket.validateUpgrade(Array(duplicate.utf8), key: "dGhlIHNhbXBsZSBub25jZQ==") }
    }
    @Test func parserBoundsPartialFramesAndRejectsMasking() throws {
        var partial: [UInt8] = [0x81, 3, 65]
        #expect(try UnixWebSocket.parseFrame(&partial) == nil)
        partial += [66, 67]
        let frame = try #require(try UnixWebSocket.parseFrame(&partial))
        #expect(frame.bytes == [65, 66, 67]); #expect(partial.isEmpty)
        let malformedFrames: [[UInt8]] = [[0x81, 0x80], [0x81, 127] + Array(repeating: 255, count: 8),
                                  [0x09, 0], [0x81, 126, 0, 1, 65], [0xC1, 0]]
        for malformed in malformedFrames {
            var bytes = malformed
            #expect(throws: (any Error).self) { try UnixWebSocket.parseFrame(&bytes) }
        }
    }
    @Test func clientFramesAreMaskedAtAllLengths() {
        for length in [0, 125, 126, 65535, 65536] {
            let payload = Array(repeating: UInt8(42), count: length)
            let frame = UnixWebSocket.maskedFrame(opcode: 1, bytes: payload)
            #expect(frame[1] & 128 != 0)
            let offset = length < 126 ? 2 : length <= 65535 ? 4 : 10
            let key = Array(frame[offset..<(offset + 4)])
            #expect(Array(frame.dropFirst(offset + 4).enumerated().map { $0.element ^ key[$0.offset % 4] }) == payload)
        }
    }
}
