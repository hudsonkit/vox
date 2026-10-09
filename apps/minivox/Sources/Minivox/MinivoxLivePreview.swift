@preconcurrency import AVFoundation
import Foundation
import OSLog
import Speech

/// Streams words into the notch while the user speaks, using Apple's
/// on-device SpeechTranscriber with volatile results. Display only: the text
/// that gets pasted still comes from the configured model reading the file.
actor MinivoxLivePreview {
    private let log = Logger(subsystem: "cc.voxd.minivox", category: "preview")
    private var locale: Locale?
    private var analyzerFormat: AVAudioFormat?
    private var isInstallingAssets = false

    private var analyzer: SpeechAnalyzer?
    private var feed: MinivoxPreviewFeed?
    private var resultsTask: Task<Void, Never>?

    /// Checks the locale, installs or reserves the speech assets, and readies the analyzer format so a session starts fast.
    /// Returns whether a preview can run right now.
    @discardableResult
    func warmUp() async -> Bool {
        if locale != nil, analyzerFormat != nil { return true }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            log.notice("Live preview unavailable for \(Locale.current.identifier, privacy: .public)")
            return false
        }

        let transcriber = Self.makeTranscriber(locale: locale)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            break
        case .supported, .downloading:
            // Assets already on disk still need reserving for this app, which
            // is quick; a real download can take a while. Warm-up runs at
            // launch off the recording path, so it waits either way.
            guard !isInstallingAssets else { return false }
            isInstallingAssets = true
            defer { isInstallingAssets = false }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                log.error("Live preview assets failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                log.notice("Live preview assets not installed yet")
                return false
            }
        default:
            log.notice("Live preview unsupported for \(locale.identifier, privacy: .public)")
            return false
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return false
        }
        self.locale = locale
        analyzerFormat = format
        log.notice("Live preview ready: \(locale.identifier, privacy: .public), \(format.description, privacy: .public)")
        return true
    }

    /// Opens a session. Feed microphone buffers to the returned handler;
    /// `onText` receives the running transcript on the main actor. Returns at
    /// once: buffers queue until the analyzer is up, so recording never waits.
    /// Nil when the preview is not warmed up yet.
    func begin(onText: @escaping @MainActor @Sendable (String) -> Void) async -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        await end()
        guard let locale, let format = analyzerFormat else {
            log.notice("Live preview skipped: not warmed up")
            Task { await self.warmUp() }
            return nil
        }

        // A transcriber serves one analyzer, so each session gets a fresh one.
        let transcriber = Self.makeTranscriber(locale: locale)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let feed = MinivoxPreviewFeed(target: format, continuation: continuation)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        log.notice("Live preview session started")
        resultsTask = Task {
            var settled = ""
            var count = 0
            do {
                for try await result in transcriber.results {
                    count += 1
                    if count == 1 { self.log.notice("Live preview first result") }
                    let text = String(result.text.characters)
                    let running: String
                    if result.isFinal {
                        settled = Self.join(settled, text)
                        running = settled
                    } else {
                        running = Self.join(settled, text)
                    }
                    await onText(running)
                }
                self.log.notice("Live preview results ended after \(count) updates")
            } catch {
                self.log.error("Live preview results failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Task {
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                self.log.error("Live preview analyzer failed: \(error.localizedDescription, privacy: .public)")
                feed.finish()
            }
        }

        self.analyzer = analyzer
        self.feed = feed
        return { buffer in feed.append(buffer) }
    }

    /// Closes the session without waiting for the last words to settle.
    func end() async {
        feed?.finish()
        feed = nil
        if let analyzer {
            await analyzer.cancelAndFinishNow()
        }
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    private static func join(_ settled: String, _ next: String) -> String {
        let next = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settled.isEmpty else { return next }
        guard !next.isEmpty else { return settled }
        return settled + " " + next
    }
}

/// Converts capture buffers to the analyzer's format. Called serially from
/// the recorder's capture queue.
private final class MinivoxPreviewFeed: @unchecked Sendable {
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var isFinished = false

    init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.target = target
        self.continuation = continuation
    }

    private var loggedFirst = false
    /// Running peak of the input, for the preview's automatic gain.
    private var level: Float = 0

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        let boosted = normalized(buffer)
        let converted = convert(boosted)
        if !loggedFirst {
            loggedFirst = true
            Logger(subsystem: "cc.voxd.minivox", category: "preview")
                .notice("Live preview first buffer: \(buffer.format.description, privacy: .public) converted=\(converted != nil)")
        }
        guard let converted else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// Mics like AirPods can deliver speech near -40 dBFS, too quiet for the
    /// transcriber to hear. Boosts the preview copy toward a steady level;
    /// the recording that gets pasted is untouched.
    private func normalized(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let samples = buffer.floatChannelData, buffer.format.channelCount == 1,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let output = copy.floatChannelData else { return buffer }
        let count = Int(buffer.frameLength)
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(samples[0][i])) }
        // Fast attack, slow release, with a floor so silence is not blown up.
        level = peak > level ? peak : max(peak, level * 0.995)
        let gain = min(Self.maxGain, Self.target / max(level, Self.floor))
        for i in 0..<count { output[0][i] = max(-1, min(1, samples[0][i] * gain)) }
        copy.frameLength = buffer.frameLength
        return copy
    }

    private static let target: Float = 0.5
    private static let maxGain: Float = 40
    private static let floor: Float = 0.004

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        isFinished = true
        continuation.finish()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
