import AVFoundation
import Foundation

public struct AudioInputDeviceInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isSystemDefault: Bool

    public init(id: String, name: String, isSystemDefault: Bool) {
        self.id = id
        self.name = name
        self.isSystemDefault = isSystemDefault
    }
}

public enum AudioInputDevices {
    public static func available() -> [AudioInputDeviceInfo] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return discoveredDevices()
            .map { device in
                AudioInputDeviceInfo(
                    id: device.uniqueID,
                    name: device.localizedName,
                    isSystemDefault: device.uniqueID == defaultID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isSystemDefault != rhs.isSystemDefault {
                    return lhs.isSystemDefault && !rhs.isSystemDefault
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public static func effectiveLabel(preferredID: String?) -> String {
        let devices = available()
        let preferredID = preferredID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let device = devices.first(where: { $0.id == preferredID }) {
            return device.name
        }
        if let device = devices.first(where: \.isSystemDefault) {
            return "System default · \(device.name)"
        }
        return "System default"
    }

    static func resolve(preferredID: String?) throws -> (device: AVCaptureDevice, info: AudioInputDeviceInfo) {
        let devices = discoveredDevices()
        let preferredID = preferredID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let device: AVCaptureDevice?

        if !preferredID.isEmpty,
           let preferred = devices.first(where: { $0.uniqueID == preferredID }) {
            device = preferred
        } else {
            device = AVCaptureDevice.default(for: .audio) ?? devices.first
        }

        guard let device else {
            throw MicrophoneCaptureError.noInputDevice
        }

        return (
            device,
            AudioInputDeviceInfo(
                id: device.uniqueID,
                name: device.localizedName,
                isSystemDefault: device.uniqueID == AVCaptureDevice.default(for: .audio)?.uniqueID
            )
        )
    }

    private static func discoveredDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}

public struct MicrophoneRecording: Sendable {
    public let url: URL
    public let inputDevice: AudioInputDeviceInfo

    public init(url: URL, inputDevice: AudioInputDeviceInfo) {
        self.url = url
        self.inputDevice = inputDevice
    }
}

public enum MicrophoneCaptureError: LocalizedError, Sendable {
    case alreadyRecording
    case noActiveRecording
    case noInputDevice
    case unableToUseInputDevice(String)
    case unableToCreateOutput
    case permissionDenied
    case permissionUnavailable

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress."
        case .noActiveRecording:
            return "No recording is active."
        case .noInputDevice:
            return "No microphone input device is available."
        case .unableToUseInputDevice(let name):
            return "Unable to use input device \(name)."
        case .unableToCreateOutput:
            return "Unable to create microphone recording output."
        case .permissionDenied:
            return "Microphone access is not allowed."
        case .permissionUnavailable:
            return "Microphone access is unavailable."
        }
    }
}

#if os(macOS)
public actor MicrophoneFileRecorder {
    private let log = VoxLog.audio

    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var sink: MicrophoneSampleSink?
    private var currentURL: URL?

    public init() {}

    public var isRecording: Bool {
        session != nil
    }

    /// Starts recording to a temporary 16 kHz mono WAV file.
    ///
    /// Vox writes the file itself from one capture stream, already converted
    /// to 16 kHz mono, so the file's header always describes its samples.
    /// `AVCaptureAudioFileOutput` occasionally labelled 16 kHz mono data as
    /// the device's 48 kHz stereo, which made a whole take unreadable.
    ///
    /// - Parameter onBuffer: Optional live tap. Receives the same audio as
    ///   16 kHz mono Float32 PCM while the file records, on a private queue,
    ///   for streaming previews and meters. The file is still the source of truth.
    public func start(
        preferredInputDeviceID: String? = nil,
        filePrefix: String = "vox",
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) async throws -> MicrophoneRecording {
        guard session == nil else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        try await ensureMicrophoneAccess()

        guard session == nil else {
            throw MicrophoneCaptureError.alreadyRecording
        }

        let resolved = try AudioInputDevices.resolve(preferredID: preferredInputDeviceID)
        let input = try AVCaptureDeviceInput(device: resolved.device)
        let output = AVCaptureAudioDataOutput()
        let session = AVCaptureSession()

        let prefix = normalizedFilePrefix(filePrefix)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: Self.speechWAVSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
        } catch {
            log.error("Unable to create recording file: \(error.localizedDescription)")
            throw MicrophoneCaptureError.unableToCreateOutput
        }
        let sink = MicrophoneSampleSink(file: file, log: log, handler: onBuffer)

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MicrophoneCaptureError.unableToUseInputDevice(resolved.info.name)
        }
        session.addInput(input)

        output.audioSettings = Self.liveBufferSettings
        output.setSampleBufferDelegate(sink, queue: sink.queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneCaptureError.unableToCreateOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()

        self.session = session
        self.output = output
        self.sink = sink
        self.currentURL = url
        log.info("Recording started with \(resolved.info.name): \(url.lastPathComponent)")
        return MicrophoneRecording(url: url, inputDevice: resolved.info)
    }

    public func stop() async throws -> URL {
        guard let session, let sink, let currentURL else {
            throw MicrophoneCaptureError.noActiveRecording
        }
        defer {
            self.session = nil
            self.output = nil
            self.sink = nil
            self.currentURL = nil
        }

        session.stopRunning()
        let frames = sink.finish()
        log.info("Recording stopped: \(currentURL.lastPathComponent), \(frames) frames")
        return currentURL
    }

    /// Current input loudness, 0 (silence) to 1, for level meters.
    /// Nil when no recording is active.
    public func inputLevel() -> Float? {
        guard let output else { return nil }
        let channels = output.connections.flatMap(\.audioChannels)
        guard !channels.isEmpty else { return nil }
        let decibels = channels.map(\.averagePowerLevel).max() ?? -160
        return max(0, min(1, (decibels + 50) / 50))
    }

    public func cancel() {
        let current = currentURL
        session?.stopRunning()
        sink?.finish()
        session = nil
        output = nil
        sink = nil
        currentURL = nil
        if let current {
            try? FileManager.default.removeItem(at: current)
            log.warning("Recording cancelled: \(current.lastPathComponent)")
        }
    }

    static func isRecoverableStopError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == AVFoundationErrorDomain
            || error.localizedDescription == "Recording Stopped"
    }

    private func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) {
                return
            }
            throw MicrophoneCaptureError.permissionDenied
        case .denied, .restricted:
            throw MicrophoneCaptureError.permissionDenied
        @unknown default:
            throw MicrophoneCaptureError.permissionUnavailable
        }
    }

    /// The file on disk: 16 kHz mono 16-bit PCM.
    static var speechWAVSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ] }

    /// The capture stream: 16 kHz mono Float32, converted by AVFoundation
    /// from whatever the device delivers.
    static var liveBufferSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ] }

    private func normalizedFilePrefix(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        return normalized.isEmpty ? "vox" : normalized
    }
}

/// Receives the capture stream, appends it to the recording file, and hands
/// the same buffers to an optional live consumer. Everything runs on `queue`.
private final class MicrophoneSampleSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "vox.microphone.capture", qos: .userInitiated)
    private var file: AVAudioFile?
    private let log: DualLogger
    private let handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var frames: AVAudioFramePosition = 0
    private var reportedWriteError = false

    init(file: AVAudioFile, log: DualLogger, handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        self.file = file
        self.log = log
        self.handler = handler
    }

    /// Closes the file once every buffer already delivered has been written.
    /// Call after the session stops running. Returns the frames written.
    @discardableResult
    func finish() -> AVAudioFramePosition {
        queue.sync {
            // Releasing the last reference also finalizes the header on macOS 14.
            if #available(macOS 15.0, *) { file?.close() }
            file = nil
            return frames
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = AVAudioFrameCount(sampleBuffer.numSamples)
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        buffer.frameLength = count
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(count),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return }

        if let file {
            do {
                try file.write(from: buffer)
                frames += AVAudioFramePosition(count)
            } catch where !reportedWriteError {
                reportedWriteError = true
                log.error("Recording write failed (\(format) into \(file.processingFormat)): \(error.localizedDescription)")
            } catch {}
        }
        handler?(buffer)
    }
}
#else
/// The companion recorder uses `AVCaptureSession` audio capture, which Apple
/// only exposes this way on macOS. iOS clients compile the shared runtime types but provide
/// capture through their app layer (for example HudsonVoice's AVAudioEngine
/// recorder) or a paired Mac runtime.
public actor MicrophoneFileRecorder {
    public init() {}

    public var isRecording: Bool { false }

    public func start(
        preferredInputDeviceID: String? = nil,
        filePrefix: String = "vox",
        onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil
    ) async throws -> MicrophoneRecording {
        throw MicrophoneCaptureError.permissionUnavailable
    }

    public func stop() async throws -> URL {
        throw MicrophoneCaptureError.noActiveRecording
    }

    public func inputLevel() -> Float? { nil }

    public func cancel() {}

    static func isRecoverableStopError(_ error: Error) -> Bool {
        false
    }
}
#endif
