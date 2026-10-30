import Foundation
import Testing
@testable import VoxCore

struct TTSLentCredentialsTests {
    @Test("allowlist forwards OpenAI, ElevenLabs, NVIDIA, Groq, and Gemini aliases and drops everything else")
    func parsesAllowlistedKeysOnly() {
        let credentials = TTSLentCredentials.parse(from: [
            "credentials": [
                "OPENAI_API_KEY": " sk-openai ",
                "NVIDIA_API_KEY": "nv-documented",
                "nvApiKey": "nv-camel",
                "GROQ_API_KEY": " groq-key ",
                "GOOGLE_GENAI_API_KEY": "google-alias",
                "geminiApiKey": "gemini-camel",
                "ELEVENLABS_API_KEY": " eleven-lent ",
                "elevenlabsApiKey": "camel",
                "elevenlabs_api_key": "snake",
                "MINIMAX_API_KEY": "should-drop",
                "ignored": "not-forwarded"
            ]
        ])

        #expect(credentials["OPENAI_API_KEY"] == "sk-openai")
        #expect(credentials["NVIDIA_API_KEY"] == "nv-documented")
        #expect(credentials["nvApiKey"] == "nv-camel")
        #expect(credentials["GROQ_API_KEY"] == "groq-key")
        #expect(credentials["GOOGLE_GENAI_API_KEY"] == "google-alias")
        #expect(credentials["geminiApiKey"] == "gemini-camel")
        #expect(credentials["ELEVENLABS_API_KEY"] == "eleven-lent")
        #expect(credentials["elevenlabsApiKey"] == "camel")
        #expect(credentials["elevenlabs_api_key"] == "snake")
        #expect(credentials["MINIMAX_API_KEY"] == nil)
        #expect(credentials["ignored"] == nil)
        #expect(!credentials.values.contains(where: { $0.contains("should-drop") }))
    }

    @Test("empty and missing credential objects produce an empty map")
    func emptyCredentialsAreDropped() {
        #expect(TTSLentCredentials.parse(from: nil).isEmpty)
        #expect(TTSLentCredentials.parse(from: [:]).isEmpty)
        #expect(TTSLentCredentials.parse(from: ["credentials": ["OPENAI_API_KEY": "   "]]).isEmpty)
    }
}
