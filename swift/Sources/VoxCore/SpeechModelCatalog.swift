import Foundation

public enum SpeechModelFamily {
    public static let coreMLStreaming = "coreml-streaming"
    public static let parakeetTDT = "parakeet-tdt"
    public static let appleSpeech = "apple-speech"
    public static let mlxAudio = "mlx-audio"
    public static let openaiTranscribe = "openai-transcribe"
    public static let mlxVlm = "mlx-vlm"
}

public struct SpeechModelCapabilities: Codable, Sendable, Equatable {
    public let fileTranscription: Bool
    public let liveTranscription: Bool
    public let onDevice: Bool
    public let wordTimestamps: Bool

    public init(
        fileTranscription: Bool,
        liveTranscription: Bool,
        onDevice: Bool,
        wordTimestamps: Bool
    ) {
        self.fileTranscription = fileTranscription
        self.liveTranscription = liveTranscription
        self.onDevice = onDevice
        self.wordTimestamps = wordTimestamps
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "fileTranscription": fileTranscription,
            "liveTranscription": liveTranscription,
            "onDevice": onDevice,
            "wordTimestamps": wordTimestamps
        ]
    }
}

public enum SpeechModelStatus {
    public static let ready = "ready"
    public static let plugin = "plugin"
    public static let unsupported = "unsupported"
}

public struct SpeechPluginInstall: Codable, Sendable, Equatable {
    public let kind: String
    public let id: String?
    public let package: String?

    public init(kind: String, id: String? = nil, package: String? = nil) {
        self.kind = kind
        self.id = id
        self.package = package
    }

    public func dictionaryValue() -> [String: Any] {
        var payload: [String: Any] = ["kind": kind]
        if let id { payload["id"] = id }
        if let package { payload["package"] = package }
        return payload
    }
}

public struct SpeechPluginCatalogEntry: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let name: String
    public let status: String?
    public let command: [String]?
    public let env: [String: String]?
    public let install: SpeechPluginInstall?
    public let notes: String?

    public init(
        id: String,
        kind: String = "asr",
        name: String,
        status: String? = SpeechModelStatus.ready,
        command: [String]? = nil,
        env: [String: String]? = nil,
        install: SpeechPluginInstall? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.status = status
        self.command = command
        self.env = env
        self.install = install
        self.notes = notes
    }

    public func dictionaryValue() -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "kind": kind,
            "name": name,
            "status": status ?? SpeechModelStatus.ready
        ]
        if let command { payload["command"] = command }
        if let env { payload["env"] = env }
        if let install { payload["install"] = install.dictionaryValue() }
        if let notes { payload["notes"] = notes }
        return payload
    }
}

public struct SpeechModelSource: Codable, Sendable, Equatable {
    public let type: String
    public let repo: String?
    public let revision: String?

    public init(type: String, repo: String? = nil, revision: String? = nil) {
        self.type = type
        self.repo = repo
        self.revision = revision
    }
}

public struct ParakeetCatalogSpec: Codable, Sendable, Equatable {
    public let cacheDirectoryName: String
    public let jointFile: String
    public let vocabularyFile: String
    public let blankId: Int
    public let requiredFiles: [String]

    public init(
        cacheDirectoryName: String,
        jointFile: String,
        vocabularyFile: String,
        blankId: Int,
        requiredFiles: [String]
    ) {
        self.cacheDirectoryName = cacheDirectoryName
        self.jointFile = jointFile
        self.vocabularyFile = vocabularyFile
        self.blankId = blankId
        self.requiredFiles = requiredFiles
    }
}

public struct SpeechModelCatalogEntry: Codable, Sendable, Equatable {
    public let id: String
    public let kind: String
    public let family: String
    public let name: String
    public let vendor: String?
    public let runtime: String?
    public let status: String?
    public let isDefault: Bool?
    public let languages: String?
    public let notes: String?
    public let requires: [String]?
    public let platforms: [String]?
    public let architectures: [String]?
    public let capabilities: SpeechModelCapabilities?
    public let plugin: String?
    public let source: SpeechModelSource?
    public let parakeet: ParakeetCatalogSpec?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case family
        case name
        case vendor
        case runtime
        case status
        case isDefault = "default"
        case languages
        case notes
        case requires
        case platforms
        case architectures
        case capabilities
        case plugin
        case source
        case parakeet
    }

    public init(
        id: String,
        kind: String = "asr",
        family: String,
        name: String,
        vendor: String? = nil,
        runtime: String? = nil,
        status: String? = SpeechModelStatus.ready,
        isDefault: Bool? = nil,
        languages: String? = nil,
        notes: String? = nil,
        requires: [String]? = nil,
        platforms: [String]? = nil,
        architectures: [String]? = nil,
        capabilities: SpeechModelCapabilities? = nil,
        plugin: String? = nil,
        source: SpeechModelSource? = nil,
        parakeet: ParakeetCatalogSpec? = nil
    ) {
        self.id = id
        self.kind = kind
        self.family = family
        self.name = name
        self.vendor = vendor
        self.runtime = runtime
        self.status = status
        self.isDefault = isDefault
        self.languages = languages
        self.notes = notes
        self.requires = requires
        self.platforms = platforms
        self.architectures = architectures
        self.capabilities = capabilities
        self.plugin = plugin
        self.source = source
        self.parakeet = parakeet
    }

    public var isReady: Bool {
        (status ?? SpeechModelStatus.ready) == SpeechModelStatus.ready
    }

    public var isASR: Bool {
        kind == "asr"
    }

    public func dictionaryValue() -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "kind": kind,
            "family": family,
            "name": name,
            "status": status ?? SpeechModelStatus.ready,
            "default": isDefault ?? false
        ]
        if let vendor { payload["vendor"] = vendor }
        if let runtime { payload["runtime"] = runtime }
        if let languages { payload["languages"] = languages }
        if let notes { payload["notes"] = notes }
        if let requires { payload["requires"] = requires }
        if let platforms { payload["platforms"] = platforms }
        if let architectures { payload["architectures"] = architectures }
        if let capabilities { payload["capabilities"] = capabilities.dictionaryValue() }
        if let plugin { payload["plugin"] = plugin }
        if let source {
            var sourcePayload: [String: Any] = ["type": source.type]
            if let repo = source.repo { sourcePayload["repo"] = repo }
            payload["source"] = sourcePayload
        }
        return payload
    }
}

public struct SpeechModelCatalog: Codable, Sendable, Equatable {
    public let version: Int
    public let updatedAt: String
    public let models: [SpeechModelCatalogEntry]
    public let plugins: [SpeechPluginCatalogEntry]

    enum CodingKeys: String, CodingKey {
        case version
        case updatedAt
        case models
        case plugins
    }

    public init(
        version: Int,
        updatedAt: String,
        models: [SpeechModelCatalogEntry],
        plugins: [SpeechPluginCatalogEntry] = []
    ) {
        self.version = version
        self.updatedAt = updatedAt
        self.models = models
        self.plugins = plugins
    }

    public static func decode(from data: Data) throws -> SpeechModelCatalog {
        try JSONDecoder().decode(SpeechModelCatalog.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        models = try container.decodeIfPresent([SpeechModelCatalogEntry].self, forKey: .models) ?? []
        plugins = try container.decodeIfPresent([SpeechPluginCatalogEntry].self, forKey: .plugins) ?? []
    }

    public func models(kind: String = "asr", family: String? = nil, readyOnly: Bool = false) -> [SpeechModelCatalogEntry] {
        models.filter { entry in
            guard entry.kind == kind else { return false }
            if let family, entry.family != family { return false }
            if readyOnly, !entry.isReady { return false }
            return true
        }
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "version": version,
            "updatedAt": updatedAt,
            "models": models.map { $0.dictionaryValue() },
            "plugins": plugins.map { $0.dictionaryValue() }
        ]
    }

    public func plugin(id: String) -> SpeechPluginCatalogEntry? {
        plugins.first { $0.id == id }
    }
}
