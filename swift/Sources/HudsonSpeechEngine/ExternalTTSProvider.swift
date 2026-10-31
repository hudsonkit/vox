#if os(macOS)
import Foundation
import VoxCore

public actor ExternalTTSProvider: TTSProvider {
    private let log = VoxLog.engine
    private let providerId: String
    private let command: [String]
    private let env: [String: String]?
    private let supportsRequestCancellation: Bool
    private var transport: StdioTransport?

    private var crashCount: Int = 0
    private var lastStableTime: Date = Date()
    private let maxCrashRestarts = 5
    private let stabilityWindow: TimeInterval = 60

    public init(id: String, command: [String], env: [String: String]? = nil, supportsRequestCancellation: Bool = false) {
        self.providerId = id
        self.command = command
        self.env = env
        self.supportsRequestCancellation = supportsRequestCancellation
    }

    deinit {
        transport?.stop()
    }

    public func shutdown() {
        transport?.stop()
        transport = nil
    }

    public func models() async -> [TTSModelInfo] {
        do {
            let transport = try ensureRunning()
            let result = try await transport.call(method: "models")
            guard let models = result["models"] as? [[String: Any]] else {
                return []
            }
            return models.compactMap { parseModelInfo($0) }
        } catch {
            log.error("Provider \(self.providerId) models() failed: \(error.localizedDescription)")
            return []
        }
    }

    public func voices(modelId: String?) async throws -> [TTSVoiceInfo] {
        try await voices(modelId: modelId, providerCredentials: [:])
    }

    public func voices(modelId: String?, providerCredentials: [String: String]) async throws -> [TTSVoiceInfo] {
        let transport = try ensureRunning()
        var params: [String: Any] = [:]
        if let modelId {
            params["modelId"] = modelId
        }

        if !providerCredentials.isEmpty { params["credentials"] = providerCredentials }

        let result = if params.isEmpty {
            try await transport.call(method: "voices")
        } else {
            try await transport.call(method: "voices", params: params)
        }
        guard let voices = result["voices"] as? [[String: Any]] else {
            throw ExternalTTSProviderError.invalidResponse("voices")
        }
        return voices.compactMap { parseVoiceInfo($0, requestedModelId: modelId) }
    }

    public func preload(
        modelId: String,
        voiceId: String?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo {
        let transport = try ensureRunning()
        transport.setProgressHandler { params in
            if let modelId = params["modelId"] as? String,
               let prog = params["progress"] as? Double,
               let status = params["status"] as? String {
                progress(ModelProgress(modelId: modelId, progress: prog, status: status))
            }
        }
        defer { transport.clearProgressHandler() }

        var params: [String: Any] = ["modelId": modelId]
        if let voiceId {
            params["voiceId"] = voiceId
        }

        let result = try await transport.call(method: "preload", params: params)
        guard let model = result["model"] as? [String: Any],
              let info = parseModelInfo(model) else {
            throw ExternalTTSProviderError.invalidResponse("preload")
        }
        return info
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput {
        let transport = try ensureRunning()
        var params: [String: Any] = [
            "requestId": request.requestId,
            "input": request.text,
            "modelId": request.modelId,
            "format": request.format
        ]
        if let voiceId = request.voiceId {
            params["voiceId"] = voiceId
        }
        if let speed = request.speed {
            params["speed"] = speed
        }
        if let instructions = request.instructions {
            params["instructions"] = instructions
        }
        if !request.providerCredentials.isEmpty {
            params["credentials"] = request.providerCredentials
        }

        let result = try await transport.call(method: "synthesize", params: params)
        try Task.checkCancellation()
        guard let modelId = result["modelId"] as? String else {
            throw ExternalTTSProviderError.invalidResponse("synthesize")
        }
        let voiceId = (result["voiceId"] as? String) ?? request.voiceId ?? ""
        let format = (result["format"] as? String) ?? request.format
        let contentType = (result["contentType"] as? String) ?? "audio/wav"
        let audioBase64 = (result["audioBase64"] as? String) ?? ""
        guard let audioData = Data(base64Encoded: audioBase64) else {
            throw ExternalTTSProviderError.invalidResponse("synthesize.audioBase64")
        }

        let elapsedMs = (result["elapsedMs"] as? Int) ?? 0
        let metricsDict = result["metrics"] as? [String: Any]
        let traceId = (metricsDict?["traceId"] as? String)
            ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let synthesisMs = (metricsDict?["synthesisMs"] as? Int) ?? (metricsDict?["inferenceMs"] as? Int) ?? elapsedMs

        let metrics = SynthesisMetrics(
            traceId: traceId,
            characterCount: (metricsDict?["characterCount"] as? Int) ?? request.text.count,
            audioDurationMs: (metricsDict?["audioDurationMs"] as? Int) ?? 0,
            outputBytes: (metricsDict?["outputBytes"] as? Int) ?? audioData.count,
            wasPreloaded: (metricsDict?["wasPreloaded"] as? Bool) ?? false,
            modelCheckMs: (metricsDict?["modelCheckMs"] as? Int) ?? 0,
            modelLoadMs: (metricsDict?["modelLoadMs"] as? Int) ?? 0,
            voiceResolveMs: (metricsDict?["voiceResolveMs"] as? Int) ?? 0,
            synthesisMs: synthesisMs,
            totalMs: (metricsDict?["totalMs"] as? Int) ?? elapsedMs
        )

        return SynthesisOutput(
            modelId: modelId,
            voiceId: voiceId,
            format: format,
            contentType: contentType,
            audioData: audioData,
            elapsedMs: elapsedMs,
            metrics: metrics
        )
    }

    private func ensureRunning() throws -> StdioTransport {
        if let transport, transport.processIsRunning {
            if Date().timeIntervalSince(lastStableTime) > stabilityWindow {
                crashCount = 0
            }
            lastStableTime = Date()
            return transport
        }

        guard crashCount < maxCrashRestarts else {
            let stderr = transport?.lastStderrOutput ?? ""
            throw ExternalTTSProviderError.tooManyCrashes(providerId: providerId, stderr: stderr)
        }

        crashCount += 1
        log.info("Starting TTS provider \(self.providerId) (attempt \(self.crashCount)/\(self.maxCrashRestarts))")

        let newTransport = StdioTransport(command: command, env: env, supportsRequestCancellation: supportsRequestCancellation)
        try newTransport.start()
        self.transport = newTransport
        lastStableTime = Date()
        return newTransport
    }

    private func parseModelInfo(_ dict: [String: Any]) -> TTSModelInfo? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else {
            return nil
        }

        return TTSModelInfo(
            id: id,
            name: name,
            backend: (dict["backend"] as? String) ?? providerId,
            installed: (dict["installed"] as? Bool) ?? true,
            preloaded: (dict["preloaded"] as? Bool) ?? false,
            available: (dict["available"] as? Bool) ?? true
        )
    }

    private func parseVoiceInfo(_ dict: [String: Any], requestedModelId: String?) -> TTSVoiceInfo? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else {
            return nil
        }

        let backend = (dict["backend"] as? String) ?? providerId
        // The bundled native provider reports platform evidence. Other backends
        // do not have a normalized native quality contract.
        let quality = backend == "avspeech"
            ? (dict["quality"] as? String).flatMap(TTSVoiceQuality.init(rawValue:)) : nil
        return TTSVoiceInfo(
            id: id,
            name: name,
            language: dict["language"] as? String,
            backend: backend,
            modelId: (dict["modelId"] as? String) ?? requestedModelId ?? TTSDefaults.modelId,
            available: (dict["available"] as? Bool) ?? true,
            isDefault: (dict["default"] as? Bool) ?? false,
            quality: quality
        )
    }
}

public enum ExternalTTSProviderError: Error, LocalizedError {
    case invalidResponse(String)
    case tooManyCrashes(providerId: String, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse(let method):
            return "Invalid response from external TTS provider for \(method)"
        case .tooManyCrashes(let id, let stderr):
            let detail = stderr.isEmpty ? "" : " — \(stderr.suffix(200))"
            return "TTS provider '\(id)' crashed too many times\(detail)"
        }
    }
}
#endif
