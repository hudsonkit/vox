import AVFoundation
import Foundation
import VoxCore

public actor OpenAITTSProvider: TTSProvider {
    public static let providerID = "openai-tts"
    public static let supportedModelIDs = ["gpt-4o-mini-tts", "tts-1", "tts-1-hd"]
    static let defaultRequestTimeout: TimeInterval = 12
    static let maximumRequestTimeout: TimeInterval = 30
    public static let supportedVoices = [
        "alloy",
        "ash",
        "ballad",
        "cedar",
        "coral",
        "echo",
        "fable",
        "marin",
        "nova",
        "onyx",
        "sage",
        "shimmer",
        "verse"
    ]

    private let log = VoxLog.engine
    private let session: URLSession
    private let apiKey: String?
    private let baseURL: URL
    private let requestTimeout: TimeInterval
    private var preloadedModels: Set<String> = []

    public init(env: [String: String]? = nil, session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
        self.apiKey = env?["OPENAI_API_KEY"]
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        let rawBaseURL = env?["OPENAI_BASE_URL"]
            ?? ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
            ?? "https://api.openai.com/v1"
        self.baseURL = URL(string: rawBaseURL) ?? URL(string: "https://api.openai.com/v1")!
        self.requestTimeout = Self.resolveRequestTimeout(env: env)
    }

    public func models() async -> [TTSModelInfo] {
        let available = apiKeyAvailability()
        return Self.supportedModelIDs.map { modelId in
            TTSModelInfo(
                id: modelId,
                name: modelId,
                backend: "openai",
                installed: available,
                preloaded: preloadedModels.contains(modelId),
                available: available
            )
        }
    }

    public func voices(modelId: String?) async throws -> [TTSVoiceInfo] {
        let resolvedModelId = modelId ?? Self.supportedModelIDs[0]
        try validate(modelId: resolvedModelId)

        return Self.supportedVoices.map { voiceId in
            TTSVoiceInfo(
                id: voiceId,
                name: voiceId.capitalized,
                language: nil,
                backend: "openai",
                modelId: resolvedModelId,
                available: apiKeyAvailability(),
                isDefault: voiceId == "alloy"
            )
        }
    }

    public func voices(modelId: String?, providerCredentials: [String: String]) async throws -> [TTSVoiceInfo] {
        let voices = try await voices(modelId: modelId)
        guard RemoteTTSSupport.firstNonEmpty(providerCredentials["OPENAI_API_KEY"],
            providerCredentials["openaiApiKey"], providerCredentials["openai_api_key"]) != nil else { return voices }
        return voices.map { TTSVoiceInfo(id: $0.id, name: $0.name, language: $0.language,
            backend: $0.backend, modelId: $0.modelId, available: true, isDefault: $0.isDefault) }
    }

    public func preload(
        modelId: String,
        voiceId: String?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo {
        try validate(modelId: modelId)
        _ = try resolveAPIKey(providerCredentials: [:])
        if let voiceId {
            _ = try resolveVoice(voiceId: voiceId)
        }
        progress(ModelProgress(modelId: modelId, progress: 0.2, status: "starting"))
        preloadedModels.insert(modelId)
        progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
        return (await models()).first(where: { $0.id == modelId }) ?? TTSModelInfo(
            id: modelId,
            name: modelId,
            backend: "openai",
            installed: true,
            preloaded: true,
            available: true
        )
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput {
        try Task.checkCancellation()
        try validate(modelId: request.modelId)
        try validate(format: request.format)
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "VoxEngine", code: 5101, userInfo: [
                NSLocalizedDescriptionKey: "Missing text"
            ])
        }

        let trace = TranscriptionTrace()

        trace.begin("model_check")
        let apiKey = try resolveAPIKey(providerCredentials: request.providerCredentials)
        let wasPreloaded = preloadedModels.contains(request.modelId)
        trace.end(wasPreloaded ? "ready" : "cold")

        if !wasPreloaded {
            trace.begin("model_load")
            preloadedModels.insert(request.modelId)
            trace.end("prepared")
        }

        trace.begin("voice_resolve")
        let resolvedVoice = try resolveVoice(voiceId: request.voiceId)
        trace.end(resolvedVoice)

        trace.begin("inference")
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("audio/speech"))
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.httpMethod = "POST"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "model": request.modelId,
            "input": request.text,
            "voice": resolvedVoice,
            "response_format": request.format.lowercased()
        ]
        if let speed = request.speed {
            payload["speed"] = speed
        }
        if let instructions = request.instructions,
           request.modelId == "gpt-4o-mini-tts" {
            payload["instructions"] = instructions
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        log.info("OpenAI synthesis request started requestId=\(request.requestId) modelId=\(request.modelId) voiceId=\(resolvedVoice) textLength=\(request.text.count) timeoutInterval=\(urlRequest.timeoutInterval)s")
        let openAIStartedAt = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await performDataRequest(urlRequest, timeout: requestTimeout)
        } catch {
            if Task.isCancelled || RemoteTTSSupport.isCancellation(error) {
                log.info("OpenAI synthesis request cancelled requestId=\(request.requestId)")
                throw CancellationError()
            }
            let elapsedMs = Int(Date().timeIntervalSince(openAIStartedAt) * 1000)
            log.error("OpenAI synthesis request failed requestId=\(request.requestId) modelId=\(request.modelId) voiceId=\(resolvedVoice) elapsedMs=\(elapsedMs) error=\(error.localizedDescription)")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            let elapsedMs = Int(Date().timeIntervalSince(openAIStartedAt) * 1000)
            log.error("OpenAI synthesis request returned non-HTTP response requestId=\(request.requestId) elapsedMs=\(elapsedMs)")
            throw NSError(domain: "VoxEngine", code: 5102, userInfo: [
                NSLocalizedDescriptionKey: "OpenAI TTS request returned a non-HTTP response."
            ])
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let elapsedMs = Int(Date().timeIntervalSince(openAIStartedAt) * 1000)
            log.error("OpenAI synthesis request returned error requestId=\(request.requestId) status=\(httpResponse.statusCode) elapsedMs=\(elapsedMs) responseBytes=\(data.count)")
            throw NSError(domain: "VoxEngine", code: 5103, userInfo: [
                NSLocalizedDescriptionKey: "OpenAI TTS request failed: HTTP \(httpResponse.statusCode)"
            ])
        }
        let synthesisMs = trace.end("\(data.count) bytes")

        let audioDurationMs = try inspectWaveData(data)
        let metrics = SynthesisMetrics(
            traceId: trace.traceId,
            characterCount: request.text.count,
            audioDurationMs: audioDurationMs,
            outputBytes: data.count,
            wasPreloaded: wasPreloaded,
            modelCheckMs: trace.durationMs(for: "model_check"),
            modelLoadMs: trace.durationMs(for: "model_load"),
            voiceResolveMs: trace.durationMs(for: "voice_resolve"),
            synthesisMs: synthesisMs,
            totalMs: trace.elapsedMs
        )

        log.info("OpenAI synthesis trace complete \(trace.summary)")
        return SynthesisOutput(
            modelId: request.modelId,
            voiceId: resolvedVoice,
            format: request.format.lowercased(),
            contentType: httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "audio/wav",
            audioData: data,
            elapsedMs: metrics.totalMs,
            metrics: metrics
        )
    }

    private func apiKeyAvailability() -> Bool {
        guard let apiKey = apiKey ?? VoxCredentialStore().openAIAPIKey() else { return false }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resolveAPIKey(providerCredentials: [String: String]) throws -> String {
        let lentKey = providerCredentials["OPENAI_API_KEY"]
            ?? providerCredentials["openaiApiKey"]
            ?? providerCredentials["openai_api_key"]
        let resolvedKey = lentKey ?? apiKey ?? VoxCredentialStore().openAIAPIKey()
        guard let resolvedKey, !resolvedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "VoxEngine", code: 5104, userInfo: [
                NSLocalizedDescriptionKey: "Missing OPENAI_API_KEY for OpenAI TTS provider."
            ])
        }
        let key = resolvedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count <= 4096, key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw NSError(domain: "VoxEngine", code: 5110, userInfo: [
                NSLocalizedDescriptionKey: "Invalid OpenAI TTS credential header value."
            ])
        }
        return key
    }

    static func resolveRequestTimeout(
        env: [String: String]?,
        processEnv: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval {
        let rawValue = env?["VOX_OPENAI_TTS_TIMEOUT_SECONDS"]
            ?? env?["OPENAI_TTS_TIMEOUT_SECONDS"]
            ?? processEnv["VOX_OPENAI_TTS_TIMEOUT_SECONDS"]
            ?? processEnv["OPENAI_TTS_TIMEOUT_SECONDS"]
        guard
            let rawValue,
            let parsed = TimeInterval(rawValue),
            parsed > 0
        else {
            return defaultRequestTimeout
        }
        return min(parsed, maximumRequestTimeout)
    }

    private func performDataRequest(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            let session = self.session
            group.addTask {
                try await session.data(for: request)
            }
            group.addTask {
                let nanoseconds = UInt64((timeout * 1_000_000_000).rounded(.up))
                try await Task.sleep(nanoseconds: nanoseconds)
                throw NSError(domain: "VoxEngine", code: 5108, userInfo: [
                    NSLocalizedDescriptionKey: "OpenAI TTS request timed out after \(Self.formatTimeout(timeout))."
                ])
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw NSError(domain: "VoxEngine", code: 5109, userInfo: [
                    NSLocalizedDescriptionKey: "OpenAI TTS request ended without a response."
                ])
            }
            group.cancelAll()
            return result
        }
    }

    private static func formatTimeout(_ timeout: TimeInterval) -> String {
        if timeout.rounded() == timeout {
            return "\(Int(timeout)) seconds"
        }
        return "\(String(format: "%.2f", timeout)) seconds"
    }

    private func validate(modelId: String) throws {
        guard Self.supportedModelIDs.contains(modelId) else {
            throw NSError(domain: "VoxEngine", code: 5105, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported OpenAI TTS model: \(modelId)"
            ])
        }
    }

    private func validate(format: String) throws {
        guard format.lowercased() == TTSDefaults.format else {
            throw NSError(domain: "VoxEngine", code: 5106, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported synthesis format: \(format). OpenAI TTS is currently configured for wav output."
            ])
        }
    }

    private func resolveVoice(voiceId: String?) throws -> String {
        let resolvedVoice = (voiceId ?? "alloy").lowercased()
        guard Self.supportedVoices.contains(resolvedVoice) else {
            throw NSError(domain: "VoxEngine", code: 5107, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported OpenAI TTS voice: \(voiceId ?? resolvedVoice)"
            ])
        }
        return resolvedVoice
    }

    private func inspectWaveData(_ data: Data) throws -> Int {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-openai-\(UUID().uuidString)")
            .appendingPathExtension(TTSDefaults.format)
        try data.write(to: url, options: .atomic)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        let file = try AVAudioFile(forReading: url)
        let durationMs = Int((Double(file.length) / file.processingFormat.sampleRate) * 1000)
        return durationMs
    }
}
