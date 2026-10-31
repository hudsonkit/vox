import Foundation

public struct AnnotationAudioEvent: Codable, Sendable, Equatable {
    public let label: String
    public let start: Double
    public let end: Double
    public let speakerId: String?
    public let logProbability: Double?
    public init(label: String, start: Double, end: Double, speakerId: String? = nil, logProbability: Double? = nil) {
        self.label = label; self.start = start; self.end = end
        self.speakerId = speakerId; self.logProbability = logProbability
    }
    public func dictionaryValue() -> [String: Any] {
        ["label": label, "start": start, "end": end, "speakerId": speakerId ?? NSNull(),
         "logProbability": logProbability ?? NSNull()]
    }
}

public struct AnnotationModelInfo: Codable, Sendable, Equatable {
    public let id: String
    public let providerId: String
    public let nativeModelId: String
    public let remote: Bool
    public let capabilities: [String: Bool]
    public let requiresCredentials: [String]
    public let unsupportedFields: [String]
    public let maxInputBytes: Int
    public init(id: String, providerId: String, nativeModelId: String, capabilities: [String: Bool],
                requiresCredentials: [String], unsupportedFields: [String], maxInputBytes: Int, remote: Bool = true) {
        self.id = id; self.providerId = providerId; self.nativeModelId = nativeModelId
        self.capabilities = capabilities; self.requiresCredentials = requiresCredentials
        self.unsupportedFields = unsupportedFields; self.maxInputBytes = maxInputBytes; self.remote = remote
    }
    public func dictionaryValue() -> [String: Any] {
        ["id": id, "providerId": providerId, "nativeModelId": nativeModelId, "remote": remote,
         "capabilities": capabilities, "requiresCredentials": requiresCredentials,
         "unsupportedFields": unsupportedFields, "maxInputBytes": maxInputBytes]
    }
}

/// Annotation has no ambient credential fallback. Only the explicitly selected request key is used.
public enum AnnotationLentCredentials {
    public static let allowedKeys: Set<String> = ["ELEVENLABS_API_KEY", "DEEPGRAM_API_KEY"]
    public static func parse(from container: [String: Any]?) -> [String: String] {
        guard let raw = container?["credentials"] as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for key in allowedKeys {
            if let value = raw[key] as? String { result[key] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return result
    }
}
