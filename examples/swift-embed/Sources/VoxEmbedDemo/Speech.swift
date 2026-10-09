import Foundation
import VoxCore
import VoxEngine

/// Speech output. With an OpenAI key it uses `gpt-4o-mini-tts`; without one
/// it uses the local system voice. Vox routes by model id and does not fall
/// back on its own, so the choice is made here.
func makeSpeech(openAIAPIKey: String?) -> (engine: TTSEngineManager, modelId: String) {
    var providers = [
        ProviderEntry(id: "avspeech", kind: .tts, builtin: true, models: [AVSpeechSynthesizerProvider.modelID])
    ]
    var modelId = TTSDefaults.localModelId
    if let openAIAPIKey, !openAIAPIKey.isEmpty {
        providers.append(ProviderEntry(
            id: "openai-tts",
            kind: .tts,
            builtin: true,
            models: OpenAITTSProvider.supportedModelIDs,
            env: ["OPENAI_API_KEY": openAIAPIKey]
        ))
        modelId = TTSDefaults.modelId
    }
    let engine = TTSEngineManager(provider: TTSProviderRegistry(config: ProvidersConfig(providers: providers)))
    return (engine, modelId)
}
