import Foundation

public enum VoxVersion {
    public static let current = "0.5.1"
}

public struct VoxPortDefinition: Sendable, Equatable {
    public let id: String
    public let envVar: String
    public let defaultPort: UInt16
    public let transport: String
    public let description: String
    public let storedInRuntimeFile: Bool

    public init(
        id: String,
        envVar: String,
        defaultPort: UInt16,
        transport: String,
        description: String,
        storedInRuntimeFile: Bool
    ) {
        self.id = id
        self.envVar = envVar
        self.defaultPort = defaultPort
        self.transport = transport
        self.description = description
        self.storedInRuntimeFile = storedInRuntimeFile
    }

    public func resolvedPort() -> UInt16 {
        if let raw = ProcessInfo.processInfo.environment[envVar],
           let port = UInt16(raw) {
            return port
        }
        return defaultPort
    }
}

public enum VoxPorts {
    public static let daemon = VoxPortDefinition(
        id: "companion-ws",
        envVar: "VOX_PORT",
        defaultPort: 42137,
        transport: "ws",
        description: "Companion daemon WebSocket port",
        storedInRuntimeFile: true
    )

    public static let bridge = VoxPortDefinition(
        id: "companion-http",
        envVar: "VOX_BRIDGE_PORT",
        defaultPort: 43115,
        transport: "http",
        description: "Companion HTTP bridge port",
        storedInRuntimeFile: false
    )

    public static let all = [daemon, bridge]
}

public enum VoxDefaults {
    public static let daemonPort: UInt16 = VoxPorts.daemon.defaultPort
    public static let bridgePort: UInt16 = VoxPorts.bridge.defaultPort
    public static let host = "127.0.0.1"

    public static func resolvedDaemonPort() -> UInt16 {
        VoxPorts.daemon.resolvedPort()
    }

    public static func resolvedBridgePort() -> UInt16 {
        VoxPorts.bridge.resolvedPort()
    }

    public static func resolvedHost() -> String {
        if let host = ProcessInfo.processInfo.environment["VOX_HOST"], !host.isEmpty {
            return host
        }
        return host
    }

    public static let modelCatalogPath = "/data/models.json"
    public static let defaultModelCatalogURL = URL(string: "https://voxd.cc/data/models.json")!

    public static func resolvedModelCatalogURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["VOX_MODEL_CATALOG_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw) {
            return url
        }
        return defaultModelCatalogURL
    }
}

public enum RuntimePaths {
    public static func voxHomeURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["VOX_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let fileManager = FileManager.default

        #if os(iOS)
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("Vox", isDirectory: true)
        #else
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".vox", isDirectory: true)
        #endif
    }

    public static func runtimeFileURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["VOX_RUNTIME_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        return voxHomeURL().appendingPathComponent("runtime.json")
    }

    public static func performanceLogURL() -> URL {
        voxHomeURL().appendingPathComponent("performance.jsonl")
    }

    public static func voiceLogURL() -> URL {
        voxHomeURL().appendingPathComponent("voice.jsonl")
    }

    public static func historyLogURL() -> URL {
        voxHomeURL().appendingPathComponent("history.jsonl")
    }

    public static func logsDirectoryURL() -> URL {
        voxHomeURL().appendingPathComponent("logs", isDirectory: true)
    }

    public static func daemonLogURL() -> URL {
        logsDirectoryURL().appendingPathComponent("voxd.log")
    }

    public static func providersConfigURL() -> URL {
        voxHomeURL().appendingPathComponent("providers.json")
    }

    public static func preferencesFileURL() -> URL {
        voxHomeURL().appendingPathComponent("preferences.json")
    }

    public static func credentialsFileURL() -> URL {
        voxHomeURL().appendingPathComponent("credentials.json")
    }

    public static func credentialsKeyURL() -> URL {
        voxHomeURL().appendingPathComponent("credentials.key")
    }

    public static func modelCatalogCacheURL() -> URL {
        voxHomeURL()
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("models-catalog.json")
    }

    public static func pluginsDirectoryURL() -> URL {
        voxHomeURL().appendingPathComponent("plugins", isDirectory: true)
    }

    public static func bridgeOriginsFileURL() -> URL {
        voxHomeURL().appendingPathComponent("origins.json")
    }

    public static func bridgeOriginsDirectoryURL() -> URL {
        voxHomeURL().appendingPathComponent("origins.d", isDirectory: true)
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(
            at: voxHomeURL(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: logsDirectoryURL(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bridgeOriginsDirectoryURL(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: pluginsDirectoryURL(),
            withIntermediateDirectories: true
        )
    }
}
