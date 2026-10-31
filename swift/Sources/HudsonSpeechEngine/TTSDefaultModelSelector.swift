import Foundation
import VoxCore

public enum TTSDefaultModelSelector {
    public static func defaultModelId(
        for config: ProvidersConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let entries = config.providers.filter { $0.resolvedKind == .tts }
        let availableConfiguredModels = entries.flatMap { entry -> [String] in
            guard isAvailableForDefaultSelection(entry, environment: environment) else {
                return []
            }
            return entry.models ?? []
        }

        if let preferred = preferredModelId(from: availableConfiguredModels) {
            return preferred
        }

        let configuredModels = entries.flatMap { $0.models ?? [] }
        return preferredModelId(from: configuredModels) ?? TTSDefaults.modelId
    }

    public static func defaultModelId(from models: [TTSModelInfo]) -> String {
        let available = models.filter { $0.available && $0.installed }
        let candidates = available.isEmpty ? models : available
        return preferredModelId(from: candidates.map(\.id)) ?? TTSDefaults.modelId
    }

    public static func preferredModelId(from modelIds: [String]) -> String? {
        let unique = Set(modelIds)
        guard !unique.isEmpty else {
            return nil
        }
        if unique.contains(TTSDefaults.modelId) {
            return TTSDefaults.modelId
        }
        for family in TTSProviderFamily.defaultSelectionOrder {
            if let modelId = family.rankedModelIDs.first(where: { unique.contains($0) }) {
                return modelId
            }
        }
        if unique.contains(TTSDefaults.localModelId) {
            return TTSDefaults.localModelId
        }
        return modelIds.first
    }

    private static func isAvailableForDefaultSelection(
        _ entry: ProviderEntry,
        environment: [String: String]
    ) -> Bool {
        switch TTSProviderFamily(providerId: entry.id) {
        case .openai:
            return hasValue(entry.env?["OPENAI_API_KEY"])
                || hasValue(environment["OPENAI_API_KEY"])
        case .elevenlabs:
            return ElevenLabsTTSProvider.resolveAPIKey(providerCredentials: [:], env: entry.env,
                processEnv: environment) != nil
        case .minimax:
            return hasValue(entry.env?["MINIMAX_API_KEY"])
                || hasValue(environment["MINIMAX_API_KEY"])
        case .nvidia:
            return NVIDIAMagpieTTSProvider.resolveConfiguredAPIKey(
                env: entry.env,
                processEnv: environment
            ) != nil
        case .groq:
            return GroqTTSProvider.resolveConfiguredAPIKey(
                env: entry.env,
                processEnv: environment
            ) != nil
        case .gemini:
            return GeminiTTSProvider.resolveConfiguredAPIKey(
                env: entry.env,
                processEnv: environment
            ) != nil
        case .avspeech, .mlxAudio, nil:
            return true
        }
    }

    private static func hasValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
