import CommonCrypto
import Darwin
import Foundation

/// Serial, bounded nonblocking socket I/O; handshake work never occupies Swift's cooperative pool.
/// Private filesystem ancestors + same-UID peer protect the credential before it is sent.
final class UnixWebSocket: ClientWire, @unchecked Sendable {
    private let path: String
    private let token: String
    private let receive: @Sendable (Data) -> Void
    private let closed: @Sendable (any Error) -> Void
    private let queue = DispatchQueue(label: "cc.voxd.client.unix")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var stopped = false
    private var input = [UInt8]()
    private var output = [UInt8]()
    private var written = 0
    private var fragment = [UInt8]()
    private var fragmented = false
    private static let maxMessage = 16 * 1024 * 1024
    private static let maxQueued = 32 * 1024 * 1024

    init(path: String, token: String, receive: @escaping @Sendable (Data) -> Void,
         closed: @escaping @Sendable (any Error) -> Void) {
        self.path = path; self.token = token; self.receive = receive; self.closed = closed
    }
    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !self.stopped else { throw VoxClientError.disconnected }
                    try self.openAndUpgrade()
                    continuation.resume()
                } catch {
                    self.stop(error); continuation.resume(throwing: error)
                }
            }
        }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard self.fd >= 0, !self.stopped else { throw VoxClientError.disconnected }
                    guard data.count <= Self.maxMessage else { throw VoxClientError.backpressure }
                    try self.enqueue(opcode: 1, bytes: Array(data))
                    continuation.resume()
                } catch { self.stop(error); continuation.resume(throwing: error) }
            }
        }
    }
    func close() { queue.async { self.stop(VoxClientError.disconnected) } }
    deinit {
        writeSource?.cancel()
        if let readSource { readSource.cancel() }
        else if fd >= 0 { Darwin.close(fd) }
    }

    private func openAndUpgrade() throws {
        guard !token.isEmpty, token.utf8.count <= 4096,
              token.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw VoxClientError.invalidEndpoint }
        try Self.validatePath(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
        else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size); address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw VoxClientError.invalidEndpoint }
        withUnsafeMutableBytes(of: &address.sun_path) { dest in
            path.utf8CString.withUnsafeBytes { dest.copyBytes(from: $0) }
        }
        let initialFlags = fcntl(fd, F_GETFL)
        guard initialFlags >= 0, fcntl(fd, F_SETFL, initialFlags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EWOULDBLOCK else { throw POSIXError(.ECONNREFUSED) }
            let deadline = Date().addingTimeInterval(5)
            var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw VoxClientError.timeout }
                let count = poll(&ready, 1, Int32(ceil(remaining * 1000)))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw VoxClientError.timeout }
                var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0,
                      ready.revents & Int16(POLLOUT) != 0 else { throw POSIXError(.ECONNREFUSED) }
                break
            }
        }
        guard fcntl(fd, F_SETFL, initialFlags) == 0 else { throw POSIXError(.EIO) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw POSIXError(.EACCES) }
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        // These fixed path/headers match PrivateWebSocketServer.performHandshake.
        let request = Array(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n" +
            "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n" +
            "x-lattices-token: \(token)\r\n\r\n").utf8)
        var sent = 0
        let deadline = Date().addingTimeInterval(5)
        while sent < request.count {
            guard Date() < deadline else { throw VoxClientError.timeout }
            let n = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), request.count - sent) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw VoxClientError.disconnected }; sent += n
        }
        var headers = [UInt8]()
        while !headers.suffix(4).elementsEqual([13, 10, 13, 10]) {
            guard headers.count < 8192, Date() < deadline else { throw VoxClientError.timeout }
            var byte: UInt8 = 0
            let n = Darwin.read(fd, &byte, 1)
            if n < 0, errno == EINTR { continue }
            guard n == 1 else { throw VoxClientError.disconnected }; headers.append(byte)
        }
        try Self.validateUpgrade(headers, key: key)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
        let descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { Darwin.close(descriptor) }
        readSource = source; source.resume()
    }

    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0), !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }), parts.count >= 3
        else { throw VoxClientError.invalidEndpoint }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(directory) }
        let components = parts.dropFirst().map(String.init)
        for (index, component) in components.dropLast().enumerated() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw POSIXError(.EACCES) }
            Darwin.close(directory); directory = next
            var info = stat()
            guard fstat(directory, &info) == 0, info.st_uid == 0 || info.st_uid == geteuid(),
                  info.st_mode & 0o022 == 0 || info.st_mode & S_ISVTX != 0 else { throw POSIXError(.EACCES) }
            if index == components.count - 2 {
                guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
            }
        }
        var info = stat()
        guard let name = components.last, fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw POSIXError(.EACCES) }
    }

    static func validateUpgrade(_ bytes: [UInt8], key: String) throws {
        guard let response = String(bytes: bytes, encoding: .utf8) else { throw VoxClientError.invalidResponse }
        let lines = response.components(separatedBy: "\r\n")
        guard lines.first?.split(separator: " ").prefix(2).map(String.init) == ["HTTP/1.1", "101"]
        else { throw VoxClientError.protocolViolation("Private Vox WebSocket upgrade rejected") }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw VoxClientError.invalidResponse }
            let name = pair[0].lowercased()
            guard fields[name] == nil else { throw VoxClientError.invalidResponse }
            fields[name] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        let material = Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        _ = material.withUnsafeBytes { CC_SHA1($0.baseAddress, CC_LONG($0.count), &digest) }
        guard fields["upgrade"]?.lowercased() == "websocket",
              fields["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              fields["sec-websocket-accept"] == Data(digest).base64EncodedString(),
              fields["sec-websocket-extensions"] == nil, fields["sec-websocket-protocol"] == nil
        else { throw VoxClientError.invalidResponse }
    }

    private func stop(_ error: any Error) {
        guard !stopped else { return }; stopped = true
        writeSource?.cancel(); writeSource = nil
        if let readSource { readSource.cancel(); self.readSource = nil }
        else if fd >= 0 { Darwin.close(fd) }
        fd = -1; output.removeAll(); input.removeAll(); fragment.removeAll()
        closed(error)
    }
    private func enqueue(opcode: UInt8, bytes: [UInt8]) throws {
        let frame = Self.maskedFrame(opcode: opcode, bytes: bytes)
        guard output.count - written + frame.count <= Self.maxQueued else { throw VoxClientError.backpressure }
        if written > 0 { output.removeFirst(written); written = 0 }
        output.append(contentsOf: frame); try flush()
    }
    static func maskedFrame(opcode: UInt8, bytes: [UInt8]) -> [UInt8] {
        var frame: [UInt8] = [0x80 | opcode]
        if bytes.count < 126 { frame.append(0x80 | UInt8(bytes.count)) }
        else if bytes.count <= 65535 {
            frame += [0x80 | 126, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]
        } else {
            frame.append(0x80 | 127)
            let size = UInt64(bytes.count)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((size >> shift) & 255)) }
        }
        let mask = (0..<4).map { _ in UInt8.random(in: .min ... .max) }
        frame += mask
        frame += bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return frame
    }
    private func flush() throws {
        while written < output.count {
            let n = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: written), output.count - written) }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in
                        guard let self, !self.stopped else { return }
                        do { try self.flush() } catch { self.stop(error) }
                    }
                    writeSource = source; source.resume()
                }
                return
            }
            guard n > 0 else { throw VoxClientError.disconnected }; written += n
        }
        output.removeAll(keepingCapacity: true); written = 0
        writeSource?.cancel(); writeSource = nil
    }
    private func readAvailable() {
        guard !stopped else { return }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &bytes, bytes.count)
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
        guard n > 0 else { stop(VoxClientError.disconnected); return }
        input.append(contentsOf: bytes.prefix(n))
        do {
            guard input.count <= Self.maxMessage + 65550 else { throw VoxClientError.backpressure }
            while let frame = try Self.parseFrame(&input) {
                switch frame.opcode {
                case 8: stop(VoxClientError.disconnected); return
                case 9: try enqueue(opcode: 10, bytes: frame.bytes)
                case 10: break
                case 1:
                    guard !fragmented else { throw VoxClientError.invalidResponse }
                    if frame.final { try deliver(frame.bytes) }
                    else { fragmented = true; fragment = frame.bytes }
                case 0:
                    guard fragmented, fragment.count + frame.bytes.count <= Self.maxMessage else { throw VoxClientError.invalidResponse }
                    fragment += frame.bytes
                    if frame.final { try deliver(fragment); fragment.removeAll(); fragmented = false }
                default: throw VoxClientError.invalidResponse
                }
            }
        } catch { stop(error) }
    }
    private func deliver(_ bytes: [UInt8]) throws {
        guard String(bytes: bytes, encoding: .utf8) != nil else { throw VoxClientError.invalidResponse }
        receive(Data(bytes))
    }
    struct Frame { let opcode: UInt8; let final: Bool; let bytes: [UInt8] }
    static func parseFrame(_ bytes: inout [UInt8]) throws -> Frame? {
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 15, final = bytes[0] & 128 != 0
        guard bytes[0] & 0x70 == 0, bytes[1] & 128 == 0, [UInt8(0), 1, 8, 9, 10].contains(opcode)
        else { throw VoxClientError.invalidResponse }
        var length = UInt64(bytes[1] & 127), offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); offset = 4
            guard length >= 126 else { throw VoxClientError.invalidResponse }
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = 0
            for byte in bytes[2..<10] { length = length << 8 | UInt64(byte) }; offset = 10
            guard length > 65535 else { throw VoxClientError.invalidResponse }
        }
        guard length <= UInt64(maxMessage), opcode < 8 || (final && length <= 125)
        else { throw VoxClientError.invalidResponse }
        guard bytes.count >= offset + Int(length) else { return nil }
        let frame = Frame(opcode: opcode, final: final, bytes: Array(bytes[offset..<(offset + Int(length))]))
        bytes.removeFirst(offset + Int(length)); return frame
    }
}
