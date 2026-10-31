import AVFoundation
import Foundation
import VoxCore

public actor AVSpeechSynthesizerProvider: TTSProvider {
    public static let modelID = TTSDefaults.localModelId

    private let log = VoxLog.engine
    private var preloaded = false

    public init() {}

    public func models() async -> [TTSModelInfo] {
        let available = await MainActor.run {
            !AVSpeechSynthesisVoice.speechVoices().isEmpty
        }

        return [
            TTSModelInfo(
                id: Self.modelID,
                name: "Apple Speech Synthesizer",
                backend: "avspeech",
                installed: available,
                preloaded: preloaded,
                available: available
            )
        ]
    }

    public func voices(modelId: String?) async throws -> [TTSVoiceInfo] {
        let resolvedModelId = modelId ?? Self.modelID
        try validate(modelId: resolvedModelId)
        return await MainActor.run {
            let voices = AVSpeechSynthesisVoice.speechVoices()
            let fallbackID = AVSpeechSynthesizerProvider.defaultVoiceIdentifier(in: voices)
            return voices.map { voice in
                TTSVoiceInfo(
                    id: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    backend: "avspeech",
                    modelId: Self.modelID,
                    available: true,
                    isDefault: voice.identifier == fallbackID,
                    quality: Self.normalizedQuality(voice.quality)
                )
            }
        }
    }

    nonisolated static func normalizedQuality(_ quality: AVSpeechSynthesisVoiceQuality) -> TTSVoiceQuality? {
        switch quality {
        case .default: return .standard
        case .enhanced: return .enhanced
        case .premium: return .premium
        @unknown default: return nil
        }
    }

    public func preload(
        modelId: String,
        voiceId: String?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> TTSModelInfo {
        try validate(modelId: modelId)
        progress(ModelProgress(modelId: modelId, progress: 0.1, status: "starting"))
        _ = try await resolveVoice(voiceId: voiceId)
        preloaded = true
        progress(ModelProgress(modelId: modelId, progress: 1.0, status: "ready"))
        return (await models()).first ?? TTSModelInfo(
            id: Self.modelID,
            name: "Apple Speech Synthesizer",
            backend: "avspeech",
            installed: true,
            preloaded: true,
            available: true
        )
    }

    public func synthesize(_ request: SynthesisRequest) async throws -> SynthesisOutput {
        try validate(modelId: request.modelId)
        try validate(format: request.format)
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "VoxEngine", code: 5001, userInfo: [
                NSLocalizedDescriptionKey: "Missing text"
            ])
        }

        let trace = TranscriptionTrace()

        trace.begin("model_check")
        let wasPreloaded = preloaded
        trace.end(wasPreloaded ? "ready" : "cold")

        if !wasPreloaded {
            trace.begin("model_load")
            preloaded = true
            trace.end("prepared")
        }

        trace.begin("voice_resolve")
        let voice = try await resolveVoice(voiceId: request.voiceId)
        trace.end(voice.identifier)

        trace.begin("inference")
        let rendered = try await AVSpeechSynthesisRenderer.render(
            requestId: request.requestId,
            text: request.text,
            voice: voice,
            speed: request.speed
        )
        let synthesisMs = trace.end("\(rendered.outputBytes) bytes")
        let audioData = try Data(contentsOf: rendered.url)
        try? FileManager.default.removeItem(at: rendered.url)

        let metrics = SynthesisMetrics(
            traceId: trace.traceId,
            characterCount: request.text.count,
            audioDurationMs: rendered.audioDurationMs,
            outputBytes: rendered.outputBytes,
            wasPreloaded: wasPreloaded,
            modelCheckMs: trace.durationMs(for: "model_check"),
            modelLoadMs: trace.durationMs(for: "model_load"),
            voiceResolveMs: trace.durationMs(for: "voice_resolve"),
            synthesisMs: synthesisMs,
            totalMs: trace.elapsedMs
        )

        log.info("Synthesis trace complete \(trace.summary)")
        return SynthesisOutput(
            modelId: request.modelId,
            voiceId: voice.identifier,
            format: request.format.lowercased(),
            contentType: "audio/wav",
            audioData: audioData,
            elapsedMs: metrics.totalMs,
            metrics: metrics
        )
    }

    private func validate(modelId: String) throws {
        guard modelId == Self.modelID else {
            throw NSError(domain: "VoxEngine", code: 5002, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported synthesis model: \(modelId)"
            ])
        }
    }

    private func validate(format: String) throws {
        guard format.lowercased() == TTSDefaults.format else {
            throw NSError(domain: "VoxEngine", code: 5003, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported synthesis format: \(format). Only wav is currently supported."
            ])
        }
    }

    private func resolveVoice(voiceId: String?) async throws -> AVSpeechSynthesisVoice {
        try await MainActor.run {
            let voices = AVSpeechSynthesisVoice.speechVoices()
            guard !voices.isEmpty else {
                throw NSError(domain: "VoxEngine", code: 5004, userInfo: [
                    NSLocalizedDescriptionKey: "No system speech voices are available."
                ])
            }

            if let voiceId {
                if let voice = voices.first(where: { $0.identifier == voiceId }) {
                    return voice
                }
                throw NSError(domain: "VoxEngine", code: 5005, userInfo: [
                    NSLocalizedDescriptionKey: "Unsupported voice: \(voiceId)"
                ])
            }

            let fallbackID = AVSpeechSynthesizerProvider.defaultVoiceIdentifier(in: voices)
            return voices.first(where: { $0.identifier == fallbackID }) ?? voices[0]
        }
    }

    @MainActor
    private static func defaultVoiceIdentifier(in voices: [AVSpeechSynthesisVoice]) -> String? {
        let preferredLanguage = Locale.autoupdatingCurrent.identifier
        if let voice = AVSpeechSynthesisVoice(language: preferredLanguage) {
            return voice.identifier
        }
        if let englishVoice = AVSpeechSynthesisVoice(language: "en-US") {
            return englishVoice.identifier
        }
        return voices.first?.identifier
    }
}

private struct RenderedSpeechArtifact: Sendable {
    let url: URL
    let audioDurationMs: Int
    let outputBytes: Int
}

@MainActor
private final class AVSpeechSynthesisRenderer {
    private let synthesizer = AVSpeechSynthesizer()
    private var outputFile: AVAudioFile?
    private var outputURL: URL?
    private var outputFormat: AVAudioFormat?
    private var totalFrames: AVAudioFramePosition = 0
    private var continuation: CheckedContinuation<RenderedSpeechArtifact, Error>?
    private var didResume = false

    static func render(
        requestId: String,
        text: String,
        voice: AVSpeechSynthesisVoice,
        speed: Double?
    ) async throws -> RenderedSpeechArtifact {
        let renderer = AVSpeechSynthesisRenderer()
        return try await renderer.render(requestId: requestId, text: text, voice: voice, speed: speed)
    }

    private func render(
        requestId: String,
        text: String,
        voice: AVSpeechSynthesisVoice,
        speed: Double?
    ) async throws -> RenderedSpeechArtifact {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        if let speed {
            let clamped = min(max(speed, 0.25), 4.0)
            let minRate = AVSpeechUtteranceMinimumSpeechRate
            let maxRate = AVSpeechUtteranceMaximumSpeechRate
            utterance.rate = minRate + Float((clamped - 0.25) / 3.75) * (maxRate - minRate)
        }

        outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vox-\(requestId)")
            .appendingPathExtension(TTSDefaults.format)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                synthesizer.write(utterance) { [weak self] buffer in
                    guard let self else { return }
                    Task { @MainActor in
                        self.handle(buffer)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel()
            }
        }
    }

    private func handle(_ buffer: AVAudioBuffer) {
        guard !didResume else { return }
        guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

        if pcmBuffer.frameLength == 0 {
            finishSuccessfully()
            return
        }

        do {
            if outputFile == nil {
                guard let outputURL else {
                    throw NSError(domain: "VoxEngine", code: 5006, userInfo: [
                        NSLocalizedDescriptionKey: "Missing synthesis output URL."
                    ])
                }

                outputFormat = pcmBuffer.format
                outputFile = try AVAudioFile(forWriting: outputURL, settings: pcmBuffer.format.settings)
            }

            try outputFile?.write(from: pcmBuffer)
            totalFrames += AVAudioFramePosition(pcmBuffer.frameLength)
        } catch {
            finish(with: .failure(error))
        }
    }

    private func finishSuccessfully() {
        guard let outputURL else {
            finish(with: .failure(NSError(domain: "VoxEngine", code: 5007, userInfo: [
                NSLocalizedDescriptionKey: "Missing synthesized output."
            ])))
            return
        }

        let sampleRate = outputFormat?.sampleRate ?? 0
        let durationMs = sampleRate > 0
            ? Int((Double(totalFrames) / sampleRate) * 1000)
            : 0

        outputFile = nil
        let outputBytes = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue) ?? 0
        finish(with: .success(RenderedSpeechArtifact(
            url: outputURL,
            audioDurationMs: durationMs,
            outputBytes: outputBytes
        )))
    }

    private func cancel() {
        guard !didResume else { return }
        synthesizer.stopSpeaking(at: .immediate)
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        finish(with: .failure(CancellationError()))
    }

    private func finish(with result: Result<RenderedSpeechArtifact, Error>) {
        guard !didResume else { return }
        didResume = true

        let continuation = self.continuation
        self.continuation = nil
        self.outputFile = nil

        switch result {
        case .success(let artifact):
            continuation?.resume(returning: artifact)
        case .failure(let error):
            if let outputURL {
                try? FileManager.default.removeItem(at: outputURL)
            }
            continuation?.resume(throwing: error)
        }
    }
}
