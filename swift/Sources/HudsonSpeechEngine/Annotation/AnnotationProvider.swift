import Foundation
import VoxCore

public struct AnnotationInputTranscription: Sendable, Equatable {
    public let text: String
    public let words: [WordTiming]

    public init(text: String, words: [WordTiming]) {
        self.text = text
        self.words = words
    }
}

public struct AnnotationRequest: Sendable, Equatable {
    public let url: URL
    public let modelId: String
    public let transcription: AnnotationInputTranscription?
    public let providerCredentials: [String: String]
    public let diarize: Bool
    public let tagAudioEvents: Bool?
    public let languageCode: String?
    public let numSpeakers: Int?

    public init(
        url: URL,
        modelId: String,
        transcription: AnnotationInputTranscription? = nil,
        providerCredentials: [String: String] = [:], diarize: Bool = true,
        tagAudioEvents: Bool? = nil, languageCode: String? = nil, numSpeakers: Int? = nil
    ) {
        self.url = url
        self.modelId = modelId
        self.transcription = transcription
        self.providerCredentials = providerCredentials; self.diarize = diarize
        self.tagAudioEvents = tagAudioEvents; self.languageCode = languageCode; self.numSpeakers = numSpeakers
    }
}

public enum AnnotationProviderError: LocalizedError {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return message
        }
    }
}

public protocol AnnotationProvider: Sendable {
    func models() async -> [AnnotationModelInfo]
    func annotate(request: AnnotationRequest) async throws -> AnnotationOutput
}

extension AnnotationProvider {
    public func models() async -> [AnnotationModelInfo] { [] }
}

public struct UnavailableAnnotationProvider: AnnotationProvider {
    private let message: String

    public init(
        message: String = "Speaker annotation is not configured in this build yet."
    ) {
        self.message = message
    }

    public func annotate(request: AnnotationRequest) async throws -> AnnotationOutput {
        throw AnnotationProviderError.unavailable(message)
    }
}

public actor AnnotationManager {
    private let provider: any AnnotationProvider

    public init(provider: any AnnotationProvider = RemoteAnnotationProvider()) {
        self.provider = provider
    }

    public func models() async -> [AnnotationModelInfo] { await provider.models() }

    public func annotate(request: AnnotationRequest) async throws -> AnnotationOutput {
        try await provider.annotate(request: request)
    }
}
