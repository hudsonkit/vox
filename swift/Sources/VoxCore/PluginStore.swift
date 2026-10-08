import Foundation

public enum PluginIdentifierError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let id):
            return "Plugin id '\(id)' is not allowed."
        }
    }
}

public enum PluginIdentifierValidator {
    private static let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
    private static let allowedFirstCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")

    public static func validate(_ id: String) throws {
        guard !id.isEmpty,
              !id.contains(".."),
              id.unicodeScalars.allSatisfy(allowedCharacters.contains),
              id.unicodeScalars.first.map(allowedFirstCharacters.contains) == true else {
            throw PluginIdentifierError.invalid(id)
        }
    }
}

public enum PluginCommandError: Error, LocalizedError {
    case empty
    case disallowedLauncher(String)
    case invalidArgument(String)
    case invalidExecutable(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Plugin command is empty."
        case .disallowedLauncher(let name):
            return "Plugin command launcher '\(name)' is not allowed."
        case .invalidArgument(let argument):
            return "Plugin command argument is not allowed: \(argument)"
        case .invalidExecutable(let path):
            return "Plugin executable must be an executable regular file inside its own plugin directory, without symlinks or traversal: \(path)"
        }
    }
}

public enum PluginCommandValidator {
    public static let allowedLaunchers: Set<String> = [
        "node",
        "bun",
        "npx",
        "bunx",
        "uv",
        "uvx",
        "python3",
        "python"
    ]

    public static func validate(_ command: [String]) throws {
        try validateArguments(command)
        let first = command[0]
        let launcher = URL(fileURLWithPath: first).lastPathComponent
        guard allowedLaunchers.contains(launcher) else {
            throw PluginCommandError.disallowedLauncher(launcher)
        }
    }

    /// Native launchers are allowed only after their bundle files are installed.
    /// Catalog commands without an installed bundle retain the global allowlist.
    public static func validate(
        _ command: [String],
        pluginDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        try validateArguments(command)
        let first = command[0]
        let directory = pluginDirectory.standardizedFileURL.path
        let executable = URL(fileURLWithPath: first).standardizedFileURL.path
        let insideDirectory = executable.hasPrefix(directory + "/")

        if !insideDirectory {
            try validate(command)
            return
        }

        guard (first as NSString).isAbsolutePath,
              !(first as NSString).pathComponents.contains(where: { $0 == "." || $0 == ".." }) else {
            throw PluginCommandError.invalidExecutable(first)
        }

        // Inspect each component without resolving symlinks. This also prevents a
        // symlinked plugin directory from authorizing a binary in another bundle.
        // VOX_HOME may live beneath a system alias such as /var or /tmp. Its
        // ancestors are trusted; enforce symlink-free components from plugins/.
        var componentURL = pluginDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath()
        let relative = String(executable.dropFirst(directory.count + 1))
        let components = ["plugins", pluginDirectory.lastPathComponent] + relative.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            componentURL.appendPathComponent(component)
            let expected: FileAttributeType = index == components.count - 1 ? .typeRegular : .typeDirectory
            guard let attributes = try? fileManager.attributesOfItem(atPath: componentURL.path),
                  attributes[.type] as? FileAttributeType == expected else {
                throw PluginCommandError.invalidExecutable(first)
            }
        }
        guard fileManager.isExecutableFile(atPath: executable) else {
            throw PluginCommandError.invalidExecutable(first)
        }
    }

    private static func validateArguments(_ command: [String]) throws {
        guard let first = command.first, !first.isEmpty else {
            throw PluginCommandError.empty
        }

        for argument in command {
            if argument.contains("\0")
                || argument.contains("\r")
                || argument.contains("\n")
                || argument.contains(";")
                || argument.contains("|")
                || argument.contains("&")
                || argument.contains("`")
                || argument.contains("$") {
                throw PluginCommandError.invalidArgument(argument)
            }
        }
    }
}

public enum PluginStore {
    public static func loadInstalled(fileManager: FileManager = .default) -> [ProviderEntry] {
        let root = RuntimePaths.pluginsDirectoryURL()
        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return contents.compactMap { directory in
            let url = directory.appendingPathComponent("provider.json")
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try? JSONDecoder().decode(ProviderEntry.self, from: Data(contentsOf: url))
        }.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    public static func install(
        _ entry: ProviderEntry,
        fileManager: FileManager = .default
    ) throws {
        let directory = try pluginDirectory(for: entry.id)
        if let command = entry.command {
            try PluginCommandValidator.validate(command, pluginDirectory: directory, fileManager: fileManager)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entry).write(
            to: directory.appendingPathComponent("provider.json"),
            options: .atomic
        )
    }

    public static func remove(id: String, fileManager: FileManager = .default) throws {
        let directory = try pluginDirectory(for: id)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    public static func isInstalled(id: String, fileManager: FileManager = .default) -> Bool {
        guard let directory = try? pluginDirectory(for: id) else { return false }
        return fileManager.fileExists(atPath: directory.appendingPathComponent("provider.json").path)
    }

    public static func pluginDirectory(for id: String) throws -> URL {
        try PluginIdentifierValidator.validate(id)
        return RuntimePaths.pluginsDirectoryURL().appendingPathComponent(id, isDirectory: true)
    }
}
