import Foundation
import Testing
@testable import VoxCore

extension VoxHomeEnvironment {
    struct PluginStoreTests {
        @Test("Plugin command validator allows node and rejects shells")
        func commandValidatorAllowlist() throws {
            try PluginCommandValidator.validate(["node", "/tmp/provider.mjs"])
            try PluginCommandValidator.validate(["npx", "-y", "@voxd/plugin-mlx-vlm"])

            #expect(throws: PluginCommandError.self) {
                try PluginCommandValidator.validate(["bash", "-c", "rm -rf /"])
            }
            #expect(throws: PluginCommandError.self) {
                try PluginCommandValidator.validate(["node", "foo; bar"])
            }
        }

        @Test("Plugin identifier validator rejects traversal and path separators")
        func identifierValidatorRejectsTraversal() throws {
            for id in ["../escape", "nested/plugin", "nested\\plugin", "a..b", ".hidden", "Uppercase"] {
                #expect(throws: PluginIdentifierError.self) {
                    try PluginIdentifierValidator.validate(id)
                }
            }

            for id in ["mlx-vlm", "mlx_vlm.v2", "plugin-2"] {
                try PluginIdentifierValidator.validate(id)
            }
        }

        @Test("Plugin store rejects traversal ids before filesystem access")
        func storeRejectsTraversalIDs() throws {
            let plugin = ProviderEntry(
                id: "../escape",
                kind: .asr,
                command: ["node", "/tmp/provider.mjs"],
                models: []
            )
            #expect(throws: PluginIdentifierError.self) {
                try PluginStore.install(plugin)
            }
            #expect(throws: PluginIdentifierError.self) {
                try PluginStore.remove(id: "../escape")
            }
            #expect(!PluginStore.isInstalled(id: "../escape"))
        }

        @Test("Plugin store writes provider.json and merges without replacing existing ids")
        func installRoundTripAndMerge() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            setenv("VOX_HOME", directory.path, 1)
            defer {
                unsetenv("VOX_HOME")
                try? FileManager.default.removeItem(at: directory)
            }

            let plugin = ProviderEntry(
                id: "mlx-vlm",
                kind: .asr,
                command: ["node", "/tmp/mlx-vlm.mjs"],
                models: ["gemma-4-e2b-it"]
            )
            try PluginStore.install(plugin)
            #expect(PluginStore.isInstalled(id: "mlx-vlm"))

            let loaded = PluginStore.loadInstalled()
            #expect(loaded.map(\.id) == ["mlx-vlm"])
            #expect(loaded.first?.models == ["gemma-4-e2b-it"])

            let merged = ProvidersConfig(providers: [
                ProviderEntry(id: "parakeet", kind: .asr, builtin: true, models: ["parakeet:v3"])
            ]).merging(loaded)
            #expect(merged.providers.map(\.id) == ["parakeet", "mlx-vlm"])

            try PluginStore.remove(id: "mlx-vlm")
            #expect(!PluginStore.isInstalled(id: "mlx-vlm"))
        }

        @Test("Plugin store accepts only an installed bundle's confined native executable")
        func nativeExecutableRoundTrip() throws {
            try withNativeBundle { _, binary in
                #expect(throws: PluginCommandError.self) {
                    try PluginCommandValidator.validate([binary.path])
                }
                try PluginStore.install(nativeEntry(binary))
                #expect(PluginStore.loadInstalled().first?.command == [binary.path, "--stdio"])
            }
        }

        @Test("Native command rejection preserves the existing provider registration")
        func nativeCommandEscapesAndArguments() throws {
            try withNativeBundle { home, binary in
                try PluginStore.install(nativeEntry(binary))
                let metadata = try PluginStore.pluginDirectory(for: "whistle").appendingPathComponent("provider.json")
                let previous = try Data(contentsOf: metadata)
                let commands = [
                    [home.appendingPathComponent("outside-native").path],
                    [binary.deletingLastPathComponent().appendingPathComponent("../bin/vox-whistle").path],
                    ["plugins/whistle/bin/vox-whistle"],
                    [binary.path + "-sibling"],
                    [binary.path, "bad;argument"],
                    [binary.path, "bad\rargument"],
                    [binary.path, "bad\0argument"],
                    [binary.path, "$HOME"],
                ]
                for command in commands {
                    let entry = ProviderEntry(id: "whistle", kind: .asr, command: command, models: ["replacement"])
                    #expect(throws: PluginCommandError.self) { try PluginStore.install(entry) }
                    #expect(try Data(contentsOf: metadata) == previous)
                }
            }
        }

        @Test("Native executable must exist, be regular, and have execute permission")
        func nativeExecutableFileRequirements() throws {
            for invalid in ["missing", "directory", "not-executable"] {
                try withNativeBundle { _, binary in
                    if invalid == "not-executable" {
                        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)
                    } else {
                        try FileManager.default.removeItem(at: binary)
                        if invalid == "directory" {
                            try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: false)
                        }
                    }
                    #expect(throws: PluginCommandError.self) { try PluginStore.install(nativeEntry(binary)) }
                    #expect(!PluginStore.isInstalled(id: "whistle"))
                }
            }
        }

        @Test("Native executable rejects symlinks from plugins root through the binary")
        func nativeExecutableSymlinks() throws {
            for location in ["plugins", "plugin", "bin", "binary"] {
                try withNativeBundle { home, binary in
                    let source: URL
                    switch location {
                    case "plugins": source = home.appendingPathComponent("plugins")
                    case "plugin": source = try PluginStore.pluginDirectory(for: "whistle")
                    case "bin": source = binary.deletingLastPathComponent()
                    default: source = binary
                    }
                    let outside = home.appendingPathComponent("moved-\(location)")
                    try FileManager.default.moveItem(at: source, to: outside)
                    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
                    #expect(throws: PluginCommandError.self) { try PluginStore.install(nativeEntry(binary)) }
                    #expect(!FileManager.default.fileExists(atPath: (try PluginStore.pluginDirectory(for: "whistle"))
                        .appendingPathComponent("provider.json").path))
                }
            }
        }

        @Test("Native bundle supports a home beneath a system or user directory alias")
        func nativeExecutableHomeAlias() throws {
            try withNativeBundle { home, _ in
                let alias = home.appendingPathComponent("home-alias")
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
                setenv("VOX_HOME", alias.path, 1)
                let binary = try PluginStore.pluginDirectory(for: "whistle").appendingPathComponent("bin/vox-whistle")
                try PluginStore.install(nativeEntry(binary))
                #expect(PluginStore.loadInstalled().first?.command?.first == binary.path)
            }
        }

        private func nativeEntry(_ binary: URL) -> ProviderEntry {
            ProviderEntry(id: "whistle", kind: .asr, command: [binary.path, "--stdio"], models: ["whistle"])
        }

        private func withNativeBundle(_ body: (URL, URL) throws -> Void) throws {
            let manager = FileManager.default
            let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let previousHome = ProcessInfo.processInfo.environment["VOX_HOME"]
            setenv("VOX_HOME", home.path, 1)
            defer {
                if let previousHome { setenv("VOX_HOME", previousHome, 1) }
                else { unsetenv("VOX_HOME") }
                try? manager.removeItem(at: home)
            }
            let binary = try PluginStore.pluginDirectory(for: "whistle").appendingPathComponent("bin/vox-whistle")
            try manager.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("native fixture; registration never executes it\n".utf8).write(to: binary)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try body(home, binary)
        }
    }
}
