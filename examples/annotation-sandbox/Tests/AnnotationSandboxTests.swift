import Darwin
import Foundation
import XCTest
import VoxCore
import VoxEngine

final class AnnotationSandboxTests: XCTestCase {
    private var base: URL { URL(string: FixtureEndpoint.baseURL)! }
    private var temporaryRoot: URL { FileManager.default.temporaryDirectory }
    private func provider() -> RemoteAnnotationProvider {
        RemoteAnnotationProvider(elevenLabsURL: base.appendingPathComponent("scribe"))
    }
    private func request(_ file: URL, key: String) -> AnnotationRequest {
        AnnotationRequest(url: file, modelId: "elevenlabs:scribe_v2",
            providerCredentials: ["ELEVENLABS_API_KEY": key], diarize: true, tagAudioEvents: true,
            languageCode: "eng", numSpeakers: 2)
    }
    private func annotation(_ provider: RemoteAnnotationProvider, _ request: AnnotationRequest) async throws -> AnnotationOutput {
        do { return try await provider.annotate(request: request) }
        catch {
            // No source/staging URL, request content, credential or vendor error body.
            if let posix = error as? POSIXError { XCTFail("Public provider POSIX failure errno=\(posix.code.rawValue)") }
            else if let remote = error as? RemoteAnnotationError {
                if case .httpStatus = remote {} else { XCTFail("Public provider typed remote failure: \(remote.localizedDescription)") }
            }
            throw error
        }
    }
    private func media() throws -> URL {
        let url = temporaryRoot.appendingPathComponent("private-recording-" + UUID().uuidString + ".wav")
        // 100 ms mono 16 kHz signed PCM, valid media metadata without real speech.
        var bytes = Data()
        func text(_ value: String) { bytes.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
        text("RIFF"); u32(3236); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        text("data"); u32(3200); bytes.append(Data(repeating: 0, count: 3200))
        try bytes.write(to: url)
        return url
    }
    private func stages() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("vox-annotation-") }
    }
    private func status() async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("status"))
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
    private func waitFor(_ condition: @escaping () async throws -> Bool) async throws {
        for _ in 0..<400 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for bounded loopback fixture observation")
        throw NSError(domain: "AnnotationSandboxTest", code: 1)
    }

    func testScopedAccountsAndMultipartCleanup() async throws {
        let provider = provider(), file = try media(), before = try stages().count
        defer { try? FileManager.default.removeItem(at: file) }
        for key in ["fixture-one", "fixture-two"] {
            let output = try await annotation(provider, request(file, key: key))
            XCTAssertEqual(output.words.count, 2)
            XCTAssertEqual(output.words.first?.speakerId, "speaker_0")
            XCTAssertNil(output.words.first?.confidence)
            XCTAssertEqual(output.words.first?.logProbability, -0.2)
            XCTAssertEqual(output.audioEvents.count, 1)
        }
        XCTAssertEqual(try stages().count, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let state = try await status()
        XCTAssertEqual(state["scoped"], 2)
    }

    func testCancellationOnlyClosesOwnedUploadAndPreservesPrivateModes() async throws {
        let provider = provider(), file = try media(), before = try stages().count
        defer { try? FileManager.default.removeItem(at: file) }
        let first = Task { try await provider.annotate(request: request(file, key: "fixture-hold-a")) }
        let second = Task { try await provider.annotate(request: request(file, key: "fixture-hold-b")) }
        defer { first.cancel(); second.cancel() }
        try await waitFor { let state = try await self.status(); return state["started"] == 2 }
        XCTAssertEqual(try stages().count, before + 2)
        for directory in try stages() {
            let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            let fileMode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("upload.bin").path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(directoryMode?.intValue, 0o700)
            XCTAssertEqual(fileMode?.intValue, 0o600)
        }
        first.cancel()
        do { _ = try await first.value; XCTFail("Expected own upload cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error type"); throw error }
        try await waitFor { try await self.status()["closedA"] == 1 }
        _ = try await URLSession.shared.data(from: base.appendingPathComponent("release"))
        _ = try await second.value
        XCTAssertEqual(try stages().count, before)
        let state = try await status()
        XCTAssertEqual(state["closedB"], 0)
    }

    func testReflected401IsTypedAndStagingIsRemoved() async throws {
        let provider = provider(), file = try media(), before = try stages().count
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            _ = try await annotation(provider, request(file, key: "fixture-reflect"))
            XCTFail("Expected HTTP 401")
        } catch {
            guard case .httpStatus(401)? = error as? RemoteAnnotationError else {
                XCTFail("Expected status-only RemoteAnnotationError.httpStatus(401)"); throw error
            }
            XCTAssertFalse(error.localizedDescription.contains("fixture-reflect"))
        }
        XCTAssertEqual(try stages().count, before)
    }

    func testOversizeRejectedBeforeHTTPOrStaging() async throws {
        let provider = provider(), file = try media(), before = try stages().count
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 2_000_000_001); try handle.close()
        do { _ = try await provider.annotate(request: request(file, key: "fixture-oversize")); XCTFail("Expected bounded-file rejection") }
        catch { guard case .invalidFile? = error as? RemoteAnnotationError else { throw error } }
        XCTAssertEqual(try stages().count, before)
        let state = try await status()
        XCTAssertEqual(state["oversize"], 0)
    }
}
