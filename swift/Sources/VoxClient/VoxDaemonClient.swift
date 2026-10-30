import Foundation
import VoxCore

/// Lightweight companion client. Depends on VoxCore only, never loads a speech model.
/// A cancelled/timed-out request disconnects: remote execution may already have started.
/// Reconnection is explicit and never resumes or retries an owned session.
public actor VoxDaemonClient {
    public let clientId: String
    private var wire: (any ClientWire)?
    private var generation = UUID()
    private var connected = false
    private enum WireEvent: Sendable { case message(Data), closed(any Error) }
    private var eventsTask: Task<Void, Never>?
    private var eventsContinuation: AsyncStream<WireEvent>.Continuation?
    private var tcpToken: String?
    private var pcmInFlight: Set<String> = []
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, any Error>
        let progress: (@Sendable (VoxRPCProgress) -> Void)?
        let timeout: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]

    public init(clientId: String) { self.clientId = clientId }
    deinit { eventsContinuation?.finish(); eventsTask?.cancel(); wire?.close() }
    public var isConnected: Bool { connected }

    public func connectDiscovered() async throws { try await connect(VoxEndpoint.discovered()) }

    public func connect(_ endpoint: VoxEndpoint) async throws {
        guard wire == nil else { throw VoxClientError.alreadyConnected }
        guard !clientId.isEmpty else { throw VoxClientError.invalidEndpoint }
        try Task.checkCancellation()
        let id = UUID(); generation = id
        let (events, continuation) = AsyncStream<WireEvent>.makeStream(bufferingPolicy: .bufferingOldest(64))
        eventsContinuation = continuation
        eventsTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                switch event {
                case .message(let data): await self?.receive(data, generation: id)
                case .closed(let error): await self?.fail(error, generation: id); return
                }
            }
        }
        let deliver: @Sendable (WireEvent) -> Void = { [weak self] event in
            if case .dropped = continuation.yield(event) {
                continuation.finish()
                Task { await self?.fail(VoxClientError.backpressure, generation: id) }
            }
        }
        let receive: @Sendable (Data) -> Void = { deliver(.message($0)) }
        let closed: @Sendable (any Error) -> Void = { deliver(.closed($0)) }
        let transport: any ClientWire
        switch endpoint {
        case .unix(let path, let token):
            tcpToken = nil
            transport = UnixWebSocket(path: path, token: token, receive: receive, closed: closed)
        case .tcp(let host, let port, let token):
            tcpToken = token
            transport = TCPWebSocket(host: host, port: port, receive: receive, closed: closed)
        }
        wire = transport
        do {
            try await withTaskCancellationHandler {
                try await transport.connect()
                try Task.checkCancellation()
            } onCancel: { transport.close() }
            guard generation == id, wire != nil else { throw VoxClientError.disconnected }
            connected = true
        } catch {
            fail(error, generation: id)
            throw error
        }
    }

    public func disconnect() { fail(VoxClientError.disconnected, generation: generation) }

    /// Injects this client's identity; progress callbacks must return promptly.
    /// Cancellation closes the connection (and therefore all its owned sessions).
    public func call(_ method: String, params: [String: JSONValue] = [:],
                     timeout: Duration = .seconds(30),
                     onProgress: (@Sendable (VoxRPCProgress) -> Void)? = nil) async throws -> JSONValue {
        try Task.checkCancellation()
        guard connected, let wire else { throw VoxClientError.disconnected }
        guard pending.count < 64 else { throw VoxClientError.backpressure }
        let id = UUID().uuidString, epoch = generation
        var ownedParams = params; ownedParams["clientId"] = .string(clientId)
        var request: [String: JSONValue] = ["id": .string(id), "method": .string(method), "params": .object(ownedParams)]
        if let tcpToken { request["authToken"] = .string(tcpToken) }
        let bytes = try JSONEncoder().encode(JSONValue.object(request))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    await self?.timeoutRequest(id, generation: epoch)
                }
                pending[id] = Pending(continuation: continuation, progress: onProgress, timeout: timer)
                Task { [weak self] in
                    do { try await wire.send(bytes) }
                    catch { await self?.fail(error, generation: epoch) }
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.cancelRequest(id, generation: epoch) }
        }
    }

    private func timeoutRequest(_ id: String, generation: UUID) {
        guard pending[id] != nil else { return }
        fail(VoxClientError.timeout, generation: generation)
    }
    private func cancelRequest(_ id: String, generation: UUID) {
        guard pending[id] != nil else { return }
        fail(CancellationError(), generation: generation)
    }
    private func fail(_ error: any Error, generation id: UUID) {
        guard generation == id else { return }
        generation = UUID(); connected = false
        eventsContinuation?.finish(); eventsContinuation = nil
        eventsTask?.cancel(); eventsTask = nil
        let previous = wire; wire = nil; previous?.close()
        tcpToken = nil; pcmInFlight.removeAll()
        let requests = pending; pending.removeAll()
        for request in requests.values { request.timeout.cancel(); request.continuation.resume(throwing: error) }
    }
    private func receive(_ data: Data, generation id: UUID) {
        guard generation == id else { return }
        do {
            let message = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let requestId = message["id"]?.stringValue, let request = pending[requestId] else { return }
            if let event = message["event"]?.stringValue {
                request.progress?(VoxRPCProgress(event: event, data: message["data"] ?? .null)); return
            }
            pending.removeValue(forKey: requestId); request.timeout.cancel()
            if let error = message["error"] {
                request.continuation.resume(throwing: VoxClientError.server(error.stringValue ?? "Vox RPC failed"))
            } else if let result = message["result"] { request.continuation.resume(returning: result) }
            else { request.continuation.resume(throwing: VoxClientError.invalidResponse) }
        } catch { fail(VoxClientError.invalidResponse, generation: id) }
    }

    public func listModels() async throws -> JSONValue { try await call("models.list") }
    public func listCatalog() async throws -> JSONValue { try await call("models.catalog") }
    public func installModel(_ modelId: String, onProgress: (@Sendable (VoxRPCProgress) -> Void)? = nil) async throws -> JSONValue {
        try await call("models.install", params: ["modelId": .string(modelId)], timeout: .seconds(1800), onProgress: onProgress)
    }
    public func preloadModel(_ modelId: String, onProgress: (@Sendable (VoxRPCProgress) -> Void)? = nil) async throws -> JSONValue {
        try await call("models.preload", params: ["modelId": .string(modelId)], timeout: .seconds(300), onProgress: onProgress)
    }
    public func nativeStreamingStatus() async throws -> NativeStreamingStatus {
        try await call("transcribe.stream.status").decode()
    }
    public func startPCMStream(modelId: String = StreamingASRDefaults.modelId) async throws -> PCMStreamingSession {
        try await call("transcribe.stream.start", params: ["modelId": .string(modelId)]).decode()
    }
    public func appendPCMStream(sessionId: String, sequence: Int, samples: [Float]) async throws -> PCMStreamingAcknowledgement {
        guard !samples.isEmpty, samples.count <= 16000, samples.allSatisfy(\.isFinite), sequence >= 0 else {
            throw VoxClientError.invalidPCM
        }
        guard pcmInFlight.insert(sessionId).inserted else { throw VoxClientError.streamBusy }
        defer { pcmInFlight.remove(sessionId) }
        var data = Data(capacity: samples.count * 4)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return try await call("transcribe.stream.append", params: ["sessionId": .string(sessionId),
            "sequence": .number(Double(sequence)), "audioBase64": .string(data.base64EncodedString())]).decode()
    }
    public func finishPCMStream(sessionId: String) async throws -> StreamingASRUpdate {
        guard pcmInFlight.insert(sessionId).inserted else { throw VoxClientError.streamBusy }
        defer { pcmInFlight.remove(sessionId) }
        let result = try await call("transcribe.stream.finish", params: ["sessionId": .string(sessionId)])
        guard let update = result["result"] else { throw VoxClientError.invalidResponse }
        return try update.decode()
    }
    public func cancelPCMStream(sessionId: String) async throws {
        _ = try await call("transcribe.stream.cancel", params: ["sessionId": .string(sessionId)])
    }
    public func transcribeFile(path: String, modelId: String = "parakeet:v3") async throws -> JSONValue {
        try await call("transcribe.file", params: ["path": .string(path), "modelId": .string(modelId)], timeout: .seconds(300))
    }
}
