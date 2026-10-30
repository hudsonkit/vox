import Foundation
import VoxCore

public actor TTSProviderRegistry: TTSProvider {
    private let log = VoxLog.engine
    private var providers: [(entry: ProviderEntry, provider: any TTSProvider)] = []
    private var modelRouting: [String: any TTSProvider] = [:]

    public init(config: ProvidersConfig) {
        for entry in config.providers where entry.resolvedKind == .tts {
            let provider: any TTSProvider

            if entry.isBuiltin {
                switch TTSProviderFamily(providerId: entry.id) {
                case .avspeech:
                    provider = AVSpeechSynthesizerProvider()
                case .openai:
                    provider = OpenAITTSProvider(env: entry.env)
                case .elevenlabs:
                    provider = ElevenLabsTTSProvider(env: entry.env)
                case .minimax:
                    provider = MiniMaxTTSProvider(env: entry.env)
                case .nvidia:
                    provider = NVIDIAMagpieTTSProvider(env: entry.env)
                case .groq:
                    provider = GroqTTSProvider(env: entry.env)
                case .gemini:
                    provider = GeminiTTSProvider(env: entry.env)
                case .mlxAudio:
                    #if os(macOS)
                    do {
                        let env = BuiltinExternalProvider.mlxAudioEnvironment(entry.env)
                        let command = try BuiltinExternalProvider.mlxAudioCommand(kind: .tts, env: env)
                        provider = ExternalTTSProvider(id: entry.id, command: command, env: env)
                    } catch {
                        log.error("Skipping builtin TTS provider \(entry.id): \(error.localizedDescription)")
                        continue
                    }
                    #else
                    // External subprocess providers require Process (macOS only).
                    log.warning("mlx-audio TTS provider unavailable on this platform: \(entry.id)")
                    continue
                    #endif
                default:
                    log.warning("Skipping unknown builtin TTS provider: \(entry.id)")
                    continue
                }
                log.info("Registered builtin TTS provider: \(entry.id)")
            } else if entry.isExternal, let command = entry.command {
                #if os(macOS)
                provider = ExternalTTSProvider(id: entry.id, command: command, env: entry.env)
                log.info("Registered external TTS provider: \(entry.id) → \(command.joined(separator: " "))")
                #else
                log.warning("External TTS providers unavailable on this platform: \(entry.id)")
                continue
                #endif
            } else {
                log.warning("Skipping TTS provider \(entry.id): no builtin flag or command specified")
                continue
            }

            providers.append((entry: entry, provider: provider))

            if let models = entry.models {
                for modelId in models {
                    modelRouting[modelId] = provider
                }
            }
        }
    }

    public func models() async -> [TTSModelInfo] {
        await withTaskGroup(of: [TTSModelInfo].self) { group in
            for (entry, provider) in providers {
                group.addTask {
                    #if os(macOS)
                    if let models = entry.models,
                       provider is ExternalTTSProvider {
                        return models.map { modelId in
                            TTSModelInfo(
                                id: modelId,
                                name: Self.displayName(for: modelId),
                                backend: entry.id,
                                installed: true,
                                preloaded: false,
                                available: true
                            )
                        }
                    }
                    #endif

                    return await provider.models()
                }
            }

            var all: [TTSModelInfo] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all.sorted { lhs, rhs in
                lhs.id.localizedCaseInsensitiveCompare(rhs.id) == .orderedAscending
            }
        }
    }

    public func voices(modelId: String?, providerCredentials: [String: String]) async throws -> [TTSVoiceInfo] {
        guard !providerCredentials.isEmpty else { return try await voices(modelId: modelId) }
        guard let modelId else { throw TTSVoiceCredentialsError.modelRequired }
        let provider = try await resolveProvider(for: modelId)
        return try await provider.voices(modelId: modelId, providerCredentials: providerCredentials)
    }

    public func voices(modelId: String?) async throws -> [TTSVoiceInfo] {
        if let modelId {
            let provider = try await resolveProvider(for: modelId)
            return try await provider.voices(modelId: modelId)
        }

        let models = await self.models()
        return try await withThrowingTaskGroup(of: [TTSVoiceInfo].self) { group in
            for model in models {
                group.addTask {
                    let provider = try await self.resolveProvider(for: model.id)
                    return try await provider.voices(modelId: model.id)
                }
            }

            var all: [TTSVoiceInfo] = []
            for try await batch in group {
                all.append(contentsOf: batch)
            }
            return all.sorted { lhs, rhs in
                if lhs.modelId == rhs.modelId {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.modelId.localizedCaseInsensitiveCompare(rhs.modelId) == .orderedAscending
            }
        }
    }

    public func preload(
        modelId: String,
        voiceId: String?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo {
        let provider = try await resolveProvider(for: modelId)
        return try await provider.preload(modelId: modelId, voiceId: voiceId, progress: progress)
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput {
        let provider = try await resolveProvider(for: request.modelId)
        return try await provider.synthesize(request)
    }

    public func shutdown() async {
        #if os(macOS)
        for (_, provider) in providers {
            if let externalProvider = provider as? ExternalTTSProvider {
                await externalProvider.shutdown()
            }
        }
        #endif
    }

    private func resolveProvider(for modelId: String) async throws -> any TTSProvider {
        if let provider = modelRouting[modelId] {
            return provider
        }

        if providers.count == 1 {
            return providers[0].provider
        }

        for (_, provider) in providers {
            let models = await provider.models()
            if models.contains(where: { $0.id == modelId }) {
                for model in models {
                    modelRouting[model.id] = provider
                }
                return provider
            }
        }

        throw TTSProviderRegistryError.unknownModel(modelId)
    }

    private nonisolated static func displayName(for modelId: String) -> String {
        modelId.split(separator: "/").last.map(String.init) ?? modelId
    }
}

public enum TTSProviderRegistryError: Error, LocalizedError {
    case unknownModel(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id):
            return "No TTS provider registered for model '\(id)'"
        }
    }
}
