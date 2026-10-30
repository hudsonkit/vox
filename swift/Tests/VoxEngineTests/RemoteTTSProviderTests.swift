import Foundation
import Testing
import VoxCore
@testable import HudsonSpeechEngine

@Suite("Remote TTS providers", .serialized)
struct RemoteTTSProviderTests {
    @Test("ElevenLabs request credentials win and explicit provider env fences ambient keys")
    func elevenCredentialPrecedenceAndIsolation() async throws {
        #expect(ElevenLabsTTSProvider.resolveAPIKey(providerCredentials: ["ELEVENLABS_API_KEY": " lent "],
            env: ["ELEVENLABS_API_KEY": "configured"], processEnv: ["ELEVENLABS_API_KEY": "ambient"]) == "lent")
        #expect(ElevenLabsTTSProvider.resolveAPIKey(providerCredentials: ["elevenlabs_api_key": " alias "],
            env: ["ELEVENLABS_API_KEY": ""], processEnv: ["ELEVENLABS_API_KEY": "ambient"]) == "alias")
        #expect(ElevenLabsTTSProvider.resolveAPIKey(providerCredentials: [:],
            env: ["ELEVENLABS_API_KEY": " "], processEnv: ["ELEVENLABS_API_KEY": "ambient"]) == nil)
        #expect(ElevenLabsTTSProvider.resolveAPIKey(providerCredentials: [:],
            env: [:], processEnv: ["ELEVENLABS_API_KEY": " ambient "]) == "ambient")
        let session = MockHTTPURLProtocol.session(body: try validWAV())
        let provider = ElevenLabsTTSProvider(env: ["ELEVENLABS_API_KEY": ""], session: session)
        for key in ["account-one-test-key", "account-two-test-key"] {
            _ = try await provider.synthesize(SynthesisRequest(text: "Hello", modelId: "eleven_flash_v2_5",
                voiceId: "selected-voice", speed: 1.1, providerCredentials: ["ELEVENLABS_API_KEY": key]))
            #expect(MockHTTPURLProtocol.lastRequest?.value(forHTTPHeaderField: "xi-api-key") == key)
            #expect(MockHTTPURLProtocol.lastRequest?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
            #expect(MockHTTPURLProtocol.lastRequest?.url?.path == "/v1/text-to-speech/selected-voice")
            let query = URLComponents(url: try #require(MockHTTPURLProtocol.lastRequest?.url), resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "output_format" })?.value == "wav_44100")
        }
        await #expect(throws: ElevenLabsTTSProviderError.self) {
            try await provider.synthesize(SynthesisRequest(text: "No borrowed key", modelId: "eleven_flash_v2_5"))
        }
        #expect(MockHTTPURLProtocol.requests.count == 2, "A borrowed key must not authorize a later request")
        #expect(await provider.models().allSatisfy { !$0.available })
    }

    @Test("ElevenLabs scoped keys never overwrite configured credentials")
    func elevenScopedKeyDoesNotReplaceConfiguredKey() async throws {
        let session = MockHTTPURLProtocol.session(body: try validWAV())
        let provider = ElevenLabsTTSProvider(env: ["ELEVENLABS_API_KEY": "configured-test-key"], session: session)
        for credentials in [[:], ["elevenlabsApiKey": "selected-test-key"], [:]] {
            _ = try await provider.synthesize(SynthesisRequest(text: "Hello", modelId: "eleven_multilingual_v2",
                providerCredentials: credentials))
        }
        #expect(MockHTTPURLProtocol.requests.map { $0.value(forHTTPHeaderField: "xi-api-key") } ==
                ["configured-test-key", "selected-test-key", "configured-test-key"])
        async let first = provider.synthesize(SynthesisRequest(text: "account A", modelId: "eleven_multilingual_v2",
            providerCredentials: ["ELEVENLABS_API_KEY": "account-a-test-key"]))
        async let second = provider.synthesize(SynthesisRequest(text: "account B", modelId: "eleven_multilingual_v2",
            providerCredentials: ["ELEVENLABS_API_KEY": "account-b-test-key"]))
        _ = try await (first, second)
        for (request, body) in zip(MockHTTPURLProtocol.requests.dropFirst(3), MockHTTPURLProtocol.bodies.dropFirst(3)) {
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let expected = object["text"] as? String == "account A" ? "account-a-test-key" : "account-b-test-key"
            #expect(request.value(forHTTPHeaderField: "xi-api-key") == expected)
        }
        #expect(MockHTTPURLProtocol.requests.count == 5)

    }

    @Test("ElevenLabs voice discovery authenticates the selected account and does not retain it")
    func elevenScopedVoiceDiscovery() async throws {
        let body = Data(#"{"voices":[{"voice_id":"selected-voice","name":"Selected account voice"}]}"#.utf8)
        let session = MockHTTPURLProtocol.session(body: body, contentType: "application/json")
        let provider = ElevenLabsTTSProvider(env: ["ELEVENLABS_API_KEY": ""], session: session)
        let manager = TTSEngineManager(provider: provider)
        let voices = try await manager.voices(modelId: "eleven_multilingual_v2",
            providerCredentials: ["ELEVENLABS_API_KEY": "selected-test-key"])
        #expect(voices.first?.id == "selected-voice")
        #expect(voices.first?.available == true)
        #expect(MockHTTPURLProtocol.lastRequest?.value(forHTTPHeaderField: "xi-api-key") == "selected-test-key")
        #expect(MockHTTPURLProtocol.lastRequest?.url?.path == "/v2/voices")
        let unconfigured = try await manager.voices(modelId: "eleven_multilingual_v2")
        #expect(unconfigured.allSatisfy { !$0.available })
        #expect(MockHTTPURLProtocol.requests.count == 1)
    }

    @Test("ElevenLabs errors discard echoed secrets/text, reject header injection and preserve cancellation")
    func elevenErrorsDoNotExposeCredentials() async throws {
        let key = "selected-test-secret", text = "private synthetic utterance"
        for message in ["{\"detail\":\"\(key) \(text)\"}", "echo \(key) \(text)"] {
            let provider = ElevenLabsTTSProvider(env: ["ELEVENLABS_API_KEY": ""], session:
                MockHTTPURLProtocol.session(body: Data(message.utf8), statusCode: 401))
            do {
                _ = try await provider.synthesize(SynthesisRequest(text: text, modelId: "eleven_multilingual_v2",
                    providerCredentials: ["ELEVENLABS_API_KEY": key]))
                Issue.record("Expected HTTP error")
            } catch {
                #expect(error.localizedDescription.contains("HTTP 401"))
                #expect(!error.localizedDescription.contains(key))
                #expect(!error.localizedDescription.contains(text))
            }
        }
        let invalidAudio = ElevenLabsTTSProvider(env: ["ELEVENLABS_API_KEY": ""], session:
            MockHTTPURLProtocol.session(body: Data("echo \(key) \(text)".utf8), statusCode: 200))
        do {
            _ = try await invalidAudio.synthesize(SynthesisRequest(text: text, modelId: "eleven_multilingual_v2",
                providerCredentials: ["ELEVENLABS_API_KEY": key]))
            Issue.record("Expected non-audio response rejection")
        } catch { #expect(!error.localizedDescription.contains(key)); #expect(!error.localizedDescription.contains(text)) }
        let provider = ElevenLabsTTSProvider(env: ["ELEVENLABS_API_KEY": ""], session: MockHTTPURLProtocol.session(body: try validWAV()))
        await #expect(throws: ElevenLabsTTSProviderError.self) {
            try await provider.synthesize(SynthesisRequest(text: text, modelId: "eleven_multilingual_v2",
                providerCredentials: ["ELEVENLABS_API_KEY": "bad\r\nheader"]))
        }
        #expect(MockHTTPURLProtocol.requests.isEmpty)
        await expectCancellation {
            try await ElevenLabsTTSProvider(env: ["ELEVENLABS_API_KEY": ""], session: MockHTTPURLProtocol.session(error: URLError(.cancelled)))
                .synthesize(SynthesisRequest(text: text, modelId: "eleven_multilingual_v2", providerCredentials: ["ELEVENLABS_API_KEY": key]))
        }
    }

    @Test("Scoped voice credentials require an explicitly supported provider")
    func voiceCredentialsAreNotSilentlyIgnored() async {
        let manager = TTSEngineManager(provider: AVSpeechSynthesizerProvider())
        await #expect(throws: TTSVoiceCredentialsError.self) {
            try await manager.voices(modelId: "avspeech:system", providerCredentials: ["ELEVENLABS_API_KEY": "selected-test-key"])
        }
    }

    @Test("NVIDIA prefers NV_API_KEY while accepting NVIDIA_API_KEY and per-request credentials")
    func nvidiaCredentialPrecedence() {
        #expect(NVIDIAMagpieTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["NV_API_KEY": " nv-primary ", "NVIDIA_API_KEY": "documented"],
            processEnv: ["NVIDIA_API_KEY": "process"]
        ) == "nv-primary")
        #expect(NVIDIAMagpieTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["NVIDIA_API_KEY": " documented "],
            processEnv: [:]
        ) == "documented")
        #expect(NVIDIAMagpieTTSProvider.resolveAPIKey(
            providerCredentials: ["nvidiaApiKey": " lent-key "],
            env: ["NV_API_KEY": "env-key"],
            processEnv: ["NVIDIA_API_KEY": "process"]
        ) == "lent-key")
        #expect(NVIDIAMagpieTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: nil,
            processEnv: [:]
        ) == nil)
    }

    @Test("explicit empty or whitespace NVIDIA env aliases fence process secrets")
    func nvidiaEmptyEnvFencesProcessSecrets() {
        #expect(NVIDIAMagpieTTSProvider.resolveConfiguredAPIKey(
            env: ["NV_API_KEY": ""],
            processEnv: ["NV_API_KEY": "process-secret", "NVIDIA_API_KEY": "alias-secret"]
        ) == nil)
        #expect(NVIDIAMagpieTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["NV_API_KEY": "   "],
            processEnv: ["NVIDIA_API_KEY": "process-secret"]
        ) == nil)
        #expect(NVIDIAMagpieTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["NVIDIA_API_KEY": ""],
            processEnv: ["NV_API_KEY": "process-secret"]
        ) == nil)
        #expect(NVIDIAMagpieTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: [:],
            processEnv: ["NV_API_KEY": "process-secret"]
        ) == "process-secret")
        #expect(NVIDIAMagpieTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["NVIDIA_TTS_URL": "https://example.test"],
            processEnv: ["NVIDIA_API_KEY": " process-alias "]
        ) == "process-alias")
        #expect(NVIDIAMagpieTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: nil,
            processEnv: ["NV_API_KEY": "process-secret"]
        ) == "process-secret")
        #expect(NVIDIAMagpieTTSProvider.resolveAPIKey(
            providerCredentials: ["nv_api_key": " lent "],
            env: ["NV_API_KEY": ""],
            processEnv: ["NV_API_KEY": "process-secret"]
        ) == "lent")
    }

    @Test("NVIDIA derives language and display name from Magpie voice ids")
    func nvidiaLanguageAndDisplayName() {
        #expect(NVIDIAMagpieTTSProvider.language(for: "Magpie-Multilingual.EN-US.Aria") == "en-US")
        #expect(NVIDIAMagpieTTSProvider.language(for: "Magpie-Multilingual.ES-US.Isabela.Angry") == "es-US")
        #expect(NVIDIAMagpieTTSProvider.language(for: "Magpie-Multilingual.JA-JP.Siwei") == "ja-JP")
        #expect(NVIDIAMagpieTTSProvider.language(for: "custom") == "en-US")
        #expect(NVIDIAMagpieTTSProvider.displayName(for: "Magpie-Multilingual.EN-US.Aria") == "Aria")
        #expect(NVIDIAMagpieTTSProvider.displayName(for: "Magpie-Multilingual.ES-US.Isabela.Angry") == "Isabela · Angry")
    }

    @Test("NVIDIA builds the Developer Inference multipart contract")
    func nvidiaMultipartContract() async throws {
        let pcm = Data([0x00, 0x01, 0x02, 0x03])
        let session = MockHTTPURLProtocol.session(body: pcm, contentType: "audio/l16")
        let provider = NVIDIAMagpieTTSProvider(
            env: ["NV_API_KEY": "synthetic-test-key"],
            session: session
        )

        let output = try await provider.synthesize(SynthesisRequest(
            text: "Scout here.",
            modelId: NVIDIAMagpieTTSProvider.modelID
        ))
        let request = try #require(MockHTTPURLProtocol.lastRequest)
        let body = try #require(MockHTTPURLProtocol.lastBody.flatMap { String(data: $0, encoding: .utf8) })

        #expect(request.url?.host?.hasSuffix("invocation.api.nvcf.nvidia.com") == true)
        #expect(request.url?.path == "/v1/audio/synthesize")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-key")
        #expect(body.contains("name=\"text\"\r\n\r\nScout here."))
        #expect(body.contains("name=\"language\"\r\n\r\nen-US"))
        #expect(body.contains("name=\"voice\"\r\n\r\n\(NVIDIAMagpieTTSProvider.defaultVoiceID)"))
        #expect(body.contains("name=\"encoding\"\r\n\r\nLINEAR_PCM"))
        #expect(body.contains("name=\"sample_rate_hz\"\r\n\r\n44100"))
        #expect(output.modelId == NVIDIAMagpieTTSProvider.modelID)
        #expect(output.voiceId == NVIDIAMagpieTTSProvider.defaultVoiceID)
        #expect(output.format == "wav")
        #expect(output.contentType == "audio/wav")
        #expect(String(data: output.audioData.prefix(4), encoding: .utf8) == "RIFF")
        #expect(output.audioData.suffix(pcm.count) == pcm)

        _ = try await provider.synthesize(SynthesisRequest(
            text: "Hola Scout.",
            modelId: NVIDIAMagpieTTSProvider.modelID,
            voiceId: "Magpie-Multilingual.ES-US.Isabela.Angry"
        ))
        let emotionBody = try #require(
            MockHTTPURLProtocol.lastBody.flatMap { String(data: $0, encoding: .utf8) }
        )
        #expect(emotionBody.contains("name=\"language\"\r\n\r\nes-US"))
        #expect(emotionBody.contains("name=\"voice\"\r\n\r\nMagpie-Multilingual.ES-US.Isabela.Angry"))
    }

    @Test("NVIDIA uses per-request credentials instead of configured env keys")
    func nvidiaPerRequestCredentials() async throws {
        let session = MockHTTPURLProtocol.session(body: try validWAV())
        let provider = NVIDIAMagpieTTSProvider(
            env: ["NV_API_KEY": "configured-key"],
            session: session
        )

        _ = try await provider.synthesize(SynthesisRequest(
            text: "Hello",
            modelId: NVIDIAMagpieTTSProvider.modelID,
            providerCredentials: ["NVIDIA_API_KEY": "lent-key"]
        ))

        #expect(MockHTTPURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer lent-key")
    }

    @Test("NVIDIA discovers the hosted Developer Inference voice roster")
    func nvidiaHostedVoiceDiscovery() async throws {
        let catalog = Data("""
        {
          "en-US,ja-JP": {
            "voices": [
              "Magpie-Multilingual.JA-JP.Siwei",
              "Magpie-Multilingual.ES-US.Isabela.Angry",
              "Magpie-Multilingual.EN-US.Jason",
              "Magpie-Multilingual.EN-US.Aria"
            ]
          }
        }
        """.utf8)
        let session = MockHTTPURLProtocol.session(body: catalog, contentType: "application/json")
        let provider = NVIDIAMagpieTTSProvider(
            env: ["NV_API_KEY": "synthetic-test-key"],
            session: session
        )

        let voices = try await provider.voices(modelId: NVIDIAMagpieTTSProvider.modelID)
        let request = try #require(MockHTTPURLProtocol.lastRequest)

        #expect(request.url?.host?.hasSuffix("invocation.api.nvcf.nvidia.com") == true)
        #expect(request.url?.path == "/v1/audio/list_voices")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-key")
        #expect(voices.map(\.id) == [
            NVIDIAMagpieTTSProvider.defaultVoiceID,
            "Magpie-Multilingual.EN-US.Jason",
            "Magpie-Multilingual.ES-US.Isabela.Angry",
            "Magpie-Multilingual.JA-JP.Siwei"
        ])
        #expect(voices[0].name == "Aria")
        #expect(voices[0].language == "en-US")
        #expect(voices[0].isDefault)
        #expect(voices[0].backend == "nvidia")
        #expect(voices[0].modelId == NVIDIAMagpieTTSProvider.modelID)
        #expect(voices[2].name == "Isabela · Angry")
        #expect(voices[2].language == "es-US")
    }

    @Test("NVIDIA returns a typed error for missing credentials")
    func nvidiaMissingCredentials() async {
        let provider = NVIDIAMagpieTTSProvider(env: [:], session: MockHTTPURLProtocol.session())
        do {
            _ = try await provider.synthesize(SynthesisRequest(
                text: "Hello",
                modelId: NVIDIAMagpieTTSProvider.modelID
            ))
            Issue.record("Expected missing API key")
        } catch let error as NVIDIAMagpieTTSProviderError {
            #expect(error.localizedDescription.contains("NV_API_KEY"))
        } catch {
            Issue.record("Expected NVIDIAMagpieTTSProviderError, got \(error)")
        }
    }

    @Test("NVIDIA surfaces HTTP error details without leaking credentials")
    func nvidiaHTTPErrorMessage() async {
        let session = MockHTTPURLProtocol.session(
            body: Data("{\"detail\":\"quota exceeded\"}".utf8),
            statusCode: 429,
            contentType: "application/json"
        )
        let provider = NVIDIAMagpieTTSProvider(
            env: ["NV_API_KEY": "synthetic-test-key"],
            session: session
        )
        do {
            _ = try await provider.synthesize(SynthesisRequest(
                text: "Hello",
                modelId: NVIDIAMagpieTTSProvider.modelID
            ))
            Issue.record("Expected request failed")
        } catch let error as NVIDIAMagpieTTSProviderError {
            #expect(error.localizedDescription.contains("quota exceeded"))
            #expect(!error.localizedDescription.contains("synthetic-test-key"))
        } catch {
            Issue.record("Expected NVIDIAMagpieTTSProviderError, got \(error)")
        }
    }

    @Test("NVIDIA rejects empty text and unsupported models")
    func nvidiaValidationErrors() async {
        let provider = NVIDIAMagpieTTSProvider(
            env: ["NV_API_KEY": "synthetic-test-key"],
            session: MockHTTPURLProtocol.session()
        )
        do {
            _ = try await provider.synthesize(SynthesisRequest(
                text: "   ",
                modelId: NVIDIAMagpieTTSProvider.modelID
            ))
            Issue.record("Expected missing text")
        } catch let error as NVIDIAMagpieTTSProviderError {
            #expect(error.localizedDescription == "Missing text")
        } catch {
            Issue.record("Expected NVIDIAMagpieTTSProviderError, got \(error)")
        }

        do {
            _ = try await provider.synthesize(SynthesisRequest(
                text: "Hello",
                modelId: "not-magpie"
            ))
            Issue.record("Expected unsupported model")
        } catch let error as NVIDIAMagpieTTSProviderError {
            #expect(error.localizedDescription.contains("not-magpie"))
        } catch {
            Issue.record("Expected NVIDIAMagpieTTSProviderError, got \(error)")
        }
    }

    @Test("Groq prefers per-request GROQ_API_KEY over env")
    func groqCredentialPrecedence() {
        #expect(GroqTTSProvider.resolveAPIKey(
            providerCredentials: ["groq_api_key": " lent "],
            env: ["GROQ_API_KEY": "env"],
            processEnv: ["GROQ_API_KEY": "process"]
        ) == "lent")
        #expect(GroqTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["GROQ_API_KEY": " env "],
            processEnv: [:]
        ) == "env")
    }

    @Test("explicit empty or whitespace GROQ_API_KEY fences process secrets")
    func groqEmptyEnvFencesProcessSecrets() {
        #expect(GroqTTSProvider.resolveConfiguredAPIKey(
            env: ["GROQ_API_KEY": ""],
            processEnv: ["GROQ_API_KEY": "process-secret"]
        ) == nil)
        #expect(GroqTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["GROQ_API_KEY": "  "],
            processEnv: ["GROQ_API_KEY": "process-secret"]
        ) == nil)
        #expect(GroqTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: [:],
            processEnv: ["GROQ_API_KEY": "process-secret"]
        ) == "process-secret")
        #expect(GroqTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["GROQ_BASE_URL": "https://example.test"],
            processEnv: ["GROQ_API_KEY": " process-secret "]
        ) == "process-secret")
        #expect(GroqTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: nil,
            processEnv: ["GROQ_API_KEY": "process-secret"]
        ) == "process-secret")
        #expect(GroqTTSProvider.resolveAPIKey(
            providerCredentials: ["groqApiKey": " lent "],
            env: ["GROQ_API_KEY": ""],
            processEnv: ["GROQ_API_KEY": "process-secret"]
        ) == "lent")
    }

    @Test("Groq sends the OpenAI-compatible Orpheus WAV contract")
    func groqRequestContract() async throws {
        let wav = try validWAV()
        let session = MockHTTPURLProtocol.session(body: wav)
        let provider = GroqTTSProvider(
            env: [
                "GROQ_API_KEY": "synthetic-test-key",
                "GROQ_BASE_URL": "https://example.test/openai/v1"
            ],
            session: session
        )
        let maximumInput = String(repeating: "a", count: GroqTTSProvider.maximumInputCharacters)

        let output = try await provider.synthesize(SynthesisRequest(
            text: maximumInput,
            modelId: GroqTTSProvider.defaultModelID,
            speed: 12
        ))
        let request = try #require(MockHTTPURLProtocol.lastRequest)
        let body = try #require(MockHTTPURLProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(request.url?.absoluteString == "https://example.test/openai/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-key")
        #expect(json["model"] as? String == GroqTTSProvider.defaultModelID)
        #expect(json["voice"] as? String == "autumn")
        #expect(json["input"] as? String == maximumInput)
        #expect(json["response_format"] as? String == "wav")
        #expect(json["speed"] as? Double == 5)
        #expect(output.format == "wav")
        #expect(output.voiceId == "autumn")
        #expect(output.modelId == GroqTTSProvider.defaultModelID)
        #expect(output.audioData == wav)
        #expect(PCMWAV.isStructurallyValid(output.audioData))
    }

    @Test("Groq rejects over-limit text instead of silently truncating it")
    func groqRejectsOverLimitInput() async {
        let session = MockHTTPURLProtocol.session(body: Data([0x03, 0x04]))
        let provider = GroqTTSProvider(
            env: ["GROQ_API_KEY": "synthetic-test-key"],
            session: session
        )
        let overLimit = String(repeating: "a", count: GroqTTSProvider.maximumInputCharacters + 1)

        do {
            _ = try await provider.synthesize(SynthesisRequest(
                text: overLimit,
                modelId: GroqTTSProvider.defaultModelID
            ))
            Issue.record("Expected input too long")
        } catch let error as GroqTTSProviderError {
            #expect(error.localizedDescription.contains("at most 200 characters"))
            #expect(MockHTTPURLProtocol.lastRequest == nil)
        } catch {
            Issue.record("Expected GroqTTSProviderError, got \(error)")
        }
    }

    @Test("Groq lists English and Arabic Orpheus voices")
    func groqVoiceCatalog() async throws {
        let provider = GroqTTSProvider(env: ["GROQ_API_KEY": "synthetic-test-key"])
        let english = try await provider.voices(modelId: GroqTTSProvider.defaultModelID)
        let arabic = try await provider.voices(modelId: GroqTTSProvider.arabicModelID)

        #expect(english.first?.id == "autumn")
        #expect(english.first?.isDefault == true)
        #expect(english.map(\.id).contains("troy"))
        #expect(arabic.first?.id == "abdullah")
        #expect(arabic.map(\.id).contains("noura"))
        #expect(arabic.first?.language == "ar-SA")
    }

    @Test("Groq preserves HTTP error messages")
    func groqHTTPErrorMessage() async {
        let session = MockHTTPURLProtocol.session(
            body: Data("{\"error\":{\"message\":\"slow down\"}}".utf8),
            statusCode: 429,
            contentType: "application/json"
        )
        let provider = GroqTTSProvider(
            env: ["GROQ_API_KEY": "synthetic-test-key"],
            session: session
        )
        do {
            _ = try await provider.synthesize(SynthesisRequest(
                text: "Hello",
                modelId: GroqTTSProvider.defaultModelID
            ))
            Issue.record("Expected request failed")
        } catch let error as GroqTTSProviderError {
            #expect(error.localizedDescription.contains("Groq TTS: slow down"))
            #expect(!error.localizedDescription.contains("synthetic-test-key"))
        } catch {
            Issue.record("Expected GroqTTSProviderError, got \(error)")
        }
    }

    @Test("Gemini prefers GEMINI_API_KEY then GOOGLE_API_KEY and per-request credentials")
    func geminiCredentialPrecedence() {
        #expect(GeminiTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["GEMINI_API_KEY": " gemini ", "GOOGLE_API_KEY": "google"],
            processEnv: [:]
        ) == "gemini")
        #expect(GeminiTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["GOOGLE_API_KEY": " google "],
            processEnv: [:]
        ) == "google")
        #expect(GeminiTTSProvider.resolveAPIKey(
            providerCredentials: ["googleApiKey": " lent "],
            env: ["GEMINI_API_KEY": "env"],
            processEnv: [:]
        ) == "lent")
    }

    @Test("explicit empty or whitespace Gemini/Google env aliases fence process secrets")
    func geminiEmptyEnvFencesProcessSecrets() {
        #expect(GeminiTTSProvider.resolveConfiguredAPIKey(
            env: ["GEMINI_API_KEY": ""],
            processEnv: ["GEMINI_API_KEY": "process-secret", "GOOGLE_API_KEY": "google-secret"]
        ) == nil)
        #expect(GeminiTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["GOOGLE_API_KEY": "  "],
            processEnv: ["GEMINI_API_KEY": "process-secret"]
        ) == nil)
        #expect(GeminiTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["GOOGLE_GENAI_API_KEY": ""],
            processEnv: ["GOOGLE_API_KEY": "process-secret"]
        ) == nil)
        #expect(GeminiTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: [:],
            processEnv: ["GEMINI_API_KEY": "process-secret"]
        ) == "process-secret")
        #expect(GeminiTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: ["GEMINI_BASE_URL": "https://example.test"],
            processEnv: ["GOOGLE_API_KEY": " process-google "]
        ) == "process-google")
        #expect(GeminiTTSProvider.resolveAPIKey(
            providerCredentials: [:],
            env: nil,
            processEnv: ["GOOGLE_GENAI_API_KEY": "process-genai"]
        ) == "process-genai")
        #expect(GeminiTTSProvider.resolveAPIKey(
            providerCredentials: ["GOOGLE_API_KEY": " lent "],
            env: ["GEMINI_API_KEY": ""],
            processEnv: ["GEMINI_API_KEY": "process-secret"]
        ) == "lent")
    }

    @Test("Gemini authenticates by header and wraps returned PCM as WAV")
    func geminiRequestAndPCMContract() async throws {
        let pcm = Data([0x00, 0x01, 0x02, 0x03])
        let responseObject: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [[
                        "inlineData": [
                            "mimeType": "audio/L16;codec=pcm;rate=22050;channels=2",
                            "data": pcm.base64EncodedString()
                        ]
                    ]]
                ]
            ]]
        ]
        let session = MockHTTPURLProtocol.session(
            body: try JSONSerialization.data(withJSONObject: responseObject),
            contentType: "application/json"
        )
        let provider = GeminiTTSProvider(
            env: [
                "GEMINI_API_KEY": "synthetic-test-key",
                "GEMINI_BASE_URL": "https://example.test/v1beta"
            ],
            session: session
        )

        let output = try await provider.synthesize(SynthesisRequest(
            text: "Hello Vox",
            modelId: "gemini-2.5-flash-preview-tts",
            voiceId: "Kore",
            instructions: "  Say warmly:  "
        ))

        let request = try #require(MockHTTPURLProtocol.lastRequest)
        let url = try #require(request.url)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "synthetic-test-key")
        #expect(url.query == nil)
        #expect(url.absoluteString == "https://example.test/v1beta/models/gemini-2.5-flash-preview-tts:generateContent")

        let body = try #require(MockHTTPURLProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "Say warmly:\n\nHello Vox")
        let generation = try #require(json["generationConfig"] as? [String: Any])
        let speech = try #require(generation["speechConfig"] as? [String: Any])
        let voice = try #require(speech["voiceConfig"] as? [String: Any])
        let prebuilt = try #require(voice["prebuiltVoiceConfig"] as? [String: Any])
        #expect(prebuilt["voiceName"] as? String == "Kore")

        #expect(output.format == "wav")
        #expect(output.voiceId == "Kore")
        #expect(output.contentType == "audio/wav")
        #expect(String(data: output.audioData.prefix(4), encoding: .utf8) == "RIFF")
        #expect(littleEndianUInt16(in: output.audioData, at: 22) == 2)
        #expect(littleEndianUInt32(in: output.audioData, at: 24) == 22_050)
        #expect(littleEndianUInt32(in: output.audioData, at: 40) == UInt32(pcm.count))
        #expect(output.audioData.suffix(pcm.count) == pcm)
    }

    @Test("Gemini generateContent URL joins GEMINI_BASE_URL with or without a trailing slash")
    func geminiGenerateContentURLJoinsTrailingSlash() {
        let modelId = GeminiTTSProvider.defaultModelID
        let expected = "https://example.test/v1beta/models/\(modelId):generateContent"
        let withoutSlash = GeminiTTSProvider.generateContentURL(
            baseURL: URL(string: "https://example.test/v1beta")!,
            modelId: modelId
        )
        let withSlash = GeminiTTSProvider.generateContentURL(
            baseURL: URL(string: "https://example.test/v1beta/")!,
            modelId: modelId
        )
        let withExtraSlashes = GeminiTTSProvider.generateContentURL(
            baseURL: URL(string: "https://example.test/v1beta///")!,
            modelId: modelId
        )
        #expect(withoutSlash?.absoluteString == expected)
        #expect(withSlash?.absoluteString == expected)
        #expect(withExtraSlashes?.absoluteString == expected)
    }

    @Test("Gemini synthesis normalizes a trailing-slash GEMINI_BASE_URL")
    func geminiTrailingSlashBaseURLDoesNotDuplicatePath() async throws {
        let pcm = Data([0x00, 0x01, 0x02, 0x03])
        let responseObject: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [[
                        "inlineData": [
                            "mimeType": "audio/L16;codec=pcm;rate=24000;channels=1",
                            "data": pcm.base64EncodedString()
                        ]
                    ]]
                ]
            ]]
        ]
        let session = MockHTTPURLProtocol.session(
            body: try JSONSerialization.data(withJSONObject: responseObject),
            contentType: "application/json"
        )
        let provider = GeminiTTSProvider(
            env: [
                "GEMINI_API_KEY": "synthetic-test-key",
                "GEMINI_BASE_URL": "https://example.test/v1beta/"
            ],
            session: session
        )

        _ = try await provider.synthesize(SynthesisRequest(
            text: "Hello Vox",
            modelId: GeminiTTSProvider.defaultModelID
        ))
        let url = try #require(MockHTTPURLProtocol.lastRequest?.url)
        #expect(url.absoluteString == "https://example.test/v1beta/models/gemini-2.5-flash-preview-tts:generateContent")
        #expect(!url.absoluteString.contains("/v1beta//models/"))
    }

    @Test("Gemini rejects malformed PCM metadata and incomplete frames")
    func geminiRejectsMalformedPCM() {
        expectUnsupportedPCM(Data([0x00, 0x01]), mimeType: "audio/L16;codec=pcm;rate=not-a-number")
        expectUnsupportedPCM(Data([0x00, 0x01, 0x02]), mimeType: "audio/L16;codec=pcm;rate=24000")
        expectUnsupportedPCM(Data([0x00, 0x01]), mimeType: "audio/L16;codec=pcm;rate=24000;channels=0")
    }

    @Test("Gemini preserves HTTP error messages")
    func geminiHTTPErrorMessage() async {
        let session = MockHTTPURLProtocol.session(
            body: Data("{\"error\":{\"message\":\"invalid voice\"}}".utf8),
            statusCode: 400,
            contentType: "application/json"
        )
        let provider = GeminiTTSProvider(
            env: ["GEMINI_API_KEY": "synthetic-test-key"],
            session: session
        )
        do {
            _ = try await provider.synthesize(SynthesisRequest(
                text: "Hello",
                modelId: GeminiTTSProvider.defaultModelID
            ))
            Issue.record("Expected request failed")
        } catch let error as GeminiTTSProviderError {
            #expect(error.localizedDescription.contains("Gemini TTS: invalid voice"))
            #expect(!error.localizedDescription.contains("synthetic-test-key"))
        } catch {
            Issue.record("Expected GeminiTTSProviderError, got \(error)")
        }
    }

    @Test("Gemini lists the official 30 prebuilt voices with Puck as default")
    func geminiVoiceCatalog() async throws {
        let provider = GeminiTTSProvider(env: ["GEMINI_API_KEY": "synthetic-test-key"])
        let voices = try await provider.voices(modelId: GeminiTTSProvider.defaultModelID)
        let puck = try #require(voices.first(where: { $0.id == "Puck" }))
        let officialCatalog = [
            "Zephyr", "Puck", "Charon", "Kore", "Fenrir", "Leda", "Orus", "Aoede",
            "Callirrhoe", "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba",
            "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar",
            "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird", "Zubenelgenubi",
            "Vindemiatrix", "Sadachbia", "Sadaltager", "Sulafat"
        ]
        #expect(puck.isDefault)
        #expect(voices.map(\.id) == officialCatalog)
        #expect(GeminiTTSProvider.supportedVoices == officialCatalog)
        #expect(voices.count == 30)
        #expect(voices.contains(where: { $0.id == "Rasalgethi" }))
        #expect(!voices.contains(where: { $0.id == "Rasalas" }))
        #expect(voices.contains(where: { $0.id == "Kore" }))
        #expect(voices.first?.backend == "gemini")
    }

    @Test("NVIDIA rejects over-limit text instead of silently truncating it")
    func nvidiaRejectsOverLimitInput() async throws {
        let session = MockHTTPURLProtocol.session(body: try validWAV())
        let provider = NVIDIAMagpieTTSProvider(
            env: ["NV_API_KEY": "synthetic-test-key"],
            session: session
        )
        let atLimit = String(repeating: "a", count: NVIDIAMagpieTTSProvider.maximumInputCharacters)
        let overLimit = String(repeating: "a", count: NVIDIAMagpieTTSProvider.maximumInputCharacters + 1)

        let output = try await provider.synthesize(SynthesisRequest(
            text: atLimit,
            modelId: NVIDIAMagpieTTSProvider.modelID
        ))
        #expect(output.metrics.characterCount == NVIDIAMagpieTTSProvider.maximumInputCharacters)
        #expect(MockHTTPURLProtocol.lastRequest != nil)

        do {
            _ = try await provider.synthesize(SynthesisRequest(
                text: overLimit,
                modelId: NVIDIAMagpieTTSProvider.modelID
            ))
            Issue.record("Expected input too long")
        } catch let error as NVIDIAMagpieTTSProviderError {
            #expect(error.localizedDescription.contains("at most 2000 normalized characters"))
        } catch {
            Issue.record("Expected NVIDIAMagpieTTSProviderError, got \(error)")
        }
    }

    @Test("NVIDIA wraps aligned LINEAR_PCM and accepts valid WAVE, rejecting other payloads")
    func nvidiaAudioValidation() throws {
        let pcm = Data([0x00, 0x01, 0x02, 0x03])
        let wrapped = try NVIDIAMagpieTTSProvider.decodeAudio(
            pcm,
            contentType: "audio/l16",
            sampleRate: 44_100
        )
        #expect(PCMWAV.isStructurallyValid(wrapped))
        #expect(wrapped.suffix(pcm.count) == pcm)

        let wav = try validWAV()
        let accepted = try NVIDIAMagpieTTSProvider.decodeAudio(
            wav,
            contentType: "audio/wav",
            sampleRate: 44_100
        )
        #expect(accepted == wav)

        do {
            _ = try NVIDIAMagpieTTSProvider.decodeAudio(
                Data([0x00, 0x01, 0x02]),
                contentType: "audio/l16",
                sampleRate: 44_100
            )
            Issue.record("Expected invalid unaligned PCM")
        } catch let error as NVIDIAMagpieTTSProviderError {
            #expect(error.localizedDescription.contains("not a valid WAVE"))
        } catch {
            Issue.record("Expected NVIDIAMagpieTTSProviderError, got \(error)")
        }

        do {
            _ = try NVIDIAMagpieTTSProvider.decodeAudio(
                Data("{\"detail\":\"not audio\"}".utf8),
                contentType: "application/json",
                sampleRate: 44_100
            )
            Issue.record("Expected invalid JSON payload")
        } catch let error as NVIDIAMagpieTTSProviderError {
            #expect(error.localizedDescription.contains("not a valid WAVE"))
        } catch {
            Issue.record("Expected NVIDIAMagpieTTSProviderError, got \(error)")
        }
    }

    @Test("Groq requires a structurally valid WAV instead of any nonempty bytes")
    func groqRejectsNonWAVAudio() async {
        let session = MockHTTPURLProtocol.session(body: Data([0x52, 0x49, 0x46, 0x46]))
        let provider = GroqTTSProvider(
            env: ["GROQ_API_KEY": "synthetic-test-key"],
            session: session
        )
        do {
            _ = try await provider.synthesize(SynthesisRequest(
                text: "Hello",
                modelId: GroqTTSProvider.defaultModelID
            ))
            Issue.record("Expected invalid audio")
        } catch let error as GroqTTSProviderError {
            #expect(error.localizedDescription.contains("structurally valid WAV"))
        } catch {
            Issue.record("Expected GroqTTSProviderError, got \(error)")
        }
    }

    @Test("NVIDIA, Groq, and Gemini map URLSession cancellation to CancellationError")
    func remoteProvidersNormalizeCancellation() async {
        await expectCancellation {
            try await NVIDIAMagpieTTSProvider(
                env: ["NV_API_KEY": "synthetic-test-key"],
                session: MockHTTPURLProtocol.session(error: URLError(.cancelled))
            ).synthesize(SynthesisRequest(
                text: "Hello",
                modelId: NVIDIAMagpieTTSProvider.modelID
            ))
        }
        await expectCancellation {
            try await NVIDIAMagpieTTSProvider(
                env: ["NV_API_KEY": "synthetic-test-key"],
                session: MockHTTPURLProtocol.session(
                    error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
                )
            ).voices(modelId: NVIDIAMagpieTTSProvider.modelID)
        }
        await expectCancellation {
            try await GroqTTSProvider(
                env: ["GROQ_API_KEY": "synthetic-test-key"],
                session: MockHTTPURLProtocol.session(error: URLError(.cancelled))
            ).synthesize(SynthesisRequest(
                text: "Hello",
                modelId: GroqTTSProvider.defaultModelID
            ))
        }
        await expectCancellation {
            try await GeminiTTSProvider(
                env: ["GEMINI_API_KEY": "synthetic-test-key"],
                session: MockHTTPURLProtocol.session(error: URLError(.cancelled))
            ).synthesize(SynthesisRequest(
                text: "Hello",
                modelId: GeminiTTSProvider.defaultModelID
            ))
        }
    }

    @Test("Vendor error bodies are bounded and do not echo credentials or request text")
    func vendorErrorBodiesAreSanitized() {
        let prompt = "Hello secret prompt"
        let huge = String(repeating: "x", count: 4_000)
        let body = Data("""
        {"error":{"message":"quota for Bearer nvapi-secret-key and input \(prompt) \(huge)"}}
        """.utf8)
        let message = RemoteTTSSupport.sanitizeVendorMessage(
            from: body,
            vendor: "NVIDIA Magpie",
            sensitiveValues: [prompt]
        )
        #expect(message.contains("quota"))
        #expect(!message.contains("nvapi-secret-key"))
        #expect(!message.contains(prompt))
        #expect(!message.contains("Hello secret prompt"))
        #expect(message.contains("[redacted]"))
        #expect(message.count <= RemoteTTSSupport.maximumVendorMessageLength + 1)
    }

    @Test("short echoed prompts never persist in vendor error detail")
    func shortEchoedPromptsNeverAppear() {
        let promptHi = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data("{\"error\":{\"message\":\"prompt hi\"}}".utf8),
            vendor: "Groq TTS",
            sensitiveValues: ["hi"]
        )
        #expect(promptHi == "Groq TTS: request failed")
        #expect(!promptHi.localizedCaseInsensitiveContains("hi"))

        let textA = RemoteTTSSupport.redactExactSensitiveValues(
            "text a",
            sensitiveValues: ["a"]
        )
        #expect(textA == "request failed")
        #expect(!textA.contains("text a"))

        let oneCharacterInQuota = RemoteTTSSupport.redactExactSensitiveValues(
            "quota exceeded",
            sensitiveValues: ["a"]
        )
        #expect(oneCharacterInQuota == "request failed")
        #expect(!oneCharacterInQuota.contains("quota"))

        let oneCharacterMessage = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data("{\"error\":{\"message\":\"quota exceeded\"}}".utf8),
            vendor: "NVIDIA Magpie",
            sensitiveValues: ["a"]
        )
        #expect(oneCharacterMessage == "NVIDIA Magpie: request failed")
        #expect(!oneCharacterMessage.contains("quota exceeded"))
    }

    @Test("plain-text vendor errors do not keep a clipped prefix of a long prompt")
    func plainTextErrorsDropLongPromptPrefixes() {
        let token = "secret-prompt-token-"
        let longPrompt = String(repeating: token, count: 20)
        #expect(longPrompt.count > RemoteTTSSupport.plainTextClipLength)
        let prefix = String(longPrompt.prefix(RemoteTTSSupport.plainTextClipLength))

        let clippedBody = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data(prefix.utf8),
            vendor: "Groq TTS",
            sensitiveValues: [longPrompt]
        )
        #expect(clippedBody == "Groq TTS: request failed")
        #expect(!clippedBody.contains(prefix))
        #expect(!clippedBody.contains(token))

        let fullBody = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data(longPrompt.utf8),
            vendor: "NVIDIA Magpie",
            sensitiveValues: [longPrompt]
        )
        #expect(fullBody == "NVIDIA Magpie: request failed")
        #expect(!fullBody.contains(token))

        let prefixedBody = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data("quota exceeded \(prefix)".utf8),
            vendor: "Gemini TTS",
            sensitiveValues: [longPrompt]
        )
        #expect(prefixedBody == "Gemini TTS: request failed")
        #expect(!prefixedBody.contains(token))
        #expect(!prefixedBody.contains("quota"))

        let unrelated = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data("quota exceeded".utf8),
            vendor: "Groq TTS",
            sensitiveValues: [longPrompt]
        )
        #expect(unrelated == "Groq TTS: request failed")
        #expect(!unrelated.contains("quota"))
        #expect(!unrelated.contains(token))

        let jsonKeepsQuota = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data("{\"error\":{\"message\":\"quota exceeded for input \(longPrompt)\"}}".utf8),
            vendor: "NVIDIA Magpie",
            sensitiveValues: [longPrompt]
        )
        #expect(jsonKeepsQuota.contains("quota"))
        #expect(!jsonKeepsQuota.contains(token))
        #expect(jsonKeepsQuota.contains("[redacted]"))

        let secretPlain = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data("upstream Bearer nvapi-secret-key denied".utf8),
            vendor: "NVIDIA Magpie",
            sensitiveValues: [longPrompt]
        )
        #expect(secretPlain == "NVIDIA Magpie: request failed")
        #expect(!secretPlain.contains("nvapi-secret-key"))
        #expect(!secretPlain.contains("upstream"))

        let secretJSON = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data("{\"error\":{\"message\":\"upstream Bearer nvapi-secret-key denied\"}}".utf8),
            vendor: "NVIDIA Magpie",
            sensitiveValues: [longPrompt]
        )
        #expect(secretJSON.contains("upstream"))
        #expect(secretJSON.contains("[redacted]"))
        #expect(!secretJSON.contains("nvapi-secret-key"))

        let voiceDiscovery = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data("quota exceeded".utf8),
            vendor: "NVIDIA Magpie"
        )
        #expect(voiceDiscovery.contains("quota exceeded"))
    }

    @Test("plain-text vendor errors fail closed on a distinctive prompt fragment")
    func plainTextErrorsFailClosedOnPromptFragment() {
        let prompt = "UNIQUE-PROMPT-PREFIX-" + String(repeating: "x", count: 279)
        #expect(prompt.count == 300)
        let fragment = String(prompt.prefix(20))
        let body = "quota: \(fragment)"
        #expect(body.contains("quota: "))
        #expect(fragment.count == 20)

        let message = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data(body.utf8),
            vendor: "Groq TTS",
            sensitiveValues: [prompt]
        )
        #expect(message == "Groq TTS: request failed")
        #expect(!message.contains(fragment))
        #expect(!message.contains("quota"))
        #expect(!message.contains(prompt))

        let jsonKeepsQuota = RemoteTTSSupport.sanitizeVendorMessage(
            from: Data("{\"error\":{\"message\":\"quota exceeded\"}}".utf8),
            vendor: "NVIDIA Magpie",
            sensitiveValues: [prompt]
        )
        #expect(jsonKeepsQuota.contains("quota"))
        #expect(!jsonKeepsQuota.contains(fragment))
        #expect(!jsonKeepsQuota.contains(prompt))
    }

    @Test("NVIDIA synthesis HTTP errors drop an echoed request prompt")
    func nvidiaHTTPErrorStripsEchoedPrompt() async {
        let prompt = "Hello secret prompt"
        await expectEchoedPromptIsAbsent(
            synthesize: {
                try await NVIDIAMagpieTTSProvider(
                    env: ["NV_API_KEY": "synthetic-test-key"],
                    session: MockHTTPURLProtocol.session(
                        body: Data("{\"detail\":\"quota exceeded for input: \(prompt)\"}".utf8),
                        statusCode: 429,
                        contentType: "application/json"
                    )
                ).synthesize(SynthesisRequest(
                    text: prompt,
                    modelId: NVIDIAMagpieTTSProvider.modelID
                ))
            },
            prompt: prompt,
            retains: "quota"
        )
    }

    @Test("Groq synthesis HTTP errors drop an echoed request prompt")
    func groqHTTPErrorStripsEchoedPrompt() async {
        let prompt = "Hello secret prompt"
        await expectEchoedPromptIsAbsent(
            synthesize: {
                try await GroqTTSProvider(
                    env: ["GROQ_API_KEY": "synthetic-test-key"],
                    session: MockHTTPURLProtocol.session(
                        body: Data("{\"error\":{\"message\":\"quota exceeded for input: \(prompt)\"}}".utf8),
                        statusCode: 429,
                        contentType: "application/json"
                    )
                ).synthesize(SynthesisRequest(
                    text: prompt,
                    modelId: GroqTTSProvider.defaultModelID
                ))
            },
            prompt: prompt,
            retains: "quota"
        )
    }

    @Test("Gemini synthesis HTTP errors drop an echoed request prompt")
    func geminiHTTPErrorStripsEchoedPrompt() async {
        let prompt = "Hello secret prompt"
        await expectEchoedPromptIsAbsent(
            synthesize: {
                try await GeminiTTSProvider(
                    env: ["GEMINI_API_KEY": "synthetic-test-key"],
                    session: MockHTTPURLProtocol.session(
                        body: Data("{\"error\":{\"message\":\"quota exceeded for prompt \(prompt)\"}}".utf8),
                        statusCode: 429,
                        contentType: "application/json"
                    )
                ).synthesize(SynthesisRequest(
                    text: prompt,
                    modelId: GeminiTTSProvider.defaultModelID
                ))
            },
            prompt: prompt,
            retains: "quota"
        )
    }

    @Test("Gemini 3.1 flash TTS preview uses the generateContent contract")
    func gemini31UsesGenerateContent() async throws {
        let pcm = Data([0x00, 0x01, 0x02, 0x03])
        let responseObject: [String: Any] = [
            "candidates": [[
                "content": [
                    "parts": [[
                        "inlineData": [
                            "mimeType": "audio/L16;codec=pcm;rate=24000;channels=1",
                            "data": pcm.base64EncodedString()
                        ]
                    ]]
                ]
            ]]
        ]
        let session = MockHTTPURLProtocol.session(
            body: try JSONSerialization.data(withJSONObject: responseObject),
            contentType: "application/json"
        )
        let provider = GeminiTTSProvider(
            env: [
                "GEMINI_API_KEY": "synthetic-test-key",
                "GEMINI_BASE_URL": "https://example.test/v1beta"
            ],
            session: session
        )

        let output = try await provider.synthesize(SynthesisRequest(
            text: "Hello Vox",
            modelId: "gemini-3.1-flash-tts-preview"
        ))
        let url = try #require(MockHTTPURLProtocol.lastRequest?.url)
        #expect(url.absoluteString.contains("/models/gemini-3.1-flash-tts-preview:generateContent"))
        #expect(GeminiTTSProvider.supportedModelIDs.contains("gemini-3.1-flash-tts-preview"))
        #expect(output.format == "wav")
        #expect(PCMWAV.isStructurallyValid(output.audioData))
    }

    private func expectEchoedPromptIsAbsent(
        synthesize: () async throws -> some Any,
        prompt: String,
        retains: String
    ) async {
        do {
            _ = try await synthesize()
            Issue.record("Expected request failed")
        } catch {
            let description = error.localizedDescription
            #expect(description.contains(retains))
            #expect(!description.contains(prompt))
            #expect(!description.contains("Hello secret prompt"))
        }
    }

    private func expectCancellation(_ work: () async throws -> some Any) async {
        do {
            _ = try await work()
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    private func expectUnsupportedPCM(_ audio: Data, mimeType: String) {
        do {
            _ = try GeminiTTSProvider.pcmWAV(audio: audio, mimeType: mimeType)
            Issue.record("Expected unsupported Gemini PCM metadata")
        } catch let error as GeminiTTSProviderError {
            #expect(error.localizedDescription.contains("unsupported audio format"))
        } catch {
            Issue.record("Expected GeminiTTSProviderError, got \(error)")
        }
    }

    private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func validWAV(pcm: Data = Data([0x00, 0x01, 0x02, 0x03])) throws -> Data {
        try PCMWAV.wrap(pcm: pcm, sampleRate: 44_100)
    }
}
