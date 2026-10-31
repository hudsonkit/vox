import Foundation
import Darwin
import VoxCore
import HudsonSpeechEngine

private struct JSONRPCError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@main
struct VoxTTSRunner {
    private static let outputLock = NSLock()

    static func main() async {
        let engine = TTSEngineManager(provider: TTSProviderRegistry(config: defaultTTSConfig()))

        let requests = RequestServer(engine: engine)
        // A dedicated reader must continue accepting cancellation while synthesis
        // awaits HTTP/AVFoundation. Never block MainActor or the cooperative pool.
        await withCheckedContinuation { (eof: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                Thread.current.name = "Vox TTS stdin"
                defer { eof.resume() }
                var buffer = Data()
                var droppingOversizedLine = false
                func submit(_ data: Data) {
                    let accepted = DispatchSemaphore(value: 0)
                    Task { await requests.receive(data); accepted.signal() }
                    accepted.wait() // only this dedicated reader thread blocks
                }
                var bytes = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { break }
                    buffer.append(contentsOf: bytes.prefix(count))
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        if droppingOversizedLine || newline > 1024 * 1024 {
                            if !droppingOversizedLine { writeError(id: nil, message: "provider_request_too_large") }
                            buffer.removeSubrange(...newline); droppingOversizedLine = false; continue
                        }
                        let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                        if !line.isEmpty { submit(line) }
                    }
                    if droppingOversizedLine { buffer.removeAll() }
                    else if buffer.count > 1024 * 1024 {
                        writeError(id: nil, message: "provider_request_too_large")
                        buffer.removeAll(); droppingOversizedLine = true
                    }
                }
                if !droppingOversizedLine && !buffer.isEmpty { submit(buffer) }
            }
        }
        await requests.shutdown()
    }

    /// Actor admission is synchronous: cancellation/completion cannot race task
    /// registration. IDs belong to this helper's parent transport, never client UUIDs.
    private actor RequestServer {
        let engine: TTSEngineManager
        var tasks: [Int: Task<Void, Never>] = [:]
        init(engine: TTSEngineManager) { self.engine = engine }
        func receive(_ data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else {
                writeError(id: nil, message: "Invalid JSON-RPC request"); return
            }
            if method == "$/cancelRequest" {
                guard object["id"] == nil, let params = object["params"] as? [String: Any],
                      let id = params["id"] as? Int else { return }
                if let task = tasks[id] {
                    VoxLog.engine.info("TTS provider cancellation received id=\(id)")
                    task.cancel()
                }
                return // notification: never reply or cancel an unknown/future ID
            }
            guard let id = object["id"] as? Int else { writeError(id: nil, message: "Missing request id"); return }
            guard tasks[id] == nil else { writeError(id: id, message: "duplicate_request_id"); return }
            guard tasks.count < 16 else { writeError(id: id, message: "provider_busy: sixteen requests active"); return }
            VoxLog.engine.info("TTS provider request accepted id=\(id) method=\(method)")
            tasks[id] = Task {
                defer { tasks[id] = nil }
                do {
                    try Task.checkCancellation()
                    let response = try await execute(data, engine: engine)
                    try Task.checkCancellation()
                    writeData(response)
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError
                    writeError(id: id, message: cancelled ? "request_cancelled" : error.localizedDescription,
                               code: cancelled ? -32800 : -32000)
                }
            }
        }
        func shutdown() async {
            let accepted = Array(tasks.values)
            for task in accepted { task.cancel() }
            for task in accepted { await task.value }
        }
    }

    private static func execute(_ data: Data, engine: TTSEngineManager) async throws -> Data {
        guard let line = String(data: data, encoding: .utf8) else { throw JSONRPCError(message: "Invalid UTF-8") }
        let request = try parseRequest(line)
        let result = try await handle(request: request, engine: engine)
        return try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": request.id, "result": result])
    }

    private static func defaultTTSConfig() -> ProvidersConfig {
        TTSDefaultProviderConfig.inProcess()
    }

    private static func handle(
        request: JSONRPCRequest,
        engine: TTSEngineManager
    ) async throws -> [String: Any] {
        switch request.method {
        case "models":
            let models = await engine.models()
            return ["models": models.map { $0.dictionaryValue() }]

        case "voices":
            let voices = try await engine.voices(modelId: request.params["modelId"] as? String,
                providerCredentials: providerCredentials(from: request.params))
            return ["voices": voices.map { $0.dictionaryValue() }]

        case "preload":
            guard let modelId = request.params["modelId"] as? String else {
                throw JSONRPCError(message: "Missing modelId")
            }
            let voiceId = request.params["voiceId"] as? String
            let model = try await engine.preload(modelId: modelId, voiceId: voiceId) { progress in
                writeNotification(method: "progress", params: progress.dictionaryValue())
            }
            return ["model": model.dictionaryValue()]

        case "synthesize":
            let text = (request.params["input"] as? String)
                ?? (request.params["text"] as? String)
                ?? ""
            let modelId = (request.params["modelId"] as? String) ?? TTSDefaults.modelId
            let format = (request.params["format"] as? String) ?? TTSDefaults.format
            let synthesisRequest = SynthesisRequest(
                requestId: (request.params["requestId"] as? String) ?? UUID().uuidString,
                text: text,
                modelId: modelId,
                voiceId: request.params["voiceId"] as? String,
                format: format,
                speed: request.params["speed"] as? Double,
                instructions: request.params["instructions"] as? String,
                providerCredentials: providerCredentials(from: request.params)
            )
            let output = try await engine.synthesize(synthesisRequest)
            return output.dictionaryValue()

        default:
            throw JSONRPCError(message: "Unknown method: \(request.method)")
        }
    }

    private static func parseRequest(_ line: String) throws -> JSONRPCRequest {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int,
              let method = object["method"] as? String else {
            throw JSONRPCError(message: "Invalid JSON-RPC request")
        }

        return JSONRPCRequest(
            id: id,
            method: method,
            params: object["params"] as? [String: Any] ?? [:]
        )
    }

    private static func providerCredentials(from params: [String: Any]) -> [String: String] {
        TTSLentCredentials.parse(from: params)
    }

    private static func writeError(id: Int?, message: String, code: Int = -32000) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        if let id {
            response["id"] = id
        } else {
            response["id"] = NSNull()
        }
        writeJSON(response)
    }

    private static func writeNotification(method: String, params: [String: Any]) {
        writeJSON([
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ])
    }

    private static func writeJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            fputs("voxttsd failed to encode response\n", stderr); return
        }
        writeData(data)
    }
    private static func writeData(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8) else { return }
        outputLock.lock()
        print(line); fflush(stdout)
        outputLock.unlock()
    }

}

private struct JSONRPCRequest {
    let id: Int
    let method: String
    let params: [String: Any]
}
