import Foundation
import Testing
import VoxCore

struct ASRIdlePolicyTests {
    @Test("Desktop idle policy is bounded; mobile retains its conservative default")
    func platformDefault() {
        #if os(macOS)
        #expect(StreamingASRDefaults.idleUnloadSeconds == 900)
        #else
        #expect(StreamingASRDefaults.idleUnloadSeconds == 60)
        #endif
        #expect(StreamingASRDefaults.resolvedIdleUnloadSeconds(environment: [:]) == StreamingASRDefaults.idleUnloadSeconds)
    }

    @Test("Explicit idle configuration accepts finite nonnegative seconds, otherwise uses the platform default")
    func configuration() {
        for (raw, seconds) in [("0", 0.0), ("60", 60.0), (" 900\n", 900.0), ("0.25", 0.25)] {
            #expect(StreamingASRDefaults.resolvedIdleUnloadSeconds(environment: ["VOX_ASR_IDLE_SECONDS": raw]) == seconds)
        }
        for raw in ["", "oops", "NaN", "inf", "-inf", "-1"] {
            #expect(StreamingASRDefaults.resolvedIdleUnloadSeconds(environment: ["VOX_ASR_IDLE_SECONDS": raw]) == StreamingASRDefaults.idleUnloadSeconds)
        }
    }

    @Test("Idle capability is optional for old model inventory and roundtrips actual configured values")
    func inventoryCompatibility() throws {
        let legacy = Data(#"{"id":"parakeet:v3","name":"v3","backend":"coreml","installed":true,"preloaded":false,"available":true}"#.utf8)
        let info = try JSONDecoder().decode(ASRModelInfo.self, from: legacy)
        #expect(info.idleUnloadSeconds == nil)
        #expect(info.dictionaryValue()["idleUnloadSeconds"] == nil)
        for seconds in [0.0, 60.0, 900.0] {
            let configured = ASRModelInfo(id: info.id, name: info.name, backend: info.backend,
                installed: true, preloaded: false, available: true, idleUnloadSeconds: seconds)
            #expect(try JSONDecoder().decode(ASRModelInfo.self, from: JSONEncoder().encode(configured)) == configured)
            #expect(configured.dictionaryValue()["idleUnloadSeconds"] as? Double == seconds)
        }
    }
}
