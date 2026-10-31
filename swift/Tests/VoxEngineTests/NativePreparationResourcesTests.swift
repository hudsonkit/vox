import Foundation
import Testing
@testable import HudsonSpeechEngine

struct NativePreparationResourcesTests {
    @Test func defaultsAndExplicitReserve() throws {
        #expect(try NativePreparationResources.minimumFreeDiskBytes(environment: [:]) == NativePreparationResources.defaultMinimumFreeDiskBytes)
        #expect(try NativePreparationResources.minimumFreeDiskBytes(environment: ["VOX_ASR_MIN_FREE_DISK_BYTES": "0"]) == 0)
        #expect(try NativePreparationResources.minimumFreeDiskBytes(environment: ["VOX_ASR_MIN_FREE_DISK_BYTES": "4294967296"]) == 4294967296)
        for raw in ["", "-1", "NaN", "invalid", "999999999999999999999999999"] {
            #expect(throws: NativePreparationError.self) { try NativePreparationResources.minimumFreeDiskBytes(environment: ["VOX_ASR_MIN_FREE_DISK_BYTES": raw]) }
        }
    }
    @Test func admissionFailsClosedBeforeNativeWork() throws {
        #expect(throws: NativePreparationError.self) { try NativePreparationResources.validate(.init(availableDiskBytes: 100, memoryPressureLevel: 1), minimumFreeDiskBytes: 101) }
        #expect(throws: NativePreparationError.self) { try NativePreparationResources.validate(.init(availableDiskBytes: -1, memoryPressureLevel: 1), minimumFreeDiskBytes: 0) }
        #expect(throws: NativePreparationError.self) { try NativePreparationResources.validate(.init(availableDiskBytes: 100, memoryPressureLevel: 4), minimumFreeDiskBytes: 100) }
        try NativePreparationResources.validate(.init(availableDiskBytes: 100, memoryPressureLevel: 2), minimumFreeDiskBytes: 100)
    }
}
