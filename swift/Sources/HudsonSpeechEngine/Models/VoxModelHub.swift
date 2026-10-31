import Foundation
import VoxCore

enum VoxModelHubError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case rateLimited(statusCode: Int, message: String)
    case downloadFailed(path: String, underlying: Error)
    case modelNotFound(path: String)
    case htmlErrorResponse(path: String, snippet: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let urlString):
            return "Invalid model URL: \(urlString)"
        case .invalidResponse:
            return "Received an invalid response from the model registry."
        case .rateLimited(_, let message):
            return "Model registry rate limit encountered: \(message)"
        case .downloadFailed(let path, let underlying):
            return "Failed to download \(path): \(underlying.localizedDescription)"
        case .modelNotFound(let path):
            return "Model file not found: \(path)"
        case .htmlErrorResponse(let path, let snippet):
            return "Model registry returned HTML instead of JSON for \(path): \(snippet)"
        }
    }
}

enum VoxModelHub {
    private static let log = VoxLog.engine
    private static let sharedSession: URLSession = configuredSession()

    static var baseURL: String {
        ProcessInfo.processInfo.environment["REGISTRY_URL"]
            ?? ProcessInfo.processInfo.environment["MODEL_REGISTRY_URL"]
            ?? "https://huggingface.co"
    }

    private static var huggingFaceToken: String? {
        ProcessInfo.processInfo.environment["HF_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGING_FACE_HUB_TOKEN"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACEHUB_API_TOKEN"]
    }

    static func apiModelsURL(_ repoPath: String, _ apiPath: String) throws -> URL {
        let urlString = "\(baseURL)/api/models/\(repoPath)/\(apiPath)"
        guard let url = URL(string: urlString) else {
            throw VoxModelHubError.invalidURL(urlString)
        }
        return url
    }

    static func resolveModelURL(_ repoPath: String, _ filePath: String, revision: String = "main") throws -> URL {
        let urlString = "\(baseURL)/\(repoPath)/resolve/\(revision)/\(filePath)"
        guard let url = URL(string: urlString) else {
            throw VoxModelHubError.invalidURL(urlString)
        }
        return url
    }

    static func listDirectory(repoPath: String, path: String, revision: String = "main") async throws -> [[String: Any]] {
        let apiPath = path.isEmpty ? "tree/\(revision)" : "tree/\(revision)/\(path)"
        let url = try apiModelsURL(repoPath, apiPath)
        let request = authorizedRequest(url: url)
        let (data, response) = try await sharedSession.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
            throw VoxModelHubError.rateLimited(
                statusCode: httpResponse.statusCode,
                message: "Rate limited while listing files"
            )
        }

        try validateJSONResponse(data, path: path)
        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw VoxModelHubError.invalidResponse
        }
        return items
    }

    static func downloadFile(
        repoPath: String,
        remotePath: String,
        to destinationURL: URL,
        revision: String = "main"
    ) async throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return
        }

        let parentDirectory = destinationURL.deletingLastPathComponent()
        try createDirectoryRobustly(at: parentDirectory)

        let encodedPath = remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remotePath
        let url = try resolveModelURL(repoPath, encodedPath, revision: revision)
        let request = authorizedRequest(url: url)
        let (temporaryURL, response) = try await sharedSession.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoxModelHubError.invalidResponse
        }
        if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
            throw VoxModelHubError.rateLimited(
                statusCode: httpResponse.statusCode,
                message: "Rate limited while downloading \(remotePath)"
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw VoxModelHubError.downloadFailed(
                path: remotePath,
                underlying: NSError(domain: "HTTP", code: httpResponse.statusCode)
            )
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    static func createDirectoryRobustly(at url: URL) throws {
        let fileManager = FileManager.default
        var pathComponents = url.pathComponents
        if pathComponents.first == "/" {
            pathComponents.removeFirst()
        }

        var currentPath = "/"
        for component in pathComponents {
            currentPath = (currentPath as NSString).appendingPathComponent(component)
            let componentURL = URL(fileURLWithPath: currentPath)

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: currentPath, isDirectory: &isDirectory) {
                if !isDirectory.boolValue {
                    log.warning("Removing file blocking directory creation: \(currentPath)")
                    try fileManager.removeItem(at: componentURL)
                    try fileManager.createDirectory(at: componentURL, withIntermediateDirectories: false)
                }
            } else {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return
            }
        }
    }

    private static func authorizedRequest(url: URL, timeout: TimeInterval = 1800) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        if let token = huggingFaceToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func validateJSONResponse(_ data: Data, path: String) throws {
        if let responseString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           responseString.hasPrefix("<") || responseString.lowercased().contains("<!doctype html") {
            let snippet = String(responseString.prefix(100))
            throw VoxModelHubError.htmlErrorResponse(path: path, snippet: snippet)
        }
    }

    private static func configuredSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        if let proxyConfig = configureProxySettings() {
            configuration.connectionProxyDictionary = proxyConfig
        }
        return URLSession(configuration: configuration)
    }

    private static func configureProxySettings() -> [String: Any]? {
        #if os(macOS)
        var proxyConfig: [String: Any] = [:]
        if let httpsProxy = ProcessInfo.processInfo.environment["https_proxy"],
           let proxySettings = parseProxyURL(httpsProxy, type: "HTTPS") {
            proxyConfig.merge(proxySettings) { _, new in new }
        }
        if let httpProxy = ProcessInfo.processInfo.environment["http_proxy"],
           let proxySettings = parseProxyURL(httpProxy, type: "HTTP") {
            proxyConfig.merge(proxySettings) { _, new in new }
        }
        return proxyConfig.isEmpty ? nil : proxyConfig
        #else
        return nil
        #endif
    }

    private static func parseProxyURL(_ proxyURLString: String, type: String) -> [String: Any]? {
        #if os(macOS)
        guard let proxyURL = URL(string: proxyURLString),
              let host = proxyURL.host,
              let port = proxyURL.port else {
            log.warning("Invalid \(type) proxy URL: \(proxyURLString)")
            return nil
        }

        let enableKey: String
        let proxyKey: String
        let portKey: String

        switch type {
        case "HTTPS":
            enableKey = kCFNetworkProxiesHTTPSEnable as String
            proxyKey = kCFNetworkProxiesHTTPSProxy as String
            portKey = kCFNetworkProxiesHTTPSPort as String
        case "HTTP":
            enableKey = kCFNetworkProxiesHTTPEnable as String
            proxyKey = kCFNetworkProxiesHTTPProxy as String
            portKey = kCFNetworkProxiesHTTPPort as String
        default:
            return nil
        }

        return [
            enableKey: true,
            proxyKey: host,
            portKey: port,
        ]
        #else
        return nil
        #endif
    }
}
