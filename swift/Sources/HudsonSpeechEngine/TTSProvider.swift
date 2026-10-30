import Foundation
import VoxCore

public enum TTSDefaults {
    public static let modelId = "gpt-4o-mini-tts"
    public static let localModelId = "avspeech:system"
    public static let format = "wav"
}

public enum TTSDefaultProviderConfig {
    public static func inProcess() -> ProvidersConfig {
        ProvidersConfig(providers: [
            ProviderEntry(
                id: "openai-tts",
                kind: .tts,
                builtin: true,
                models: OpenAITTSProvider.supportedModelIDs
            ),
            ProviderEntry(
                id: "elevenlabs",
                kind: .tts,
                builtin: true,
                models: ElevenLabsTTSProvider.supportedModelIDs
            ),
            ProviderEntry(
                id: "minimax",
                kind: .tts,
                builtin: true,
                models: MiniMaxTTSProvider.supportedModelIDs
            ),
            ProviderEntry(
                id: "nvidia",
                kind: .tts,
                builtin: true,
                models: NVIDIAMagpieTTSProvider.supportedModelIDs
            ),
            ProviderEntry(
                id: "groq",
                kind: .tts,
                builtin: true,
                models: GroqTTSProvider.supportedModelIDs
            ),
            ProviderEntry(
                id: "gemini",
                kind: .tts,
                builtin: true,
                models: GeminiTTSProvider.supportedModelIDs
            ),
            ProviderEntry(
                id: "avspeech",
                kind: .tts,
                builtin: true,
                models: [AVSpeechSynthesizerProvider.modelID]
            )
        ])
    }

    public static func mergingMissingDefaults(into config: ProvidersConfig) -> ProvidersConfig {
        let existingTTS = config.providers.filter { $0.resolvedKind == .tts }
        let existingIds = Set(existingTTS.map { $0.id.lowercased() })
        let existingFamilies = Set(existingTTS.compactMap { TTSProviderFamily(providerId: $0.id) })

        let additionalProviders = inProcess().providers.filter { entry in
            guard entry.resolvedKind == .tts else { return false }
            if existingIds.contains(entry.id.lowercased()) {
                return false
            }
            if let family = TTSProviderFamily(providerId: entry.id), existingFamilies.contains(family) {
                return false
            }
            return true
        }

        guard !additionalProviders.isEmpty else {
            return config
        }

        return ProvidersConfig(providers: config.providers + additionalProviders)
    }
}

public struct SynthesisRequest: Sendable, Equatable {
    public let requestId: String
    public let text: String
    public let modelId: String
    public let voiceId: String?
    public let format: String
    public let speed: Double?
    public let instructions: String?
    public let providerCredentials: [String: String]

    public init(
        requestId: String = UUID().uuidString,
        text: String,
        modelId: String = TTSDefaults.modelId,
        voiceId: String? = nil,
        format: String = TTSDefaults.format,
        speed: Double? = nil,
        instructions: String? = nil,
        providerCredentials: [String: String] = [:]
    ) {
        self.requestId = requestId
        self.text = text
        self.modelId = modelId
        self.voiceId = voiceId
        self.format = format
        self.speed = speed
        self.instructions = instructions
        self.providerCredentials = providerCredentials
    }
}

public protocol TTSProvider: Sendable {
    func models() async -> [TTSModelInfo]
    func voices(modelId: String?) async throws -> [TTSVoiceInfo]
    func voices(modelId: String?, providerCredentials: [String: String]) async throws -> [TTSVoiceInfo]
    func preload(
        modelId: String,
        voiceId: String?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput
}

public enum TTSVoiceCredentialsError: Error, LocalizedError, Sendable {
    case unsupported, modelRequired
    public var errorDescription: String? {
        switch self {
        case .unsupported: return "This provider does not support scoped credentials for voice discovery"
        case .modelRequired: return "Scoped voice credentials require an explicit modelId"
        }
    }
}

extension TTSProvider {
    public func voices(modelId: String?, providerCredentials: [String: String]) async throws -> [TTSVoiceInfo] {
        guard providerCredentials.isEmpty else { throw TTSVoiceCredentialsError.unsupported }
        return try await voices(modelId: modelId)
    }
}

public actor TTSEngineManager {
    private let provider: any TTSProvider

    public init() {
        self.provider = TTSProviderRegistry(config: TTSDefaultProviderConfig.inProcess())
    }

    public init(provider: any TTSProvider) {
        self.provider = provider
    }

    public func models() async -> [TTSModelInfo] {
        await provider.models()
    }

    public func voices(modelId: String? = nil, providerCredentials: [String: String] = [:]) async throws -> [TTSVoiceInfo] {
        try await provider.voices(modelId: modelId, providerCredentials: providerCredentials)
    }

    public func preload(
        modelId: String,
        voiceId: String? = nil,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo {
        try await provider.preload(modelId: modelId, voiceId: voiceId, progress: progress)
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput {
        try await provider.synthesize(request)
    }
}
