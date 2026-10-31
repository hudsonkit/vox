import Foundation

public enum ProviderKind: String, Codable, Sendable {
    case asr
    case tts
}

public struct ProvidersConfig: Codable, Sendable {
    public let providers: [ProviderEntry]

    public init(providers: [ProviderEntry]) {
        self.providers = providers
    }

    public static func load(from url: URL) throws -> ProvidersConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ProvidersConfig.self, from: data)
    }

    public func merging(_ extra: [ProviderEntry]) -> ProvidersConfig {
        var seen = Set(providers.map(\.id))
        var merged = providers
        for entry in extra where seen.insert(entry.id).inserted {
            merged.append(entry)
        }
        return ProvidersConfig(providers: merged)
    }
}

public struct ProviderEntry: Codable, Sendable {
    public let id: String
    public let kind: ProviderKind?
    public let builtin: Bool?
    public let command: [String]?
    public let models: [String]?
    public let env: [String: String]?
    /// Opt-in JSON-RPC $/cancelRequest support; absent means legacy provider.
    public let supportsRequestCancellation: Bool?

    public init(
        id: String,
        kind: ProviderKind? = nil,
        builtin: Bool? = nil,
        command: [String]? = nil,
        models: [String]? = nil,
        env: [String: String]? = nil,
        supportsRequestCancellation: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.builtin = builtin
        self.command = command
        self.models = models
        self.env = env
        self.supportsRequestCancellation = supportsRequestCancellation
    }

    public var isBuiltin: Bool {
        builtin == true
    }

    public var isExternal: Bool {
        command != nil && !command!.isEmpty
    }

    public var resolvedKind: ProviderKind {
        kind ?? .asr
    }
}
