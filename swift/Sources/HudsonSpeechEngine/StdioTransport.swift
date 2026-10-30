#if os(macOS)
import Foundation
import VoxCore

public final class StdioTransport: @unchecked Sendable {
    private let log = VoxLog.engine
    private let command: [String]
    private let env: [String: String]?
    private let queue = DispatchQueue(label: "cc.voxd.stdio-transport")

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var nextId: Int = 1
    private var pending: [Int: CheckedContinuation<[String: Any], any Error>] = [:]
    private var _progressHandler: (([String: Any]) -> Void)?
    private var _isRunning: Bool = false
    private var _stderrOutput: String = ""
    private let callTimeoutSeconds: TimeInterval

    public init(
        command: [String],
        env: [String: String]? = nil,
        callTimeoutSeconds: TimeInterval? = nil
    ) {
        self.command = command
        self.env = env
        self.callTimeoutSeconds = callTimeoutSeconds ?? Self.resolveCallTimeoutSeconds(env: env)
    }

    public func start() throws {
        guard !command.isEmpty else {
            throw StdioTransportError.invalidCommand
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command[0])
        if command.count > 1 {
            proc.arguments = Array(command.dropFirst())
        }

        var environment = ProcessInfo.processInfo.environment
        if let env {
            for (key, value) in env {
                environment[key] = value
            }
        }
        proc.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        queue.sync {
            stdinPipe = stdin
            stdoutPipe = stdout
            stderrPipe = stderr
            process = proc
        }

        try proc.run()
        queue.sync { _isRunning = true }
        log.info("Started external provider: \(self.command.joined(separator: " "))")

        startReadingStdout(stdout)
        startReadingStderr(stderr)

        proc.terminationHandler = { [weak self] proc in
            self?.handleTermination(exitCode: proc.terminationStatus)
        }
    }

    public func stop() {
        queue.sync {
            if let process, process.isRunning {
                try? stdinPipe?.fileHandleForWriting.close()
                process.terminate()
            }
            _isRunning = false
        }
        cancelAllPending(error: StdioTransportError.stopped)
    }

    public func setProgressHandler(_ handler: @escaping @Sendable ([String: Any]) -> Void) {
        queue.sync { _progressHandler = handler }
    }

    public func clearProgressHandler() {
        queue.sync { _progressHandler = nil }
    }

    public func call(method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let isRunning = queue.sync { _isRunning }
        guard isRunning else {
            throw StdioTransportError.notRunning
        }

        let id = queue.sync { () -> Int in
            let current = nextId
            nextId += 1
            return current
        }

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        let data = try JSONSerialization.data(withJSONObject: request)
        guard var line = String(data: data, encoding: .utf8) else {
            throw StdioTransportError.serializationFailed
        }
        line.append("\n")

        guard let lineData = line.data(using: .utf8) else {
            throw StdioTransportError.serializationFailed
        }

        let pipe = queue.sync { stdinPipe }
        guard let pipe else {
            throw StdioTransportError.notRunning
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.sync {
                pending[id] = continuation
            }

            pipe.fileHandleForWriting.write(lineData)

            // Schedule timeout
            queue.asyncAfter(deadline: .now() + self.callTimeoutSeconds) { [weak self] in
                guard let self else { return }
                let cont = self.pending.removeValue(forKey: id)
                cont?.resume(throwing: StdioTransportError.timeout(method: method))
            }
        }
    }

    deinit {
        stop()
    }

    public var processIsRunning: Bool {
        queue.sync { _isRunning }
    }

    public var lastStderrOutput: String {
        queue.sync { _stderrOutput }
    }

    // MARK: - Private

    private static func resolveCallTimeoutSeconds(env: [String: String]?) -> TimeInterval {
        let environment = ProcessInfo.processInfo.environment
        let secondsRaw = env?["VOX_PROVIDER_CALL_TIMEOUT_SECONDS"]
            ?? environment["VOX_PROVIDER_CALL_TIMEOUT_SECONDS"]
        if let secondsRaw,
           let seconds = TimeInterval(secondsRaw),
           seconds > 0
        {
            return seconds
        }

        let millisecondsRaw = env?["VOX_PROVIDER_CALL_TIMEOUT_MS"]
            ?? environment["VOX_PROVIDER_CALL_TIMEOUT_MS"]
        if let millisecondsRaw,
           let milliseconds = TimeInterval(millisecondsRaw),
           milliseconds > 0
        {
            return milliseconds / 1000
        }

        return 30
    }

    private func startReadingStdout(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        // FileHandle.availableData blocks. Use a dedicated thread, not Swift's
        // cooperative executor or GCD's bounded global worker pool: both must
        // remain available to callers, timeout continuations, and message dispatch.
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "Vox provider stdout"
            var buffer = Data()
            while self?.processIsRunning == true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)

                while let newlineRange = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                    buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                    guard !lineData.isEmpty,
                          let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                        continue
                    }

                    self?.handleMessage(json)
                }
            }
        }
    }

    private func startReadingStderr(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            Thread.current.name = "Vox provider stderr"
            while self?.processIsRunning == true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                if let text = String(data: chunk, encoding: .utf8) {
                    self?.appendStderr(text)
                }
            }
        }
    }

    private func appendStderr(_ text: String) {
        queue.sync {
            _stderrOutput.append(text)
            if _stderrOutput.count > 4096 {
                _stderrOutput = String(_stderrOutput.suffix(4096))
            }
        }
    }

    private func handleMessage(_ json: [String: Any]) {
        // Response: has "id" field
        if let id = json["id"] as? Int {
            let continuation = queue.sync { pending.removeValue(forKey: id) }
            guard let continuation else { return }

            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                continuation.resume(throwing: StdioTransportError.rpcError(message))
            } else if let error = json["error"] as? String {
                continuation.resume(throwing: StdioTransportError.rpcError(error))
            } else if let result = json["result"] as? [String: Any] {
                nonisolated(unsafe) let value = result
                continuation.resume(returning: value)
            } else {
                continuation.resume(returning: [:])
            }
            return
        }

        // Notification: has "method" but no "id"
        if let method = json["method"] as? String, method == "progress",
           let params = json["params"] as? [String: Any] {
            let handler = queue.sync { _progressHandler }
            handler?(params)
        }
    }

    private func handleTermination(exitCode: Int32) {
        queue.sync { _isRunning = false }
        log.warning("External provider exited with code \(exitCode)")
        let stderr = queue.sync { _stderrOutput }
        cancelAllPending(error: StdioTransportError.processExited(exitCode: exitCode, stderr: stderr))
    }

    private func cancelAllPending(error: any Error) {
        let continuations = queue.sync { () -> [Int: CheckedContinuation<[String: Any], any Error>] in
            let copy = pending
            pending.removeAll()
            return copy
        }
        for (_, continuation) in continuations {
            continuation.resume(throwing: error)
        }
    }
}

public enum StdioTransportError: Error, LocalizedError {
    case invalidCommand
    case notRunning
    case stopped
    case serializationFailed
    case timeout(method: String)
    case rpcError(String)
    case processExited(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCommand:
            return "Provider command is empty or invalid"
        case .notRunning:
            return "Provider process is not running"
        case .stopped:
            return "Provider transport was stopped"
        case .serializationFailed:
            return "Failed to serialize JSON-RPC request"
        case .timeout(let method):
            return "Provider call timed out: \(method)"
        case .rpcError(let message):
            return "Provider error: \(message)"
        case .processExited(let code, let stderr):
            let detail = stderr.isEmpty ? "" : " — \(stderr.suffix(200))"
            return "Provider process exited with code \(code)\(detail)"
        }
    }
}
#endif
