import AVFoundation
import Foundation
import VoxCore

public enum VoxDictationError: LocalizedError, Equatable {
    case alreadyListening
    case notListening

    public var errorDescription: String? {
        switch self {
        case .alreadyListening: "Dictation is already listening."
        case .notListening: "Dictation is not listening."
        }
    }
}

/// Dictation in one object: warm up, start, stop for text, or cancel.
///
/// Records the microphone to a temporary file, transcribes it on device, and
/// writes a performance sample for every transcription. Warm-up stays
/// explicit: call `warmUp()` when the user shows intent to dictate, or the
/// first `stop()` pays the model load.
///
/// Microphone capture is macOS only for now. On iOS, record audio in the app
/// and pass the file to `transcribe(fileURL:)`.
public actor VoxDictation {
    /// Route recorded for microphone dictation.
    public static let dictationRoute = "transcribe.dictation"
    /// Route recorded for file transcription, shared with Vox Companion.
    public static let fileRoute = "transcribe.file"

    public let clientId: String
    public let modelId: String

    private let engine: EngineManager
    private let recorder = MicrophoneFileRecorder()
    private let performance: PerformanceRecorder?
    private let preferredInputDeviceID: String?

    public private(set) var isReady = false

    /// - Parameters:
    ///   - clientId: Names your app in performance samples.
    ///   - modelId: Any installed ASR model. `parakeet:v3` is multilingual;
    ///     `parakeet:v2` is English only.
    ///   - preferredInputDeviceID: A microphone from
    ///     `MicrophoneFileRecorder.available()`, or nil for the system default.
    ///   - engine: Swap in a different ASR provider.
    ///   - recordsPerformance: Write samples to `RuntimePaths.performanceLogURL()`.
    public init(
        clientId: String,
        modelId: String = "parakeet:v3",
        preferredInputDeviceID: String? = nil,
        engine: EngineManager = EngineManager(),
        recordsPerformance: Bool = true
    ) {
        self.clientId = clientId
        self.modelId = modelId
        self.preferredInputDeviceID = preferredInputDeviceID
        self.engine = engine
        self.performance = recordsPerformance ? PerformanceRecorder() : nil
    }

    /// Downloads the model if needed and loads it into memory.
    @discardableResult
    public func warmUp(
        progress: @escaping @Sendable (ModelProgress) -> Void = { _ in }
    ) async throws -> ASRModelInfo {
        let info = try await engine.preload(modelId: modelId, progress: progress)
        isReady = info.preloaded
        return info
    }

    public var isListening: Bool {
        get async { await recorder.isRecording }
    }

    /// Starts recording from the microphone.
    ///
    /// - Parameter onBuffer: Optional live 16 kHz mono Float32 audio, on a
    ///   private queue, for meters or streaming previews.
    public func start(onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) async throws {
        guard await !recorder.isRecording else { throw VoxDictationError.alreadyListening }
        _ = try await recorder.start(
            preferredInputDeviceID: preferredInputDeviceID,
            filePrefix: "vox-dictation",
            onBuffer: onBuffer
        )
    }

    /// Stops recording and returns the transcript. The recording is deleted.
    public func stop() async throws -> TranscriptionOutput {
        guard await recorder.isRecording else { throw VoxDictationError.notListening }
        let url = try await recorder.stop()
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcribe(url: url, route: Self.dictationRoute)
    }

    /// Stops recording and discards the audio.
    public func cancel() async {
        await recorder.cancel()
    }

    /// Microphone level from 0 to 1 while listening, for a meter.
    public func inputLevel() async -> Float? {
        await recorder.inputLevel()
    }

    /// Transcribes an existing audio file. The file is left in place.
    public func transcribe(fileURL: URL) async throws -> TranscriptionOutput {
        try await transcribe(url: fileURL, route: Self.fileRoute)
    }

    private func transcribe(url: URL, route: String) async throws -> TranscriptionOutput {
        do {
            let output = try await engine.transcribe(url: url, modelId: modelId)
            isReady = true
            await performance?.record(PerformanceSample(
                clientId: clientId,
                route: route,
                modelId: output.modelId,
                outcome: "ok",
                textLength: output.text.count,
                metrics: output.metrics.performanceMetrics
            ))
            return output
        } catch {
            await performance?.record(PerformanceSample(
                clientId: clientId,
                route: route,
                modelId: modelId,
                outcome: "error",
                textLength: 0,
                error: error.localizedDescription
            ))
            throw error
        }
    }
}
