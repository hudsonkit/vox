import AVFoundation
import Darwin
import Foundation
import VoxCore

struct AnnotationUploadFile: Sendable {
    static let maxInputBytes = 2_000_000_000
    let url: URL
    private let staging: AnnotationStagingFile
    var directory: URL { staging.directory }
    let inputBytes: Int
    let duration: Double?
    let fileCheckMs: Int
    let audioLoadMs: Int
    let audioPrepareMs: Int
    func remove() { staging.remove() }

    private final class Cancellation: @unchecked Sendable {
        let lock = NSLock(); var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
    }
    private static let queue = DispatchQueue(label: "cc.voxd.annotation-file", attributes: .concurrent)
    private static let mimeTypes = ["wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/mp4", "mp4": "video/mp4",
        "flac": "audio/flac", "ogg": "audio/ogg", "opus": "audio/ogg", "webm": "audio/webm", "aac": "audio/aac",
        "aif": "audio/aiff", "aiff": "audio/aiff", "mov": "video/quicktime", "mkv": "video/x-matroska"]
    static func mimeType(_ url: URL) throws -> String {
        guard url.isFileURL, let type = mimeTypes[url.pathExtension.lowercased()] else { throw RemoteAnnotationError.unsupportedContainer }
        return type
    }
    static func prepare(source: URL, fields: [(String, String)]?, boundary: String) async throws -> Self {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try build(source: source, fields: fields, boundary: boundary, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }
    private static func build(source: URL, fields: [(String, String)]?, boundary: String, cancellation: Cancellation) throws -> Self {
        try cancellation.check()
        let checkStart = Date()
        _ = try mimeType(source)
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw RemoteAnnotationError.invalidFile }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
              info.st_size <= maxInputBytes else { throw RemoteAnnotationError.invalidFile }
        let fileCheckMs = Int(Date().timeIntervalSince(checkStart) * 1000)
        let loadStart = Date()
        let duration: Double? = autoreleasepool {
            guard let file = try? AVAudioFile(forReading: source) else { return nil }
            let value = Double(file.length) / file.fileFormat.sampleRate
            return value.isFinite && value >= 0 ? value : nil
        }
        let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
        let prepareStart = Date()
        let staging = try AnnotationStagingFile.create()
        var keep = false
        defer { if !keep { staging.remove() } }
        let outputFD = try staging.openOutput()
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        if let fields {
            for (name, value) in fields {
                try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
            }
            let mime = try mimeType(source)
            let filename = "audio." + source.pathExtension.lowercased()
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        }
        var copied = 0
        while true {
            try cancellation.check()
            guard let data = try input.read(upToCount: 65536), !data.isEmpty else { break }
            copied += data.count
            guard copied <= maxInputBytes else { throw RemoteAnnotationError.invalidFile }
            try output.write(contentsOf: data)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, copied == info.st_size, after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { throw RemoteAnnotationError.fileChanged }
        if fields != nil { try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8)) }
        try cancellation.check()
        keep = true
        return Self(url: staging.url, staging: staging, inputBytes: copied, duration: duration,
                    fileCheckMs: fileCheckMs, audioLoadMs: loadMs, audioPrepareMs: Int(Date().timeIntervalSince(prepareStart) * 1000))
    }
}
