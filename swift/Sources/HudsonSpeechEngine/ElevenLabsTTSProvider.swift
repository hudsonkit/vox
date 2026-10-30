import AVFoundation
import Foundation
import VoxCore

public actor ElevenLabsTTSProvider: TTSProvider {
    public static let providerID = "elevenlabs"
    public static let supportedModelIDs = [
        "eleven_multilingual_v2",
        "eleven_turbo_v2_5",
        "eleven_flash_v2_5"
    ]
    public static let defaultVoiceID = "JBFqnCBsd6RMkjVDRZzb"

    private static let defaultBaseURL = "https://api.elevenlabs.io"
    private static let defaultOutputFormat = "wav_44100"

    private let log = VoxLog.engine
    private let session: URLSession
    private let apiKey: String?
    private let baseURL: URL
    private let outputFormat: String
    private var preloadedModels: Set<String> = []

    public init(env: [String: String]? = nil, session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration)
        self.apiKey = Self.resolveAPIKey(providerCredentials: [:], env: env,
                                         processEnv: ProcessInfo.processInfo.environment)
        let rawBaseURL = env?["ELEVENLABS_BASE_URL"]
            ?? ProcessInfo.processInfo.environment["ELEVENLABS_BASE_URL"]
            ?? Self.defaultBaseURL
        self.baseURL = URL(string: rawBaseURL) ?? URL(string: Self.defaultBaseURL)!
        self.outputFormat = env?["ELEVENLABS_OUTPUT_FORMAT"]
            ?? ProcessInfo.processInfo.environment["ELEVENLABS_OUTPUT_FORMAT"]
            ?? Self.defaultOutputFormat
    }

    public func models() async -> [TTSModelInfo] {
        let available = apiKeyAvailability()
        return Self.supportedModelIDs.map { modelId in
            TTSModelInfo(
                id: modelId,
                name: modelId,
                backend: Self.providerID,
                installed: available,
                preloaded: preloadedModels.contains(modelId),
                available: available
            )
        }
    }

    public func voices(modelId: String?) async throws -> [TTSVoiceInfo] {
        try await voices(modelId: modelId, providerCredentials: [:])
    }

    public func voices(modelId: String?, providerCredentials: [String: String]) async throws -> [TTSVoiceInfo] {
        let resolvedModelId = modelId ?? Self.supportedModelIDs[0]
        try validate(modelId: resolvedModelId)

        guard resolvedAPIKey(providerCredentials: providerCredentials) != nil else {
            return [
                TTSVoiceInfo(
                    id: Self.defaultVoiceID,
                    name: "ElevenLabs Default",
                    language: nil,
                    backend: Self.providerID,
                    modelId: resolvedModelId,
                    available: false,
                    isDefault: true
                )
            ]
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("v2/voices"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "page_size", value: "100")
        ]
        guard let url = components?.url else {
            throw ElevenLabsTTSProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(try resolveAPIKey(providerCredentials: providerCredentials), forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await RemoteTTSSupport.data(for: request, session: session)
        try validateHTTPResponse(response: response)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = object["voices"] as? [[String: Any]] else {
            throw ElevenLabsTTSProviderError.invalidResponse("voices")
        }

        let parsed = voices.compactMap { voice -> TTSVoiceInfo? in
            guard let id = voice["voice_id"] as? String,
                  let name = voice["name"] as? String else {
                return nil
            }

            let language = (voice["verified_languages"] as? [[String: Any]])?
                .compactMap { $0["locale"] as? String ?? $0["language"] as? String }
                .first

            return TTSVoiceInfo(
                id: id,
                name: name,
                language: language,
                backend: Self.providerID,
                modelId: resolvedModelId,
                available: true,
                isDefault: id == Self.defaultVoiceID
            )
        }

        if parsed.contains(where: { $0.isDefault }) {
            return parsed
        }

        return parsed.enumerated().map { index, voice in
            TTSVoiceInfo(
                id: voice.id,
                name: voice.name,
                language: voice.language,
                backend: voice.backend,
                modelId: voice.modelId,
                available: voice.available,
                isDefault: index == 0
            )
        }
    }

    public func preload(
        modelId: String,
        voiceId: String?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo {
        try validate(modelId: modelId)
        _ = try resolveAPIKey()
        progress(ModelProgress(modelId: modelId, progress: 0.2, status: "starting"))
        preloadedModels.insert(modelId)
        progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
        return (await models()).first(where: { $0.id == modelId }) ?? TTSModelInfo(
            id: modelId,
            name: modelId,
            backend: Self.providerID,
            installed: true,
            preloaded: true,
            available: true
        )
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput {
        try validate(modelId: request.modelId)
        try validate(format: request.format)
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ElevenLabsTTSProviderError.missingText
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
        let resolvedVoice = request.voiceId ?? Self.defaultVoiceID
        trace.end(resolvedVoice)

        trace.begin("inference")
        var components = URLComponents(
            url: baseURL.appendingPathComponent("v1/text-to-speech/\(resolvedVoice)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "output_format", value: outputFormat)
        ]
        guard let url = components?.url else {
            throw ElevenLabsTTSProviderError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "text": request.text,
            "model_id": request.modelId
        ]
        if let speed = request.speed {
            payload["voice_settings"] = ["speed": speed]
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await RemoteTTSSupport.data(for: urlRequest, session: session)
        let httpResponse = try validateHTTPResponse(response: response)
        let synthesisMs = trace.end("\(data.count) bytes")

        guard PCMWAV.isStructurallyValid(data) else {
            throw ElevenLabsTTSProviderError.invalidResponse("synthesize audio (expected WAV)")
        }
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

        log.info("ElevenLabs synthesis trace complete \(trace.summary)")
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
        guard let apiKey else { return false }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func resolveAPIKey(
        providerCredentials: [String: String], env: [String: String]?, processEnv: [String: String]
    ) -> String? {
        RemoteTTSSupport.resolveSecret(
            lentValues: [providerCredentials["ELEVENLABS_API_KEY"], providerCredentials["elevenlabsApiKey"],
                         providerCredentials["elevenlabs_api_key"]],
            env: env, processEnv: processEnv,
            keys: ["ELEVENLABS_API_KEY"])
    }

    private func resolvedAPIKey(providerCredentials: [String: String]) -> String? {
        RemoteTTSSupport.firstNonEmpty(providerCredentials["ELEVENLABS_API_KEY"],
            providerCredentials["elevenlabsApiKey"], providerCredentials["elevenlabs_api_key"], apiKey)
    }

    private func resolveAPIKey(providerCredentials: [String: String] = [:]) throws -> String {
        guard let key = resolvedAPIKey(providerCredentials: providerCredentials) else {
            throw ElevenLabsTTSProviderError.missingAPIKey
        }
        guard key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw ElevenLabsTTSProviderError.invalidAPIKey
        }
        return key
    }

    private func validate(modelId: String) throws {
        guard Self.supportedModelIDs.contains(modelId) else {
            throw ElevenLabsTTSProviderError.unsupportedModel(modelId)
        }
    }

    private func validate(format: String) throws {
        guard format.lowercased() == TTSDefaults.format else {
            throw ElevenLabsTTSProviderError.unsupportedFormat(format)
        }
    }

    @discardableResult
    private func validateHTTPResponse(response: URLResponse) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ElevenLabsTTSProviderError.nonHTTPResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            // A vendor body can echo credentials or user text. Never propagate it to logs/history.
            throw ElevenLabsTTSProviderError.requestFailed("HTTP \(httpResponse.statusCode)")
        }

        return httpResponse
    }

    private func inspectWaveData(_ data: Data) throws -> Int {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-elevenlabs-\(UUID().uuidString)")
            .appendingPathExtension(TTSDefaults.format)
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        return Int((Double(file.length) / file.processingFormat.sampleRate) * 1000)
    }
}

public enum ElevenLabsTTSProviderError: Error, LocalizedError {
    case missingText
    case missingAPIKey
    case invalidAPIKey
    case unsupportedModel(String)
    case unsupportedFormat(String)
    case invalidURL
    case nonHTTPResponse
    case requestFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingText:
            return "Missing text"
        case .missingAPIKey:
            return "Missing ELEVENLABS_API_KEY for ElevenLabs TTS provider."
        case .invalidAPIKey:
            return "Invalid ElevenLabs API key header value."
        case .unsupportedModel(let modelId):
            return "Unsupported ElevenLabs TTS model: \(modelId)"
        case .unsupportedFormat(let format):
            return "Unsupported synthesis format: \(format). ElevenLabs TTS is currently configured for wav output."
        case .invalidURL:
            return "Invalid ElevenLabs TTS API URL."
        case .nonHTTPResponse:
            return "ElevenLabs TTS request returned a non-HTTP response."
        case .requestFailed(let message):
            return "ElevenLabs TTS request failed: \(message)"
        case .invalidResponse(let method):
            return "Invalid ElevenLabs TTS response for \(method)."
        }
    }
}
