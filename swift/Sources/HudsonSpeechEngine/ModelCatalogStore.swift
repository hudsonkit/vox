import Foundation
import VoxCore

public protocol CatalogTransport: Sendable {
    func fetch(from url: URL) async throws -> Data
}

public struct URLSessionCatalogTransport: CatalogTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "VoxEngine", code: 1201, userInfo: [
                NSLocalizedDescriptionKey: "Model catalog request failed with HTTP \(http.statusCode)."
            ])
        }
        return data
    }
}

public final class ModelCatalogStore: @unchecked Sendable {
    public static let shared = ModelCatalogStore()

    private let lock = NSLock()
    private let transport: any CatalogTransport
    private let bundledCatalog: SpeechModelCatalog
    private var cachedCatalog: SpeechModelCatalog
    private let cacheURL: URL

    public init(
        bundledCatalog: SpeechModelCatalog? = nil,
        cachedCatalog: SpeechModelCatalog? = nil,
        transport: any CatalogTransport = URLSessionCatalogTransport(),
        cacheURL: URL = RuntimePaths.modelCatalogCacheURL()
    ) {
        self.transport = transport
        self.cacheURL = cacheURL
        let bundled = bundledCatalog ?? Self.loadBundledCatalog()
        self.bundledCatalog = bundled
        let cached = cachedCatalog ?? Self.loadCachedCatalog(from: cacheURL)
        self.cachedCatalog = Self.preferredCatalog(bundled: bundled, cached: cached)
    }

    public var current: SpeechModelCatalog {
        lock.lock()
        defer { lock.unlock() }
        return cachedCatalog
    }

    public func refresh(from url: URL = VoxDefaults.resolvedModelCatalogURL()) async throws -> SpeechModelCatalog {
        let data = try await transport.fetch(from: url)
        let catalog = try SpeechModelCatalog.decode(from: data)
        persist(catalog)
        return catalog
    }

    public func asrModels(family: String? = nil, readyOnly: Bool = true) -> [SpeechModelCatalogEntry] {
        current.models(kind: "asr", family: family, readyOnly: readyOnly)
    }

    func parakeetManifests() -> [ParakeetModelManifest] {
        asrModels(family: SpeechModelFamily.parakeetTDT).compactMap(ParakeetModelManifest.init(entry:))
    }

    public func parakeetModelIDs() -> [String] {
        parakeetManifests().map(\.modelId)
    }

    public func mlxAudioModelIDs() -> [String] {
        asrModels(family: SpeechModelFamily.mlxAudio).map(\.id)
    }

    public func appleSpeechModelIDs() -> [String] {
        asrModels(family: SpeechModelFamily.appleSpeech).map(\.id)
    }

    public func openaiTranscribeModelIDs() -> [String] {
        asrModels(family: SpeechModelFamily.openaiTranscribe).map(\.id)
    }

    private func persist(_ catalog: SpeechModelCatalog) {
        lock.lock()
        cachedCatalog = catalog
        lock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(catalog).write(to: cacheURL, options: .atomic)
        } catch {
            VoxLog.engine.warning("Failed to cache model catalog: \(error.localizedDescription)")
        }
    }

    static func loadBundledCatalog() -> SpeechModelCatalog {
        if let url = SpeechEngineResources.url(forResource: "models", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let catalog = try? SpeechModelCatalog.decode(from: data) {
            return catalog
        }
        return fallbackCatalog
    }

    private static func loadCachedCatalog(from url: URL) -> SpeechModelCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SpeechModelCatalog.decode(from: data)
    }

    static func preferredCatalog(
        bundled: SpeechModelCatalog,
        cached: SpeechModelCatalog?
    ) -> SpeechModelCatalog {
        guard let cached else { return bundled }
        if cached.version != bundled.version {
            return cached.version > bundled.version ? cached : bundled
        }
        return cached.updatedAt >= bundled.updatedAt ? cached : bundled
    }

    static let fallbackCatalog = SpeechModelCatalog(
        version: 1,
        updatedAt: "2026-08-29",
        models: [
            SpeechModelCatalogEntry(
                id: "parakeet:v3",
                family: SpeechModelFamily.parakeetTDT,
                name: "Parakeet TDT v3",
                vendor: "nvidia",
                runtime: "coreml",
                isDefault: true,
                languages: "25 European languages",
                source: SpeechModelSource(type: "huggingface", repo: "arach/parakeet-tdt-0.6b-v3-coreml", revision: "743fa35d26213cbc8de1e001bfdc76ed0530abe8"),
                parakeet: ParakeetCatalogSpec(
                    cacheDirectoryName: "parakeet-tdt-0.6b-v3-743fa35",
                    jointFile: "JointDecisionv3.mlmodelc",
                    vocabularyFile: "parakeet_vocab.json",
                    blankId: 8192,
                    requiredFiles: [
                        "Preprocessor.mlmodelc",
                        "Encoder.mlmodelc",
                        "Decoder.mlmodelc",
                        "JointDecisionv3.mlmodelc"
                    ]
                )
            ),
            SpeechModelCatalogEntry(
                id: "parakeet:v2",
                family: SpeechModelFamily.parakeetTDT,
                name: "Parakeet TDT v2",
                vendor: "nvidia",
                runtime: "coreml",
                languages: "English",
                source: SpeechModelSource(type: "huggingface", repo: "FluidInference/parakeet-tdt-0.6b-v2-coreml"),
                parakeet: ParakeetCatalogSpec(
                    cacheDirectoryName: "parakeet-tdt-0.6b-v2",
                    jointFile: "JointDecision.mlmodelc",
                    vocabularyFile: "parakeet_vocab.json",
                    blankId: 1024,
                    requiredFiles: [
                        "Preprocessor.mlmodelc",
                        "Encoder.mlmodelc",
                        "Decoder.mlmodelc",
                        "JointDecision.mlmodelc"
                    ]
                )
            )
        ]
    )
}
