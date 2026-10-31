import Foundation
import Testing
import VoxCore

struct TTSVoiceQualityTests {
    private func voice(_ quality: TTSVoiceQuality? = nil) -> TTSVoiceInfo {
        TTSVoiceInfo(id: "unchanged-id", name: "Name (Premium)", language: "en-GB",
                     backend: "avspeech", modelId: "avspeech:system", available: false,
                     isDefault: true, quality: quality)
    }

    @Test(arguments: TTSVoiceQuality.allCases)
    func knownQualityRoundtrips(_ quality: TTSVoiceQuality) throws {
        let original = voice(quality)
        #expect(try JSONDecoder().decode(TTSVoiceInfo.self, from: JSONEncoder().encode(original)) == original)
        let wire = original.dictionaryValue()
        #expect(wire["quality"] as? String == quality.rawValue)
        #expect(wire["default"] as? Bool == true)
        #expect(wire["isDefault"] == nil)
        #expect(try JSONDecoder().decode(TTSVoiceInfo.self, from: JSONSerialization.data(withJSONObject: wire)) == original)
    }

    @Test("Legacy Swift and wire data keep all metadata and unknown quality")
    func legacyData() throws {
        let original = voice()
        #expect(original.dictionaryValue()["quality"] == nil)
        let archive = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(TTSVoiceInfo.self, from: archive) == original)
        let wire = try JSONSerialization.data(withJSONObject: original.dictionaryValue())
        #expect(try JSONDecoder().decode(TTSVoiceInfo.self, from: wire) == original)
    }

    @Test("Null and future wire quality remain unknown, not standard")
    func unknownQuality() throws {
        for value: Any in [NSNull(), "future-quality"] {
            var wire = voice().dictionaryValue()
            wire["quality"] = value
            let decoded = try JSONDecoder().decode(TTSVoiceInfo.self, from: JSONSerialization.data(withJSONObject: wire))
            #expect(decoded == voice())
            #expect(decoded.quality == nil)
        }
    }
}
