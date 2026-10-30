import Dispatch
import Foundation
import VoxCore
import HudsonSpeechEngine
import VoxService

#if canImport(Darwin)
import Darwin
#endif

let log = VoxLog.daemon

func parsePort() -> UInt16 {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--port"), arguments.indices.contains(index + 1) else {
        return VoxDefaults.resolvedDaemonPort()
    }

    return UInt16(arguments[index + 1]) ?? VoxDefaults.resolvedDaemonPort()
}

func defaultASRConfig() -> ProvidersConfig {
    let catalog = ModelCatalogStore.shared
    let parakeetModels = catalog.parakeetModelIDs()
    let appleSpeechModels = catalog.appleSpeechModelIDs()
    let openaiModels = catalog.openaiTranscribeModelIDs()
    return ProvidersConfig(providers: [
        ProviderEntry(id: "native-streaming", kind: .asr, builtin: true),
        ProviderEntry(
            id: "parakeet",
            kind: .asr,
            builtin: true,
            models: parakeetModels.isEmpty ? ["parakeet:v3", "parakeet:v2"] : parakeetModels
        ),
        ProviderEntry(
            id: "apple-speech",
            kind: .asr,
            builtin: true,
            models: appleSpeechModels.isEmpty
                ? AppleSpeechTranscriberProvider.fallbackModelIDs
                : appleSpeechModels
        ),
        ProviderEntry(
            id: "openai-transcribe",
            kind: .asr,
            builtin: true,
            models: openaiModels.isEmpty ? OpenAIASRProvider.fallbackModelIDs : openaiModels
        )
    ])
}

func defaultTTSConfig() -> ProvidersConfig {
    if let command = bundledTTSCommand() {
        let models = bundledTTSModels()
        return ProvidersConfig(providers: [
            ProviderEntry(
                id: "voxttsd",
                kind: .tts,
                command: command,
                models: models
            )
        ])
    }

    log.warning("voxttsd not found next to voxd; using in-process TTS providers")
    return TTSDefaultProviderConfig.inProcess()
}

func bundledTTSModels() -> [String] {
    var models: [String] = []
    if openAITTSAvailable() {
        models.append(contentsOf: OpenAITTSProvider.supportedModelIDs)
    }
    if elevenLabsTTSAvailable() {
        models.append(contentsOf: ElevenLabsTTSProvider.supportedModelIDs)
    }
    if miniMaxTTSAvailable() {
        models.append(contentsOf: MiniMaxTTSProvider.supportedModelIDs)
    }
    if nvidiaTTSAvailable() {
        models.append(contentsOf: NVIDIAMagpieTTSProvider.supportedModelIDs)
    }
    if groqTTSAvailable() {
        models.append(contentsOf: GroqTTSProvider.supportedModelIDs)
    }
    if geminiTTSAvailable() {
        models.append(contentsOf: GeminiTTSProvider.supportedModelIDs)
    }
    models.append(AVSpeechSynthesizerProvider.modelID)
    return models
}

func openAITTSAvailable() -> Bool {
    hasEnvironmentValue("OPENAI_API_KEY") || VoxCredentialStore().state().openAIConfigured
}

func elevenLabsTTSAvailable() -> Bool {
    hasEnvironmentValue("ELEVENLABS_API_KEY")
}

func miniMaxTTSAvailable() -> Bool {
    hasEnvironmentValue("MINIMAX_API_KEY")
}

func nvidiaTTSAvailable() -> Bool {
    hasEnvironmentValue("NV_API_KEY") || hasEnvironmentValue("NVIDIA_API_KEY")
}

func groqTTSAvailable() -> Bool {
    hasEnvironmentValue("GROQ_API_KEY")
}

func geminiTTSAvailable() -> Bool {
    hasEnvironmentValue("GEMINI_API_KEY")
        || hasEnvironmentValue("GOOGLE_API_KEY")
        || hasEnvironmentValue("GOOGLE_GENAI_API_KEY")
}

func hasEnvironmentValue(_ key: String) -> Bool {
    guard let value = ProcessInfo.processInfo.environment[key] else { return false }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

func bundledTTSCommand() -> [String]? {
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    let executableName = "voxttsd"
    let siblingURL = executableURL.deletingLastPathComponent().appendingPathComponent(executableName)
    if FileManager.default.isExecutableFile(atPath: siblingURL.path) {
        return [siblingURL.path]
    }

    guard let resolvedPath = Bundle.main.path(forResource: executableName, ofType: nil),
          FileManager.default.isExecutableFile(atPath: resolvedPath) else {
        return nil
    }
    return [resolvedPath]
}

func loadEngines() -> (EngineManager, TTSEngineManager, String) {
    let plugins = PluginStore.loadInstalled()
    let asrPlugins = plugins.filter { $0.resolvedKind == .asr }
    let ttsPlugins = plugins.filter { $0.resolvedKind == .tts }
    if !plugins.isEmpty {
        log.info("Loaded \(plugins.count) installed plugin provider(s)")
    }

    let configURL = RuntimePaths.providersConfigURL()
    guard FileManager.default.fileExists(atPath: configURL.path) else {
        log.info("No providers.json found, using default Vox ASR and TTS providers")
        let ttsConfig = defaultTTSConfig()
        return (
            EngineManager(provider: ProviderRegistry(config: defaultASRConfig().merging(asrPlugins))),
            TTSEngineManager(provider: TTSProviderRegistry(config: ttsConfig.merging(ttsPlugins))),
            TTSDefaultModelSelector.defaultModelId(for: ttsConfig)
        )
    }

    do {
        let config = try ProvidersConfig.load(from: configURL)
        log.info("Loaded \(config.providers.count) provider(s) from providers.json")
        let asrConfig = (config.providers.contains(where: { $0.resolvedKind == .asr })
            ? config
            : defaultASRConfig())
            .merging([ProviderEntry(id: "native-streaming", kind: .asr, builtin: true)])
            .merging(asrPlugins)
        let baseTTSConfig: ProvidersConfig
        if config.providers.contains(where: { $0.resolvedKind == .tts }) {
            let merged = TTSDefaultProviderConfig.mergingMissingDefaults(into: config)
            let added = merged.providers.count - config.providers.count
            if added > 0 {
                log.info("Adding \(added) default TTS provider(s) alongside providers.json")
            }
            baseTTSConfig = merged
        } else {
            baseTTSConfig = defaultTTSConfig()
        }
        let ttsConfig = baseTTSConfig.merging(ttsPlugins)

        return (
            EngineManager(provider: ProviderRegistry(config: asrConfig)),
            TTSEngineManager(provider: TTSProviderRegistry(config: ttsConfig)),
            TTSDefaultModelSelector.defaultModelId(for: ttsConfig)
        )
    } catch {
        log.error("Failed to parse providers.json: \(error.localizedDescription) — falling back to default")
        let ttsConfig = defaultTTSConfig()
        return (
            EngineManager(provider: ProviderRegistry(config: defaultASRConfig().merging(asrPlugins))),
            TTSEngineManager(provider: TTSProviderRegistry(config: ttsConfig.merging(ttsPlugins))),
            TTSDefaultModelSelector.defaultModelId(for: ttsConfig)
        )
    }
}

let port = parsePort()
let host = VoxDefaults.resolvedHost()
let authToken = ProcessInfo.processInfo.environment["VOX_AUTH_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
let socketPath = ProcessInfo.processInfo.environment["VOX_SOCKET_PATH"].flatMap { $0.isEmpty ? nil : $0 }
let (engine, ttsEngine, defaultSynthesisModelId) = loadEngines()
let service = VoxRuntimeService(
    port: port,
    bindAddress: host,
    engine: engine,
    ttsEngine: ttsEngine,
    defaultSynthesisModelId: defaultSynthesisModelId,
    authToken: authToken,
    socketPath: socketPath
)

do {
    try service.start()
} catch {
    fputs("Failed to start Vox daemon: \(error.localizedDescription)\n", stderr)
    exit(1)
}

let signals: [Int32] = [SIGTERM, SIGINT]
var sources: [DispatchSourceSignal] = []
for signalNumber in signals {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        service.stop()
        exit(0)
    }
    source.resume()
    sources.append(source)
}

RunLoop.main.run()
