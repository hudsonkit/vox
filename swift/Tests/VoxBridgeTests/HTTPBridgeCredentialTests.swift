import Foundation
import Testing
@testable import VoxBridge

struct HTTPBridgeCredentialTests {
    @Test("HTTP bridge allowlists ElevenLabs, NVIDIA, Groq, and Gemini credentials and drops unsupported keys")
    func bridgeForwardsAllowlistedTTSCredentials() throws {
        let credentials = HTTPBridgeServer.providerCredentials(from: [
            "credentials": [
                "NV_API_KEY": " nv-key ",
                "NVIDIA_API_KEY": "nvidia-alias",
                "GROQ_API_KEY": "groq-key",
                "groq_api_key": "groq-snake",
                "GEMINI_API_KEY": "gemini-key",
                "GOOGLE_API_KEY": "google-key",
                "ELEVENLABS_API_KEY": " eleven-lent ",
                "secret": "nope"
            ]
        ])

        let parsed = try #require(credentials)
        #expect(parsed["NV_API_KEY"] == "nv-key")
        #expect(parsed["NVIDIA_API_KEY"] == "nvidia-alias")
        #expect(parsed["GROQ_API_KEY"] == "groq-key")
        #expect(parsed["groq_api_key"] == "groq-snake")
        #expect(parsed["GEMINI_API_KEY"] == "gemini-key")
        #expect(parsed["GOOGLE_API_KEY"] == "google-key")
        #expect(parsed["ELEVENLABS_API_KEY"] == "eleven-lent")
        #expect(parsed["secret"] == nil)
    }

    @Test("HTTP bridge omits empty credential objects")
    func bridgeOmitsEmptyCredentials() {
        #expect(HTTPBridgeServer.providerCredentials(from: nil) == nil)
        #expect(HTTPBridgeServer.providerCredentials(from: ["credentials": [:]]) == nil)
        #expect(HTTPBridgeServer.providerCredentials(from: [
            "credentials": ["OPENAI_API_KEY": "  "]
        ]) == nil)
    }
}
