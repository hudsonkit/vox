import Foundation

/// Allowlist for per-request TTS credential lending.
///
/// Only OpenAI, ElevenLabs, NVIDIA Magpie, Groq, and Gemini/Google keys are forwarded
/// through the companion RPC and HTTP bridge. Unknown keys are dropped and
/// values are never logged by this parser.
public enum TTSLentCredentials {
    public static let allowedKeys: Set<String> = [
        "ELEVENLABS_API_KEY",
        "elevenlabsApiKey",
        "elevenlabs_api_key",
        "OPENAI_API_KEY",
        "openaiApiKey",
        "openai_api_key",
        "NV_API_KEY",
        "NVIDIA_API_KEY",
        "nvApiKey",
        "nvidiaApiKey",
        "nv_api_key",
        "nvidia_api_key",
        "GROQ_API_KEY",
        "groqApiKey",
        "groq_api_key",
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "GOOGLE_GENAI_API_KEY",
        "geminiApiKey",
        "googleApiKey",
        "googleGenaiApiKey",
        "gemini_api_key",
        "google_api_key",
        "google_genai_api_key"
    ]

    public static func parse(from container: [String: Any]?) -> [String: String] {
        guard let rawCredentials = container?["credentials"] as? [String: Any] else {
            return [:]
        }

        var credentials: [String: String] = [:]
        for key in allowedKeys {
            guard let value = rawCredentials[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                credentials[key] = trimmed
            }
        }
        return credentials
    }
}
