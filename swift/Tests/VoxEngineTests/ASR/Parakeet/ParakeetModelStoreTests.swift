import Foundation
import Testing
import VoxCore
@testable import HudsonSpeechEngine

struct ParakeetModelStoreTests {
    @Test("Parakeet model store only reports installed when all required model files and vocabulary exist")
    func installationRequiresExpectedArtifacts() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let manifest = ParakeetModelManifest.v3
        let store = ParakeetModelStore(
            manifest: manifest,
            preferredModelsRootDirectory: tempDirectory
        )
        let installDirectory = tempDirectory.appendingPathComponent(manifest.cacheDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        #expect(!store.isInstalled(fileManager: .default))

        for fileName in manifest.requiredModelFiles {
            try FileManager.default.createDirectory(
                at: installDirectory.appendingPathComponent(fileName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        #expect(!store.isInstalled(fileManager: .default))

        try Data("{\"0\":\"<unk>\",\"1\":\"hello\"}".utf8)
            .write(to: installDirectory.appendingPathComponent(manifest.vocabularyFile))

        // Empty .mlmodelc directories must remain uninstalled, even with vocabulary present.
        #expect(!store.isInstalled(fileManager: .default))
        try writeInstalledArtifacts(for: manifest, to: installDirectory)
        let customStore = ParakeetModelStore(manifest: manifest)
        let installed = customStore.installedDirectory(
            fileManager: FileManager.default,
            candidateDirectories: [installDirectory]
        )

        #expect(installed == installDirectory)
    }

    @Test("Parakeet vocabulary loader supports array and dictionary JSON formats")
    func vocabularyLoaderSupportsBothKnownFormats() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let arrayURL = tempDirectory.appendingPathComponent("array-vocab.json")
        try Data("[\"<unk>\",\"hello\",\"world\"]".utf8).write(to: arrayURL)
        let arrayVocabulary = try ParakeetVocabulary.load(from: arrayURL)
        #expect(arrayVocabulary[0] == "<unk>")
        #expect(arrayVocabulary[2] == "world")

        let dictionaryURL = tempDirectory.appendingPathComponent("dict-vocab.json")
        try Data("{\"0\":\"<unk>\",\"17\":\"voice\"}".utf8).write(to: dictionaryURL)
        let dictionaryVocabulary = try ParakeetVocabulary.load(from: dictionaryURL)
        #expect(dictionaryVocabulary[0] == "<unk>")
        #expect(dictionaryVocabulary[17] == "voice")
    }

    @Test("Parakeet model store reuses an existing installation without re-downloading")
    func ensureInstalledSkipsDownloaderWhenArtifactsExist() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let manifest = ParakeetModelManifest.v3
        let recorder = DownloadRecorder()
        let store = ParakeetModelStore(
            manifest: manifest,
            downloader: MockDownloader { _, _, _ in
                await recorder.recordDownload()
            },
            preferredModelsRootDirectory: tempDirectory
        )

        let installDirectory = store.preferredInstallDirectory(fileManager: .default)
        try writeInstalledArtifacts(for: manifest, to: installDirectory)

        let installed = try await store.ensureInstalled { _ in }

        #expect(installed == installDirectory)
        #expect(await recorder.downloadCount() == 0)
    }

    @Test("Parakeet model store downloads missing artifacts into Vox's preferred cache root")
    func ensureInstalledDownloadsToPreferredRoot() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let manifest = ParakeetModelManifest.v3
        let recorder = DownloadRecorder()
        let store = ParakeetModelStore(
            manifest: manifest,
            downloader: MockDownloader { manifest, modelsRootDirectory, _ in
                await recorder.recordDownload(to: modelsRootDirectory)
                let installDirectory = modelsRootDirectory.appendingPathComponent(
                    manifest.cacheDirectoryName,
                    isDirectory: true
                )
                try writeInstalledArtifacts(for: manifest, to: installDirectory)
            },
            preferredModelsRootDirectory: tempDirectory
        )

        let installed = try await store.ensureInstalled { _ in }

        #expect(installed == store.preferredInstallDirectory(fileManager: .default))
        #expect(await recorder.downloadCount() == 1)
        #expect(await recorder.lastRootDirectory() == tempDirectory)
    }
}

private func writeInstalledArtifacts(for manifest: ParakeetModelManifest, to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for fileName in manifest.requiredModelFiles {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(fileName, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    for model in manifest.requiredModelFiles {
        for artifact in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
            let path = directory.appendingPathComponent(model).appendingPathComponent(artifact)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: path)
        }
    }
    try Data("{\"0\":\"<unk>\",\"1\":\"hello\"}".utf8)
        .write(to: directory.appendingPathComponent(manifest.vocabularyFile))
}

private actor DownloadRecorder {
    private var count = 0
    private var lastRoot: URL?

    func recordDownload(to directory: URL? = nil) {
        count += 1
        lastRoot = directory
    }

    func downloadCount() -> Int {
        count
    }

    func lastRootDirectory() -> URL? {
        lastRoot
    }
}

private struct MockDownloader: ParakeetModelArtifactDownloader {
    let downloadBlock: @Sendable (
        ParakeetModelManifest,
        URL,
        @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> Void

    func download(
        manifest: ParakeetModelManifest,
        to modelsRootDirectory: URL,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws {
        try await downloadBlock(manifest, modelsRootDirectory, progress)
    }
}
