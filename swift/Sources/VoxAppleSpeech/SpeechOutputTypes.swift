import Foundation
import VoxCore
import VoxEngine

/// How a synthesis model should be delivered on an Apple audible surface.
///
/// This is a route/model capability for playback. It does not add `speak()` to
/// `TTSProvider`, which stays generation-only.
public enum SpeechOutputDelivery: String, Sendable, Codable, Equatable {
    /// Live `AVSpeechSynthesizer.speak()`. Do not `write()`-then-play.
    case liveSystem
    /// Provider-generated audio bytes played through a local audio sink.
    case generatedAudio
}

/// Physical playback path used by one controller instance.
public enum SpeechAudioOutputKind: String, Sendable, Codable, Equatable {
    case systemSynthesizer
    case generatedAudioPlayer
}

public struct SpeechAudioOutputRoute: Sendable, Equatable {
    public var kind: SpeechAudioOutputKind

    public init(kind: SpeechAudioOutputKind) {
        self.kind = kind
    }
}

/// Synthesis identity is reported separately from the physical audio-output route.
///
/// `backend` is `TTSModelInfo.backend` when known. It is not a provider id.
/// Requested model/voice stay on the request fields; actual model/voice are
/// filled in after resolve or generation.
public struct SpeechSynthesisIdentity: Sendable, Equatable {
    public var requestedModelId: String
    public var modelId: String
    public var requestedVoiceId: String?
    public var voiceId: String?
    public var backend: String?
    public var delivery: SpeechOutputDelivery

    public init(
        requestedModelId: String,
        modelId: String? = nil,
        requestedVoiceId: String? = nil,
        voiceId: String? = nil,
        backend: String? = nil,
        delivery: SpeechOutputDelivery
    ) {
        self.requestedModelId = requestedModelId
        self.modelId = modelId ?? requestedModelId
        self.requestedVoiceId = requestedVoiceId
        self.voiceId = voiceId
        self.backend = backend
        self.delivery = delivery
    }
}

public struct SpeechOutputRouteCapability: Sendable, Equatable {
    public var modelId: String
    public var backend: String?
    public var delivery: SpeechOutputDelivery
    public var audioOutput: SpeechAudioOutputRoute

    public init(
        modelId: String,
        backend: String? = nil,
        delivery: SpeechOutputDelivery,
        audioOutput: SpeechAudioOutputRoute
    ) {
        self.modelId = modelId
        self.backend = backend
        self.delivery = delivery
        self.audioOutput = audioOutput
    }
}

/// Capabilities of the actual playback sink, not synthesis-model accuracy.
public struct SpeechPlaybackCapabilities: Sendable, Equatable {
    public var canPauseResume: Bool
    public var canReportUTF16Ranges: Bool
    public var canSeekByReplacement: Bool

    public init(canPauseResume: Bool = false, canReportUTF16Ranges: Bool = false, canSeekByReplacement: Bool = false) {
        self.canPauseResume = canPauseResume
        self.canReportUTF16Ranges = canReportUTF16Ranges
        self.canSeekByReplacement = canSeekByReplacement
    }

    public static let unavailable = Self()
    public static let systemSpeech = Self(canPauseResume: true, canReportUTF16Ranges: true, canSeekByReplacement: true)
    public static let generatedAudio = Self(canPauseResume: true)
}

/// Both fields must match for an identity-scoped control to mutate playback.
public struct SpeechOutputIdentity: Sendable, Equatable, Hashable {
    public let requestId: String
    public let generation: UInt64
    public init(requestId: String, generation: UInt64) {
        self.requestId = requestId
        self.generation = generation
    }
}

/// UTF-16 code units, relative to the original, unmodified SynthesisRequest.text.
/// These are platform will-speak callbacks, not forced alignment or playback clocks.
public struct SpeechUTF16Range: Sendable, Equatable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
    public var nsRange: NSRange { NSRange(location: location, length: length) }
}

public struct SpeechOutputStatus: Sendable, Equatable {
    public let identity: SpeechOutputIdentity
    public let phase: SpeechOutputPhase
    public let capabilities: SpeechPlaybackCapabilities
    public let startingAtUTF16Offset: Int
    public let originalTextUTF16Length: Int
}

public enum SpeechOutputControlError: Error, Sendable, Equatable, LocalizedError {
    case staleIdentity, unsupported, notReady, controlPending, invalidUTF16Offset
    public var errorDescription: String? {
        switch self {
        case .staleIdentity: return "Speech playback identity is no longer active."
        case .unsupported: return "The playback sink does not support this control."
        case .notReady: return "Speech playback is not in the required state."
        case .controlPending: return "A speech playback control is awaiting acknowledgement."
        case .invalidUTF16Offset: return "Seek requires a character boundary before nonempty remaining text."
        }
    }
}

public enum SpeechOutputPhase: String, Sendable, Codable, Equatable {
    case resolving
    case generating
    case starting
    case playing
    case paused
    case resumed
    case wordRange
    case finished
    case cancelled
    case failed
}

public struct SpeechOutputEvent: Sendable, Equatable {
    public var requestId: String
    public var generation: UInt64
    public var phase: SpeechOutputPhase
    public var synthesis: SpeechSynthesisIdentity
    public var audioOutput: SpeechAudioOutputRoute
    public var error: String?
    public var utf16Range: SpeechUTF16Range?
    public var capabilities: SpeechPlaybackCapabilities
    public var identity: SpeechOutputIdentity { SpeechOutputIdentity(requestId: requestId, generation: generation) }

    public init(
        requestId: String,
        generation: UInt64,
        phase: SpeechOutputPhase,
        synthesis: SpeechSynthesisIdentity,
        audioOutput: SpeechAudioOutputRoute,
        error: String? = nil,
        utf16Range: SpeechUTF16Range? = nil,
        capabilities: SpeechPlaybackCapabilities = .unavailable
    ) {
        self.requestId = requestId
        self.generation = generation
        self.phase = phase
        self.synthesis = synthesis
        self.audioOutput = audioOutput
        self.error = error
        self.utf16Range = utf16Range
        self.capabilities = capabilities
    }
}

public enum SpeechOutputError: Error, Sendable, Equatable, LocalizedError {
    case missingText
    case unsupportedVoice(String)
    case noSystemVoices
    case audioSessionFailed(String)
    case playerFailedToStart
    case playerFailed(String)
    case playerFactoryFailed(String)
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingText:
            return "Missing text"
        case .unsupportedVoice(let voiceId):
            return "Unsupported voice: \(voiceId)"
        case .noSystemVoices:
            return "No system speech voices are available."
        case .audioSessionFailed(let message):
            return message
        case .playerFailedToStart:
            return "Audio player failed to start."
        case .playerFailed(let message):
            return message
        case .playerFactoryFailed(let message):
            return message
        case .generationFailed(let message):
            return message
        }
    }
}

/// Provider-neutral synthesis speed mapped onto AVSpeech utterance rates.
///
/// `1.0` is the platform default, `0.25` is minimum, and `4.0` is maximum.
enum SpeechOutputRate {
    static func map(
        speed: Double,
        minimum: Float,
        defaultRate: Float,
        maximum: Float
    ) -> Float {
        let clamped = min(max(speed, 0.25), 4.0)
        if clamped <= 1.0 {
            let t = Float((clamped - 0.25) / 0.75)
            return minimum + t * (defaultRate - minimum)
        }
        let t = Float((clamped - 1.0) / 3.0)
        return defaultRate + t * (maximum - defaultRate)
    }
}

struct SystemVoiceDescriptor: Sendable, Equatable {
    var identifier: String
    var language: String

    init(identifier: String, language: String) {
        self.identifier = identifier
        self.language = language
    }
}

/// Picks a system voice from an explicit id or BCP-47 preferred languages.
enum SystemVoiceResolver {
    static func languageCandidates(preferredLanguages: [String]) -> [String] {
        var tags: [String] = []
        for language in preferredLanguages {
            let tag = language.replacingOccurrences(of: "_", with: "-")
            if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                tags.append(tag)
            }
        }
        if !tags.contains(where: { $0.caseInsensitiveCompare("en-US") == .orderedSame }) {
            tags.append("en-US")
        }
        return tags
    }

    static func resolve(
        voiceId: String?,
        voices: [SystemVoiceDescriptor],
        preferredLanguages: [String]
    ) throws -> SystemVoiceDescriptor {
        guard !voices.isEmpty else {
            throw SpeechOutputError.noSystemVoices
        }

        if let voiceId {
            if let voice = voices.first(where: { $0.identifier == voiceId }) {
                return voice
            }
            throw SpeechOutputError.unsupportedVoice(voiceId)
        }

        for tag in languageCandidates(preferredLanguages: preferredLanguages) {
            if let voice = voices.first(where: { Self.matches(language: $0.language, tag: tag) }) {
                return voice
            }
        }
        return voices[0]
    }

    private static func matches(language: String, tag: String) -> Bool {
        language.replacingOccurrences(of: "_", with: "-")
            .caseInsensitiveCompare(tag) == .orderedSame
    }
}

public enum SpeechOutputCapabilities {
    public static func delivery(forModelId modelId: String, backend: String? = nil) -> SpeechOutputDelivery {
        if modelId == TTSDefaults.localModelId {
            return .liveSystem
        }
        if backend?.lowercased() == "avspeech" {
            return .liveSystem
        }
        return .generatedAudio
    }

    public static func audioOutput(for delivery: SpeechOutputDelivery) -> SpeechAudioOutputRoute {
        switch delivery {
        case .liveSystem:
            return SpeechAudioOutputRoute(kind: .systemSynthesizer)
        case .generatedAudio:
            return SpeechAudioOutputRoute(kind: .generatedAudioPlayer)
        }
    }

    public static func capability(forModelId modelId: String, backend: String? = nil) -> SpeechOutputRouteCapability {
        let delivery = delivery(forModelId: modelId, backend: backend)
        return SpeechOutputRouteCapability(
            modelId: modelId,
            backend: backend,
            delivery: delivery,
            audioOutput: audioOutput(for: delivery)
        )
    }

    public static func capability(for model: TTSModelInfo) -> SpeechOutputRouteCapability {
        capability(forModelId: model.id, backend: model.backend)
    }
}
