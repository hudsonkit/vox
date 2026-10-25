import CommonCrypto
import Darwin
import Foundation

/// Private local transport. Admission precedes every RPC/event; UID and file
/// permissions protect against other users, not arbitrary same-user code.
final class PrivateWebSocketServer: @unchecked Sendable {
    typealias Receive = (Data, String, @escaping @Sendable (Data) -> Void) -> Void
    private let socketURL: URL
    private let token: String
    private let receive: Receive
    private let disconnected: (String) -> Void
    private var lockFD: Int32 = -1
    private var serverFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var boundSocketIdentity: (dev_t, ino_t)?
    private var clients: [UUID: VoxIPCClient] = [:]
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "cc.voxd.private-bridge")

    init(path: String, token: String, receive: @escaping Receive, disconnected: @escaping (String) -> Void) {
        socketURL = URL(fileURLWithPath: path); self.token = token
        self.receive = receive; self.disconnected = disconnected
    }

    func start() throws {
        guard serverFd < 0, !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw POSIXError(.EACCES) }
        try VoxPrivateIPC.prepareDirectory(socketURL.deletingLastPathComponent())
        lockFD = open(socketURL.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var info = stat()
        guard lockFD >= 0, fstat(lockFD, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }; throw POSIXError(.EADDRINUSE)
        }
        do {
            try VoxPrivateIPC.removeStaleSocket(socketURL)
            serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard serverFd >= 0 else { throw POSIXError(.EIO) }
            guard fcntl(serverFd, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EIO) }
            var addr = sockaddr_un(); addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size); addr.sun_family = sa_family_t(AF_UNIX)
            guard socketURL.path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in socketURL.path.utf8CString.withUnsafeBytes { dest.copyBytes(from: $0) } }
            let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { throw POSIXError(.EADDRINUSE) }
            guard lstat(socketURL.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw POSIXError(.EACCES) }
            boundSocketIdentity = (info.st_dev, info.st_ino)
            guard chmod(socketURL.path, 0o600) == 0, listen(serverFd, 16) == 0,
                  fcntl(serverFd, F_SETFL, fcntl(serverFd, F_GETFL) | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            let fd = serverFd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptConnection(listener: fd, isUnix: true) }
            source.setCancelHandler { close(fd) }
            acceptSource = source; source.resume()
        } catch { stop(); throw error }
    }

    func stop() {
        queue.sync {
            if let acceptSource { acceptSource.cancel(); self.acceptSource = nil }
            else if serverFd >= 0 { close(serverFd) }
            serverFd = -1
            lock.lock(); let snapshot = Array(clients.values); lock.unlock()
            for client in snapshot { client.handshakeTimeout?.cancel(); client.readSource?.cancel() }
        }
        if let identity = boundSocketIdentity {
            var info = stat()
            if lstat(socketURL.path, &info) == 0, info.st_dev == identity.0, info.st_ino == identity.1 { unlink(socketURL.path) }
            boundSocketIdentity = nil
        }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }

    private func acceptConnection(listener: Int32, isUnix: Bool) {
        let clientFd = accept(listener, nil, nil)
        guard clientFd >= 0 else { return }
        lock.lock(); let atLimit = clients.count >= 64; lock.unlock()
        guard !atLimit, !isUnix || VoxPrivateIPC.sameUserPeer(clientFd) else { close(clientFd); return }
        var yes: Int32 = 1
        let flags = fcntl(clientFd, F_GETFL)
        guard fcntl(clientFd, F_SETFD, FD_CLOEXEC) == 0,
              flags >= 0, fcntl(clientFd, F_SETFL, flags | O_NONBLOCK) == 0,
              setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0 else { close(clientFd); return }
        let client = VoxIPCClient(id: UUID(), fd: clientFd)
        client.isUnix = isUnix
        lock.lock(); clients[client.id] = client; lock.unlock()
        // Incremental nonblocking handshake: one idle peer cannot stall other clients.
        readLoop(client: client)
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + 3)
        timeout.setEventHandler { [weak client] in client?.readSource?.cancel() }
        client.handshakeTimeout = timeout
        timeout.resume()
    }

    private func performHandshake(client: VoxIPCClient) -> Bool {
        guard let end = (client.buffer.count >= 4 ? (0...(client.buffer.count - 4)).first(where: { Array(client.buffer[$0..<($0 + 4)]) == [13, 10, 13, 10] }) : nil) else {
            if client.buffer.count > 8192 { client.readSource?.cancel() }
            return false
        }
        let headerLength = end + 4
        guard headerLength <= 8192, let request = String(bytes: client.buffer.prefix(headerLength), encoding: .utf8) else { client.readSource?.cancel(); return false }
        let lines = request.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { client.readSource?.cancel(); return false }
            let name = String(pair[0]).lowercased()
            guard !name.isEmpty, name == name.trimmingCharacters(in: .whitespaces), headers[name] == nil else { client.readSource?.cancel(); return false }
            headers[name] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        let hosts: Set<String> = ["localhost", "127.0.0.1"]
        let supplied = headers["x-lattices-token"] ?? ""
        let authorized = supplied.utf8.count == token.utf8.count && zip(supplied.utf8, token.utf8).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        guard lines.first == "GET / HTTP/1.1", headers["origin"] == nil,
              let host = headers["host"], hosts.contains(host.lowercased()),
              headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              headers["sec-websocket-version"] == "13", authorized, headers["content-length"] == nil, headers["transfer-encoding"] == nil,
              let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
            let denied = Array("HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
            _ = denied.withUnsafeBytes { write(client.fd, $0.baseAddress!, $0.count) }
            client.readSource?.cancel()
            return false
        }
        let acceptKey = sha1Base64(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        client.buffer.removeFirst(headerLength)
        client.authorized = true
        client.handshakeTimeout?.cancel(); client.handshakeTimeout = nil
        client.pendingOutput.append(contentsOf: response.utf8)
        flushOutput(client)
        return true
    }

    // MARK: - WebSocket Frame I/O

    private func readLoop(client: VoxIPCClient) {
        let source = DispatchSource.makeReadSource(fileDescriptor: client.fd, queue: queue)
        client.readSource = source
        source.setEventHandler { [weak self] in
            self?.readFrame(client: client)
        }
        let disconnected = self.disconnected
        source.setCancelHandler { [weak self] in
            // ServiceBridge releases this server after stop(). Descriptor and
            // session cleanup must not depend on that server staying alive.
            client.handshakeTimeout?.cancel(); client.handshakeTimeout = nil
            client.writeSource?.cancel(); client.writeSource = nil
            client.readSource = nil
            client.pendingOutput.removeAll()
            close(client.fd)
            self?.removeClient(client)
            if client.authorized { disconnected(client.id.uuidString) }
        }
        source.resume()
    }

    private func readFrame(client: VoxIPCClient) {
        // Read available data into client buffer
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(client.fd, &buf, buf.count)
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
        if n <= 0 {
            client.readSource?.cancel()
            return
        }
        client.buffer.append(contentsOf: buf[..<n])

        if !client.authorized, !performHandshake(client: client) { return }
        guard client.buffer.count <= 16_777_230 else { client.readSource?.cancel(); return }
        // Validate lengths as UInt64 before any Int conversion or allocation.
        do { while let frame = try parseFrame(&client.buffer) {
            switch frame.opcode {
            case 0x1: // Text
                if let text = String(bytes: frame.payload, encoding: .utf8),
                   let data = text.data(using: .utf8) {
                    handleMessage(data, client: client)
                }
            case 0x8: // Close
                // Send close frame back
                sendFrame(opcode: 0x8, payload: [], to: client)
                client.readSource?.cancel()
                return
            case 0x9: // Ping → Pong
                sendFrame(opcode: 0xA, payload: frame.payload, to: client)
            case 0xA: // Pong — ignore
                break
            default:
                break
            }
        } } catch { client.readSource?.cancel() }
    }

    private struct WSFrame {
        let opcode: UInt8
        let payload: [UInt8]
    }

    private func parseFrame(_ buffer: inout [UInt8]) throws -> WSFrame? {
        guard buffer.count >= 2 else { return nil }

        let byte0 = buffer[0]
        let byte1 = buffer[1]
        let opcode = byte0 & 0x0F
        let masked = (byte1 & 0x80) != 0
        guard byte0 & 0x80 != 0, byte0 & 0x70 == 0, masked,
              [UInt8(1), 8, 9, 10].contains(opcode) else { throw POSIXError(.EPROTO) }
        var payloadLen = UInt64(byte1 & 0x7F)
        var offset = 2

        if payloadLen == 126 {
            guard buffer.count >= 4 else { return nil }
            payloadLen = UInt64(buffer[2]) << 8 | UInt64(buffer[3])
            offset = 4
        } else if payloadLen == 127 {
            guard buffer.count >= 10 else { return nil }
            payloadLen = 0
            for i in 0..<8 { payloadLen = payloadLen << 8 | UInt64(buffer[2 + i]) }
            offset = 10
        }

        guard payloadLen <= 16_777_216, opcode < 8 || payloadLen <= 125 else { throw POSIXError(.EMSGSIZE) }
        let maskSize = masked ? 4 : 0
        let totalNeeded = offset + maskSize + Int(payloadLen)
        guard buffer.count >= totalNeeded else { return nil }

        var payload: [UInt8]
        if masked {
            let mask = Array(buffer[offset..<(offset + 4)])
            let dataStart = offset + 4
            payload = Array(buffer[dataStart..<(dataStart + Int(payloadLen))])
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        } else {
            payload = Array(buffer[offset..<(offset + Int(payloadLen))])
        }

        buffer.removeFirst(totalNeeded)
        return WSFrame(opcode: opcode, payload: payload)
    }

    private func sendFrame(opcode: UInt8, payload: [UInt8], to client: VoxIPCClient) {
        var frame: [UInt8] = [0x80 | opcode] // FIN + opcode

        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }
        frame.append(contentsOf: payload)

        // All frame writes and pending bytes belong to the socket queue.
        // Nonblocking sockets may accept only a prefix; retain the rest until writable.
        let bytes = frame
        queue.async { [weak self] in
            guard let self, self.isConnected(client) else { return }
            guard client.pendingOutput.count + bytes.count <= 32 * 1024 * 1024 else {
                client.readSource?.cancel()
                return
            }
            client.pendingOutput.append(contentsOf: bytes)
            self.flushOutput(client)
        }
    }

    private func flushOutput(_ client: VoxIPCClient) {
        guard isConnected(client) else { return }
        while !client.pendingOutput.isEmpty {
            let written = client.pendingOutput.withUnsafeBytes { bytes in
                write(client.fd, bytes.baseAddress!, bytes.count)
            }
            if written > 0 {
                client.pendingOutput.removeFirst(written)
                continue
            }
            if written < 0 && errno == EINTR { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if client.writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: client.fd, queue: queue)
                    client.writeSource = source
                    source.setEventHandler { [weak self, weak client] in
                        guard let self, let client else { return }
                        self.flushOutput(client)
                    }
                    source.resume()
                }
                return
            }
            client.readSource?.cancel()
            return
        }
        client.writeSource?.cancel()
        client.writeSource = nil
    }

    private func sendWebSocketText(_ text: String, to client: VoxIPCClient) {
        let payload = Array(text.utf8)
        sendFrame(opcode: 0x1, payload: payload, to: client)
    }

    private func handleMessage(_ data: Data, client: VoxIPCClient) {
        receive(data, client.id.uuidString) { [weak self, weak client] reply in
            guard let self, let client else { return }
            self.sendFrame(opcode: 1, payload: Array(reply), to: client)
        }
    }

    private func isConnected(_ client: VoxIPCClient) -> Bool {
        lock.lock(); defer { lock.unlock() }; return clients[client.id] === client
    }

    private func removeClient(_ client: VoxIPCClient) {
        lock.lock(); clients.removeValue(forKey: client.id); lock.unlock()
    }

    private func sha1Base64(_ string: String) -> String {
        let data = Array(string.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        CC_SHA1(data, CC_LONG(data.count), &hash)
        return Data(hash).base64EncodedString()
    }
}
private final class VoxIPCClient: @unchecked Sendable {
    let id: UUID
    let fd: Int32
    var authorized = false
    var isUnix = false
    var handshakeTimeout: DispatchSourceTimer?
    var buffer: [UInt8] = []
    var readSource: DispatchSourceRead?
    var writeSource: DispatchSourceWrite?
    var pendingOutput = Data()

    init(id: UUID, fd: Int32) {
        self.id = id
        self.fd = fd
    }
}
