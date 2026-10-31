import Foundation
import VoxClient

let a = VoxDaemonClient(clientId: "annotation-fixture-a")
let b = VoxDaemonClient(clientId: "annotation-fixture-b")
try await a.connectDiscovered()
try await b.connectDiscovered()
let models = try await a.listAnnotationModels()
precondition(models.map(\.id) == ["elevenlabs:scribe_v2", "deepgram:nova-3"])
precondition(models[1].capabilities["audioEvents"] == false)
let path = CommandLine.arguments[1]
async let sr = a.annotateFile(path: path, modelId: "elevenlabs:scribe_v2",
    credentials: ["ELEVENLABS_API_KEY": "fixture-eleven-a"], languageCode: "eng", numSpeakers: 2)
async let dr = b.annotateFile(path: path, modelId: "deepgram:nova-3",
    credentials: ["DEEPGRAM_API_KEY": "fixture-deepgram-b"])
let (s, d) = try await (sr, dr)
precondition(s.words.count == 2 && s.words[0].confidence == nil && s.words[0].logProbability == -0.2)
precondition(s.audioEvents.count == 1 && s.audioEvents[0].label == "[laughter]")
precondition(s.words.map(\.speakerId) == ["speaker_2", "speaker_7"])
precondition(s.duration == 2 && s.durationSource == "media-file" && s.language == "eng")
precondition(s.providerRequestId == "scribe-request" && s.providerModelIds.isEmpty)
precondition(d.words.map(\.speakerId) == ["0", "1"] && d.words[0].confidence == 0.97)
precondition(d.words[1].confidence == nil && d.speakers[0].confidence == nil)
precondition(d.durationSource == "vendor" && d.providerModelIds == ["actual-model-revision"])
precondition(d.unsupportedFields.contains("audioEvents"))
precondition(d.languages == ["en"] && d.words[0].language == "en")
for key in ["fixture-eleven-c", "fixture-eleven-d"] {
    _ = try await a.annotateFile(path: path, modelId: "elevenlabs:scribe_v2", credentials: ["ELEVENLABS_API_KEY": key])
}
do {
    _ = try await a.annotateFile(path: path, modelId: "elevenlabs:scribe_v2", credentials: ["ELEVENLABS_API_KEY": "fixture-rejected"])
    fatalError("rejected key accepted")
} catch { precondition(error.localizedDescription.contains("HTTP 401") && !error.localizedDescription.contains("fixture-rejected")) }
do {
    _ = try await a.annotateFile(path: path, modelId: "elevenlabs:scribe_v2", credentials: [:])
    fatalError("borrowed key retained")
} catch { precondition(error.localizedDescription.contains("credentials_required")) }
do {
    _ = try await a.annotateFile(path: path, modelId: "deepgram:nova-3", credentials: ["DEEPGRAM_API_KEY": "fixture-deepgram-b"], tagAudioEvents: true)
    fatalError("unsupported event option accepted")
} catch { precondition(error.localizedDescription.contains("unsupported_options")) }
let cancelled = Task {
    try await a.annotateFile(path: path, modelId: "elevenlabs:scribe_v2", credentials: ["ELEVENLABS_API_KEY": "fixture-slow"])
}
try await Task.sleep(for: .milliseconds(400))
cancelled.cancel()
do { _ = try await cancelled.value; fatalError("cancel failed") } catch {}
// The other authenticated connection must still work after A disconnects.
_ = try await b.annotateFile(path: path, modelId: "deepgram:nova-3", credentials: ["DEEPGRAM_API_KEY": "fixture-deepgram-b"])
await b.disconnect()
print("PASS: two private clients, both vendors, scoped keys, provenance/nulls/events, sanitized errors, unsupported options, disconnect cancellation")
