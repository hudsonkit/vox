import Foundation
import VoxClient

let a = VoxDaemonClient(clientId: "tts-fixture-client-a")
let b = VoxDaemonClient(clientId: "tts-fixture-client-b")
try await a.connectDiscovered(); try await b.connectDiscovered()
let endpoint = URL(string: ProcessInfo.processInfo.environment["TTS_FIXTURE_URL"]!)!
func params(_ key: String?, openAI: Bool = false, text: String = "fixture-fast") -> [String: JSONValue] {
    var result: [String: JSONValue] = ["modelId": .string(openAI ? "gpt-4o-mini-tts" : "eleven_flash_v2_5"),
        "voiceId": .string(openAI ? "alloy" : (key == "tts-loan-b" ? "fixture-b" : "fixture-a")),
        "text": .string(text), "format": "wav"]
    if let key { result["credentials"] = .object([openAI ? "OPENAI_API_KEY" : "ELEVENLABS_API_KEY": .string(key)]) }
    return result
}
func valid(_ result: JSONValue) -> Bool {
    guard let encoded = result["audioBase64"]?.stringValue, let data = Data(base64Encoded: encoded) else { return false }
    return data.count > 44 && data.prefix(4) == Data("RIFF".utf8)
}
func state() async throws -> [String: Bool] {
    let (data, _) = try await URLSession.shared.data(from: endpoint.appendingPathComponent("state"))
    return try JSONDecoder().decode([String: Bool].self, from: data)
}
func waitFor(_ predicate: @Sendable ([String: Bool]) -> Bool) async throws {
    for _ in 0..<250 {
        if predicate(try await state()) { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    fatalError("Timed out waiting for loopback HTTP evidence")
}
for (client, key, voice) in [(a, "tts-loan-a", "fixture-a"), (b, "tts-loan-b", "fixture-b")] {
    let result = try await client.call("synthesize.voices", params: ["modelId": "eleven_flash_v2_5",
        "credentials": .object(["ELEVENLABS_API_KEY": .string(key)])])
    guard case .array(let voices) = result["voices"] else { fatalError("Missing voices") }
    precondition(voices.first?["id"]?.stringValue == voice)
}
let generatedA = try await a.call("synthesize.generate", params: params("tts-loan-a"))
precondition(valid(generatedA))
let generatedB = try await b.call("synthesize.generate", params: params("tts-loan-b", openAI: true))
precondition(valid(generatedB))
for openAI in [true, false] {
    do {
        _ = try await a.call("synthesize.generate", params: params("tts-loan-rejected", openAI: openAI))
        fatalError("Expected HTTP rejection")
    } catch {
        precondition(error.localizedDescription.contains("HTTP 401"))
        precondition(!error.localizedDescription.contains("tts-loan-rejected") && !error.localizedDescription.contains("fixture-fast"))
    }
}
do { _ = try await a.call("synthesize.generate", params: params(nil, openAI: true)); fatalError("Borrowed key retained") }
catch { precondition(error.localizedDescription.contains("Missing OPENAI_API_KEY")) }
let slowA = Task { try await a.call("synthesize.generate", params: params("tts-loan-a", text: "fixture-slow-a")) }
let slowB = Task { try await b.call("synthesize.generate", params: params("tts-loan-b", text: "fixture-slow-b")) }
try await waitFor { $0["aStarted"] == true && $0["bStarted"] == true }
let start = ContinuousClock.now
slowA.cancel()
do { _ = try await slowA.value; fatalError("Expected cancellation") } catch {}
let cancel = start.duration(to: .now)
try await waitFor { $0["aClosed"] == true }
let closed = start.duration(to: .now)
var release = URLRequest(url: endpoint.appendingPathComponent("release")); release.httpMethod = "POST"
_ = try await URLSession.shared.data(for: release)
let survived = try await slowB.value
precondition(valid(survived))
let subsequent = try await b.call("synthesize.generate", params: params("tts-loan-b"))
precondition(valid(subsequent))
let stillConnected = await b.isConnected
precondition(stillConnected)
await b.disconnect()
func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}
let output = ["clientCancelMs": milliseconds(cancel), "cancelToHTTPPeerCloseMs": milliseconds(closed)]
print(String(decoding: try JSONEncoder().encode(output), as: UTF8.self))
