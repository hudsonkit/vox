import Foundation

protocol ClientWire: AnyObject, Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func close()
}

final class TCPWebSocket: ClientWire, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let receive: @Sendable (Data) -> Void
    private let closed: @Sendable (any Error) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var stopped = false

    init(host: String, port: UInt16, receive: @escaping @Sendable (Data) -> Void,
         closed: @escaping @Sendable (any Error) -> Void) {
        self.host = host; self.port = port; self.receive = receive; self.closed = closed
    }
    func connect() async throws {
        var parts = URLComponents(); parts.scheme = "ws"; parts.host = host
        parts.port = Int(port); parts.path = "/"
        guard !host.isEmpty, port != 0, let url = parts.url else { throw VoxClientError.invalidEndpoint }
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: url); request.timeoutInterval = 5
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 16 * 1024 * 1024
        let installed = lock.withLock {
            guard !stopped else { return false }
            self.session = session; self.socket = socket; return true
        }
        guard installed else { session.invalidateAndCancel(); throw VoxClientError.disconnected }
        socket.resume()
        let deadline = DispatchWorkItem { socket.cancel(with: .goingAway, reason: nil) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    switch message {
                    case .string(let text): self?.receive(Data(text.utf8))
                    case .data: throw VoxClientError.protocolViolation("Expected a JSON text frame")
                    @unknown default: throw VoxClientError.invalidResponse
                    }
                }
            } catch { self?.closed(error) }
        }
        lock.withLock { if stopped { reader.cancel() } else { self.reader = reader } }
    }
    func send(_ data: Data) async throws {
        guard let socket = lock.withLock({ self.socket }), let text = String(data: data, encoding: .utf8)
        else { throw VoxClientError.disconnected }
        guard data.count <= 16 * 1024 * 1024 else { throw VoxClientError.backpressure }
        try await socket.send(.string(text))
    }
    func close() {
        lock.withLock {
            stopped = true; reader?.cancel(); reader = nil
            socket?.cancel(with: .goingAway, reason: nil); socket = nil
            session?.invalidateAndCancel(); session = nil
        }
    }
    deinit { close() }
}
