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
    private var output: AVCaptureAudioFileOutput?
    private var recordingDelegate: MicrophoneFileRecordingDelegate?
    private var currentURL: URL?

    public init() {}

    public var isRecording: Bool {
        session != nil
    }

    public func start(
        preferredInputDeviceID: String? = nil,
        filePrefix: String = "vox"
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
        let output = AVCaptureAudioFileOutput()
        let session = AVCaptureSession()

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MicrophoneCaptureError.unableToUseInputDevice(resolved.info.name)
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MicrophoneCaptureError.unableToCreateOutput
        }
        session.addOutput(output)
        session.commitConfiguration()

        let fileType = preferredOutputFileType(for: output)
        // Pin the file format. Left unset, the writer adopts the first buffer's
        // format and stops ("Recording Stopped") if the device stream later
        // switches format, leaving a fraction of a second of audio.
        if fileType == .wav {
            output.audioSettings = Self.speechWAVSettings
        }
        let prefix = normalizedFilePrefix(filePrefix)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension(for: fileType))
        let delegate = MicrophoneFileRecordingDelegate()

        session.startRunning()
        output.startRecording(to: url, outputFileType: fileType, recordingDelegate: delegate)

        self.session = session
        self.output = output
        self.recordingDelegate = delegate
        self.currentURL = url
        log.info("Recording started with \(resolved.info.name): \(url.lastPathComponent)")
        return MicrophoneRecording(url: url, inputDevice: resolved.info)
    }

    public func stop() async throws -> URL {
        guard let session, let output, let recordingDelegate, let currentURL else {
            throw MicrophoneCaptureError.noActiveRecording
        }

        output.stopRecording()
        defer {
            session.stopRunning()
            self.session = nil
            self.output = nil
            self.recordingDelegate = nil
            self.currentURL = nil
        }

        do {
            let finishedURL = try await recordingDelegate.waitForFinish()
            log.info("Recording stopped: \(currentURL.lastPathComponent)")
            return finishedURL
        } catch {
            if Self.isRecoverableStopError(error) {
                if await waitForOutputFile(at: currentURL) {
                    log.warning("Recording stop reported \(error.localizedDescription); using completed file \(currentURL.lastPathComponent)")
                    return currentURL
                }
                log.warning("Recording stop reported \(error.localizedDescription), but no output file was finalized for \(currentURL.lastPathComponent)")
            }
            log.error("Recording stop failed for \(currentURL.lastPathComponent): \(error.localizedDescription)")
            throw error
        }
    }

    public func cancel() {
        let current = currentURL
        output?.stopRecording()
        session?.stopRunning()
        session = nil
        output = nil
        recordingDelegate = nil
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

    static var speechWAVSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ] }

    private func preferredOutputFileType(for output: AVCaptureAudioFileOutput) -> AVFileType {
        let fileTypes = AVCaptureAudioFileOutput.availableOutputFileTypes()
        if fileTypes.contains(.wav) {
            return .wav
        }
        if fileTypes.contains(.m4a) {
            return .m4a
        }
        return fileTypes.first ?? .wav
    }

    private func fileExtension(for fileType: AVFileType) -> String {
        switch fileType {
        case .wav:
            return "wav"
        case .m4a:
            return "m4a"
        case .aiff:
            return "aiff"
        default:
            return "caf"
        }
    }

    private func normalizedFilePrefix(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        return normalized.isEmpty ? "vox" : normalized
    }

    private func waitForOutputFile(at url: URL, attempts: Int = 5) async -> Bool {
        for attempt in 0..<attempts {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return false
    }
}

private final class MicrophoneFileRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    func waitForFinish() async throws -> URL {
        if let result = existingResult() {
            return try result.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let result: Result<URL, Error> = if let error {
            .failure(error)
        } else {
            .success(outputFileURL)
        }

        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.result = result
            lock.unlock()
        }
    }

    private func existingResult() -> Result<URL, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
#else
/// The companion recorder uses `AVCaptureAudioFileOutput`, which Apple only
/// exposes on macOS. iOS clients compile the shared runtime types but provide
/// capture through their app layer (for example HudsonVoice's AVAudioEngine
/// recorder) or a paired Mac runtime.
public actor MicrophoneFileRecorder {
    public init() {}

    public var isRecording: Bool { false }

    public func start(
        preferredInputDeviceID: String? = nil,
        filePrefix: String = "vox"
    ) async throws -> MicrophoneRecording {
        throw MicrophoneCaptureError.permissionUnavailable
    }

    public func stop() async throws -> URL {
        throw MicrophoneCaptureError.noActiveRecording
    }

    public func cancel() {}

    static func isRecoverableStopError(_ error: Error) -> Bool {
        false
    }
}
#endif
