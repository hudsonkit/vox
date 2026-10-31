import Foundation
import VoxCore
import VoxEngine
import VoxAppleSpeech

/// Public-only consumer. No direct AVSpeechSynthesizer, Speech, or daemon ownership.
public actor ReadoutSurface {
    private let output: AppleSpeechOutputController

    public init(onEvent: @escaping @Sendable (SpeechOutputEvent) -> Void) {
        output = AppleSpeechOutputController(onEvent: onEvent)
    }

    public func start(text: String, voiceId: String? = nil, speed: Double? = nil,
                      pitchMultiplier: Double? = nil, volume: Double? = nil) async throws -> SpeechOutputIdentity {
        try await output.start(SynthesisRequest(text: text, modelId: TTSDefaults.localModelId, voiceId: voiceId, speed: speed),
                               options: SpeechOutputOptions(pitchMultiplier: pitchMultiplier, volume: volume))
    }

    public func pause(_ identity: SpeechOutputIdentity) async throws -> Bool { try await output.pause(identity) }
    public func resume(_ identity: SpeechOutputIdentity) async throws -> Bool { try await output.resume(identity) }
    public func seek(_ identity: SpeechOutputIdentity, toOriginalUTF16Offset offset: Int) async throws -> SpeechOutputIdentity {
        try await output.seek(identity, toUTF16Offset: offset)
    }
    public func stop(_ identity: SpeechOutputIdentity) async throws { try await output.stop(identity) }
    public func cancel(_ identity: SpeechOutputIdentity) async throws { try await output.cancel(identity) }
    public func status() async -> SpeechOutputStatus? { await output.status() }

    /// The caller must supply the same unmodified request text and re-check after UI hops.
    public nonisolated static func highlightRange(
        _ event: SpeechOutputEvent, current identity: SpeechOutputIdentity, in originalText: String
    ) -> Range<String.Index>? {
        guard event.identity == identity, event.phase == .wordRange, let range = event.utf16Range else { return nil }
        return Range(range.nsRange, in: originalText)
    }

    /// Inventory only: no install, Core ML load or inference. False on Simulator.
    public func nativeStreamingAvailable() async -> Bool {
        await NativeStreamingASR.shared.models().contains { $0.id == StreamingASRDefaults.modelId && $0.available }
    }
}
