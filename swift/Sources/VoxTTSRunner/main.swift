import Foundation
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

        while let line = readLine() {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            do {
                let request = try parseRequest(line)
                let result = try await handle(request: request, engine: engine)
                writeResponse(id: request.id, result: result)
            } catch {
                let id = requestId(from: line)
                writeError(id: id, message: error.localizedDescription)
            }
        }
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

    private static func requestId(from line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["id"] as? Int
    }

    private static func providerCredentials(from params: [String: Any]) -> [String: String] {
        TTSLentCredentials.parse(from: params)
    }

    private static func writeResponse(id: Int, result: [String: Any]) {
        writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        ])
    }

    private static func writeError(id: Int?, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": -32000,
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
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let line = String(data: data, encoding: .utf8) else {
                return
            }
            outputLock.lock()
            print(line)
            fflush(stdout)
            outputLock.unlock()
        } catch {
            fputs("voxttsd failed to encode response: \(error.localizedDescription)\n", stderr)
        }
    }
}

private struct JSONRPCRequest {
    let id: Int
    let method: String
    let params: [String: Any]
}
