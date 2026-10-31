import Foundation
import Testing
import VoxCore
@testable import HudsonSpeechEngine

@Suite("Scoped cloud annotation", .serialized)
struct AnnotationProviderTests {
    static let scribe = Data(#"{"text":"Hello [laughter] world.","language_code":"eng","language_probability":0.98,"transcription_id":"scribe-request","words":[{"text":"Hello","type":"word","start":0.1,"end":0.4,"speaker_id":"speaker_2","logprob":-0.2},{"text":" ","type":"spacing"},{"text":"[laughter]","type":"audio_event","start":0.5,"end":0.7,"speaker_id":"speaker_2"},{"text":"world.","type":"word","start":0.8,"end":1.2,"speaker_id":"speaker_7"}]}"#.utf8)
    static let deepgram = Data(#"{"metadata":{"request_id":"dg-request","duration":2,"models":["actual-model-revision"]},"results":{"channels":[{"detected_language":"en","alternatives":[{"transcript":"Hello world.","words":[{"word":"hello","punctuated_word":"Hello","start":0.1,"end":0.4,"confidence":0.97,"speaker":0,"speaker_confidence":0.82},{"word":"world","punctuated_word":"world.","start":0.8,"end":1.2,"speaker":1}]}]}],"utterances":[{"start":0.1,"end":0.4,"speaker":0,"confidence":0.99},{"start":0.8,"end":1.2,"speaker":1}]}}"#.utf8)

    @Test func scribePreservesEvidenceWithoutInventingScores() throws {
        let parsed = try AnnotationResponseParser.parse(Self.scribe, eleven: true, diarize: true)
        #expect(parsed.words.count == 2 && parsed.events.count == 1)
        #expect(parsed.words[0].confidence == nil && parsed.words[0].logProbability == -0.2)
        #expect(parsed.words.map(\.speakerId) == ["speaker_2", "speaker_7"])
        #expect(parsed.events[0].label == "[laughter]")
        #expect(parsed.speakers[0].confidence == nil && parsed.speakerSource == "word-span-derived")
        #expect(parsed.duration == nil && parsed.requestId == "scribe-request" && parsed.modelIds.isEmpty)
        #expect(parsed.language == "eng" && parsed.languageConfidence == 0.98)
        #expect(parsed.unavailable.contains("words.logProbability"))
    }
    @Test func deepgramPreservesScoresAndSpeakerIdentity() throws {
        let parsed = try AnnotationResponseParser.parse(Self.deepgram, eleven: false, diarize: true)
        #expect(parsed.words.map(\.speakerId) == ["0", "1"])
        #expect(parsed.words[0].confidence == 0.97 && parsed.words[0].speakerConfidence == 0.82)
        #expect(parsed.words[1].confidence == nil && parsed.words[1].speakerConfidence == nil)
        #expect(parsed.speakers[0].confidence == nil, "Transcript confidence is not speaker confidence")
        #expect(parsed.speakerSource == "vendor-utterances" && parsed.duration == 2)
        #expect(parsed.modelIds == ["actual-model-revision"] && parsed.language == "en")
        #expect(parsed.events.isEmpty && parsed.languageConfidence == nil)
    }
    @Test func missingMetadataDoesNotBecomeInventedLanguageOrVendorIDs() throws {
        let parsed = try AnnotationResponseParser.parse(Data(#"{"text":"","words":[]}"#.utf8), eleven: true, diarize: true)
        #expect(parsed.duration == nil && parsed.language == nil && parsed.languageConfidence == nil)
        #expect(parsed.requestId == nil && parsed.modelIds.isEmpty && parsed.languages.isEmpty)
        #expect(parsed.unavailable.contains("language") && parsed.unavailable.contains("languageConfidence"))
    }
    @Test func malformedResponsesNeverBecomeZeroTimings() throws {
        for body in [#"{"text":"bad","words":[{"text":"bad","type":"word"}]}"#,
                     #"{"text":"bad","words":[{"text":"bad","type":"word","start":2,"end":1}]}"#,
                     #"{"text":"bad","words":[{"text":"bad","type":"surprise","start":0,"end":1}]}"#] {
            #expect(throws: RemoteAnnotationError.self) { try AnnotationResponseParser.parse(Data(body.utf8), eleven: true, diarize: true) }
        }
        let noSpeakers = try AnnotationResponseParser.parse(Self.deepgram, eleven: false, diarize: false)
        #expect(noSpeakers.words.allSatisfy { $0.speakerId == nil } && noSpeakers.speakers.isEmpty)
    }
    @Test func explicitModelOptionsAndCredentialsRequired() async throws {
        let provider = RemoteAnnotationProvider()
        let url = URL(fileURLWithPath: "/nonexistent.wav")
        let requests = [AnnotationRequest(url: url, modelId: "speaker-diarization:v1"),
            AnnotationRequest(url: url, modelId: "elevenlabs:scribe_v2"),
            AnnotationRequest(url: url, modelId: "deepgram:nova-3", providerCredentials: ["ELEVENLABS_API_KEY": "wrong-account"]),
            AnnotationRequest(url: url, modelId: "deepgram:nova-3", providerCredentials: ["DEEPGRAM_API_KEY": "test"], tagAudioEvents: true),
            AnnotationRequest(url: url, modelId: "elevenlabs:scribe_v2", providerCredentials: ["ELEVENLABS_API_KEY": "bad\r\nkey"])]
        for request in requests {
            await #expect(throws: RemoteAnnotationError.self) { try await provider.annotate(request: request) }
        }
        let models = await AnnotationManager().models()
        #expect(models.map(\.id) == ["elevenlabs:scribe_v2", "deepgram:nova-3"])
        #expect(models[0].capabilities["wordConfidence"] == false)
        #expect(models[1].capabilities["audioEvents"] == false)
        #expect(AnnotationLentCredentials.parse(from: ["credentials": ["ELEVENLABS_API_KEY": " test ", "UNKNOWN": "ignored"]]) == ["ELEVENLABS_API_KEY": "test"])
    }
    @Test func scopedHTTPUploadsAndNoCredentialReuse() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try PCMWAV.wrap(pcm: Data(repeating: 0, count: 64000), sampleRate: 16000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let configuration = AnnotationMockHTTPURLProtocol.session(body: Self.scribe, contentType: "application/json").configuration
        let provider = RemoteAnnotationProvider(configuration: configuration)
        for key in ["account-one-fixture", "account-two-fixture"] {
            let result = try await provider.annotate(request: AnnotationRequest(url: file, modelId: "elevenlabs:scribe_v2",
                providerCredentials: ["ELEVENLABS_API_KEY": key], languageCode: "eng", numSpeakers: 2))
            #expect(AnnotationMockHTTPURLProtocol.lastRequest?.value(forHTTPHeaderField: "xi-api-key") == key)
            #expect(result.duration == 2 && result.durationSource == "media-file")
            #expect(result.words.first?.confidence == nil && result.audioEvents.count == 1)
            let body = String(decoding: AnnotationMockHTTPURLProtocol.lastBody ?? Data(), as: UTF8.self)
            #expect(body.contains("scribe_v2") && body.contains("filename=\"audio.wav\""))
            #expect(!body.contains(key) && !body.contains(file.lastPathComponent))
        }
        await #expect(throws: RemoteAnnotationError.self) {
            try await provider.annotate(request: AnnotationRequest(url: file, modelId: "elevenlabs:scribe_v2"))
        }
        #expect(AnnotationMockHTTPURLProtocol.requests.count == 2)
        async let first = provider.annotate(request: AnnotationRequest(url: file, modelId: "elevenlabs:scribe_v2",
            providerCredentials: ["ELEVENLABS_API_KEY": "concurrent-one"]))
        async let second = provider.annotate(request: AnnotationRequest(url: file, modelId: "elevenlabs:scribe_v2",
            providerCredentials: ["ELEVENLABS_API_KEY": "concurrent-two"]))
        _ = try await (first, second)
        #expect(Set(AnnotationMockHTTPURLProtocol.requests.suffix(2).compactMap {
            $0.value(forHTTPHeaderField: "xi-api-key") }) == Set(["concurrent-one", "concurrent-two"]))

        _ = AnnotationMockHTTPURLProtocol.session(body: Self.deepgram, contentType: "application/json")
        let dg = try await provider.annotate(request: AnnotationRequest(url: file, modelId: "deepgram:nova-3",
            providerCredentials: ["DEEPGRAM_API_KEY": "dg-fixture"]))
        #expect(dg.durationSource == "vendor")
        #expect(AnnotationMockHTTPURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Token dg-fixture")
        #expect(AnnotationMockHTTPURLProtocol.lastRequest?.url?.query?.contains("diarize_model=v2") == true)
        #expect(AnnotationMockHTTPURLProtocol.lastBody == (try Data(contentsOf: file)))
    }
    @Test func HTTPFailuresDiscardVendorBodiesAndBoundResponse() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try PCMWAV.wrap(pcm: Data(repeating: 0, count: 32000), sampleRate: 16000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let key = "never-echo-this-fixture-key"
        for (status, body, expected) in [(401, Data(key.utf8), "HTTP 401"),
            (200, Data(repeating: 65, count: AnnotationHTTPUpload.maxResponseBytes + 1), "response_too_large"),
            (200, Data("invalid JSON".utf8), "invalid_response")] {
            let configuration = AnnotationMockHTTPURLProtocol.session(body: body, statusCode: status).configuration
            let provider = RemoteAnnotationProvider(configuration: configuration)
            do {
                _ = try await provider.annotate(request: AnnotationRequest(url: file, modelId: "elevenlabs:scribe_v2",
                    providerCredentials: ["ELEVENLABS_API_KEY": key]))
                Issue.record("Expected sanitized error")
            } catch { #expect(error.localizedDescription.contains(expected)); #expect(!error.localizedDescription.contains(key)) }
        }
    }

}
