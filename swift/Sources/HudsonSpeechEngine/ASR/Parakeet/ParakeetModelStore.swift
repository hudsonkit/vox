import Foundation
import VoxCore

struct ParakeetModelManifest: Sendable, Equatable {
    let modelId: String
    let name: String
    let backend: String
    let revision: String
    let repositoryFolderName: String
    let cacheDirectoryName: String
    let requiredModelFiles: Set<String>
    let vocabularyFile: String
    let jointFileName: String
    let tdtConfig: ParakeetTdtConfig

    var inferenceConfig: ParakeetInferenceConfig {
        ParakeetInferenceConfig(tdtConfig: tdtConfig)
    }

    init(
        modelId: String,
        name: String,
        backend: String = "parakeet",
        repositoryFolderName: String,
        revision: String = "main",
        cacheDirectoryName: String,
        requiredModelFiles: Set<String>,
        vocabularyFile: String,
        jointFileName: String,
        tdtConfig: ParakeetTdtConfig
    ) {
        self.modelId = modelId
        self.name = name
        self.backend = backend
        self.repositoryFolderName = repositoryFolderName
        self.revision = revision
        self.cacheDirectoryName = cacheDirectoryName
        self.requiredModelFiles = requiredModelFiles
        self.vocabularyFile = vocabularyFile
        self.jointFileName = jointFileName
        self.tdtConfig = tdtConfig
    }

    init?(entry: SpeechModelCatalogEntry) {
        guard entry.family == SpeechModelFamily.parakeetTDT,
              entry.isASR,
              let spec = entry.parakeet,
              let repo = entry.source?.repo else {
            return nil
        }

        self.init(
            modelId: entry.id,
            name: entry.name,
            repositoryFolderName: repo,
            revision: entry.source?.revision ?? "main",
            cacheDirectoryName: spec.cacheDirectoryName,
            requiredModelFiles: Set(spec.requiredFiles),
            vocabularyFile: spec.vocabularyFile,
            jointFileName: spec.jointFile,
            tdtConfig: ParakeetTdtConfig(blankId: spec.blankId)
        )
    }

    static let v3 = ParakeetModelManifest(
        modelId: "parakeet:v3",
        name: "Parakeet TDT v3",
        repositoryFolderName: "arach/parakeet-tdt-0.6b-v3-coreml",
        revision: "743fa35d26213cbc8de1e001bfdc76ed0530abe8",
        cacheDirectoryName: "parakeet-tdt-0.6b-v3-743fa35",
        requiredModelFiles: [
            "Preprocessor.mlmodelc",
            "Encoder.mlmodelc",
            "Decoder.mlmodelc",
            "JointDecisionv3.mlmodelc",
        ],
        vocabularyFile: "parakeet_vocab.json",
        jointFileName: "JointDecisionv3.mlmodelc",
        tdtConfig: ParakeetTdtConfig(blankId: 8192)
    )

    static let v2 = ParakeetModelManifest(
        modelId: "parakeet:v2",
        name: "Parakeet TDT v2",
        repositoryFolderName: "FluidInference/parakeet-tdt-0.6b-v2-coreml",
        cacheDirectoryName: "parakeet-tdt-0.6b-v2",
        requiredModelFiles: [
            "Preprocessor.mlmodelc",
            "Encoder.mlmodelc",
            "Decoder.mlmodelc",
            "JointDecision.mlmodelc",
        ],
        vocabularyFile: "parakeet_vocab.json",
        jointFileName: "JointDecision.mlmodelc",
        tdtConfig: ParakeetTdtConfig(blankId: 1024)
    )

    static let builtin: [ParakeetModelManifest] = [.v3, .v2]
}

struct ParakeetModelStore: Sendable {
    let manifest: ParakeetModelManifest
    private let downloader: any ParakeetModelArtifactDownloader
    private let storageAnchor: URL
    private let storageParents: [String]

    init(
        manifest: ParakeetModelManifest = .v3,
        downloader: any ParakeetModelArtifactDownloader = VoxParakeetArtifactDownloader(),
        preferredModelsRootDirectory: URL? = nil
    ) {
        self.manifest = manifest
        self.downloader = downloader
        self.storageAnchor = preferredModelsRootDirectory ?? RuntimePaths.voxHomeURL()
        self.storageParents = preferredModelsRootDirectory == nil ? ["cache", "models"] : []
    }

    func isInstalled(fileManager: FileManager = .default) -> Bool {
        guard (try? ownedDirectory()) != nil else { return false }
        return installedDirectory(fileManager: fileManager) != nil
    }

    func preferredModelsRootDirectory(fileManager: FileManager = .default) -> URL {
        storageParents.reduce(storageAnchor) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private var ownership: ParakeetOwnedStorage {
        ParakeetOwnedStorage(anchor: storageAnchor, parents: storageParents, manifest: manifest)
    }
    func ownedDirectory() throws -> URL { try ownership.directory() }
    func removeInstallation() throws { try ownership.remove() }

    func preferredInstallDirectory(fileManager: FileManager = .default) -> URL {
        preferredModelsRootDirectory(fileManager: fileManager)
            .appendingPathComponent(manifest.cacheDirectoryName, isDirectory: true)
    }

    func installedDirectory(fileManager: FileManager = .default) -> URL? {
        installedDirectory(
            fileManager: fileManager,
            candidateDirectories: candidateModelDirectories(fileManager: fileManager)
        )
    }

    func installedDirectory(fileManager: FileManager = .default, candidateDirectories: [URL]) -> URL? {
        candidateDirectories.first { directory in
            hasRequiredArtifacts(at: directory, fileManager: fileManager)
        }
    }

    func candidateModelDirectories(fileManager: FileManager = .default) -> [URL] {
        [preferredInstallDirectory(fileManager: fileManager)]
    }

    func ensureInstalled(
        fileManager: FileManager = .default,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        try ownership.prepare()
        if let installed = installedDirectory(fileManager: fileManager) {
            progress(ModelProgress(modelId: manifest.modelId, progress: 0.8, status: "installed"))
            return installed
        }

        let modelsRoot = preferredModelsRootDirectory(fileManager: fileManager)
        try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        progress(ModelProgress(modelId: manifest.modelId, progress: 0.05, status: "starting"))
        try await downloader.download(manifest: manifest, to: modelsRoot, progress: progress)

        let preferredInstall = preferredInstallDirectory(fileManager: fileManager)
        let candidateDirectories = [preferredInstall] + candidateModelDirectories(fileManager: fileManager)
        if let installed = installedDirectory(
            fileManager: fileManager,
            candidateDirectories: candidateDirectories
        ) {
            progress(ModelProgress(modelId: manifest.modelId, progress: 0.8, status: "installed"))
            return installed
        }

        throw NSError(domain: "VoxEngine", code: 104, userInfo: [
            NSLocalizedDescriptionKey:
                "Parakeet model download completed, but the expected model artifacts were not found."
        ])
    }

    func loadVocabulary(fileManager: FileManager = .default) throws -> [Int: String] {
        guard let directory = installedDirectory(fileManager: fileManager) else {
            throw NSError(domain: "VoxEngine", code: 101, userInfo: [
                NSLocalizedDescriptionKey: "Parakeet vocabulary is unavailable because the model is not installed."
            ])
        }

        let vocabularyURL = directory.appendingPathComponent(manifest.vocabularyFile)
        return try ParakeetVocabulary.load(from: vocabularyURL)
    }

    private func hasRequiredArtifacts(at directory: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }

        // Check compiled-bundle contents, not just a directory left by an interrupted download.
        // Never instantiate an MLModel (especially a CPU encoder) for installation validation.
        let requiredModelsPresent = manifest.requiredModelFiles.allSatisfy { fileName in
            ["coremldata.bin", "model.mil", "weights/weight.bin"].allSatisfy { artifact in
                let path = directory.appendingPathComponent(fileName).appendingPathComponent(artifact).path
                return ((try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0) > 0
            }
        }
        guard requiredModelsPresent else {
            return false
        }

        return fileManager.fileExists(atPath: directory.appendingPathComponent(manifest.vocabularyFile).path)
    }
}

protocol ParakeetModelArtifactDownloader: Sendable {
    func download(
        manifest: ParakeetModelManifest,
        to modelsRootDirectory: URL,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws
}

struct VoxParakeetArtifactDownloader: ParakeetModelArtifactDownloader {
    private let log = VoxLog.engine

    func download(
        manifest: ParakeetModelManifest,
        to modelsRootDirectory: URL,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws {
        log.info("Downloading \(manifest.cacheDirectoryName) from model registry")

        let installDirectory = modelsRootDirectory.appendingPathComponent(
            manifest.cacheDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        let requiredDirectoryPrefixes = manifest.requiredModelFiles.map { "\($0)/" }
        let metadataFiles: Set<String> = [manifest.vocabularyFile, "config.json"]
        var filesToDownload: [(path: String, size: Int)] = []

        func shouldProcessDirectory(_ itemPath: String) -> Bool {
            requiredDirectoryPrefixes.contains { prefix in
                itemPath == String(prefix.dropLast())
                    || itemPath.hasPrefix(prefix)
                    || prefix.hasPrefix(itemPath + "/")
            }
        }

        func shouldIncludeFile(_ itemPath: String) -> Bool {
            metadataFiles.contains(itemPath)
                || requiredDirectoryPrefixes.contains { itemPath.hasPrefix($0) }
        }

        func listDirectory(path: String) async throws {
            let items = try await VoxModelHub.listDirectory(
                repoPath: manifest.repositoryFolderName,
                path: path,
                revision: manifest.revision
            )
            for item in items {
                guard let itemPath = item["path"] as? String,
                      let itemType = item["type"] as? String else {
                    continue
                }

                if itemType == "directory" {
                    if shouldProcessDirectory(itemPath) {
                        try await listDirectory(path: itemPath)
                    }
                } else if itemType == "file", shouldIncludeFile(itemPath) {
                    let fileSize = item["size"] as? Int ?? -1
                    filesToDownload.append((path: itemPath, size: fileSize))
                }
            }
        }

        progress(ModelProgress(modelId: manifest.modelId, progress: 0.1, status: "listing"))
        try await listDirectory(path: "")
        filesToDownload.sort { $0.path < $1.path }

        for (index, file) in filesToDownload.enumerated() {
            let destinationURL = installDirectory.appendingPathComponent(file.path)
            try await VoxModelHub.downloadFile(
                repoPath: manifest.repositoryFolderName,
                remotePath: file.path,
                to: destinationURL,
                revision: manifest.revision
            )

            let fraction = filesToDownload.isEmpty ? 1.0 : Double(index + 1) / Double(filesToDownload.count)
            let scaledProgress = min(max((fraction * 0.7) + 0.1, 0.1), 0.8)
            progress(
                ModelProgress(
                    modelId: manifest.modelId,
                    progress: scaledProgress,
                    status: "downloading \(index + 1)/\(filesToDownload.count)"
                )
            )
        }

        for requiredModel in manifest.requiredModelFiles {
            let modelPath = installDirectory.appendingPathComponent(requiredModel)
            guard FileManager.default.fileExists(atPath: modelPath.path) else {
                throw VoxModelHubError.modelNotFound(path: requiredModel)
            }
        }

        let vocabularyPath = installDirectory.appendingPathComponent(manifest.vocabularyFile)
        guard FileManager.default.fileExists(atPath: vocabularyPath.path) else {
            throw VoxModelHubError.modelNotFound(path: manifest.vocabularyFile)
        }

        log.info("Downloaded all required artifacts for \(manifest.cacheDirectoryName)")
    }
}
