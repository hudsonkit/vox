import AVFoundation
import Foundation
import Testing
import VoxCore
@testable import HudsonSpeechEngine

struct NativeVoiceQualityTests {
    @Test("Native quality uses platform values only")
    func platformMapping() {
        #expect(AVSpeechSynthesizerProvider.normalizedQuality(.default) == .standard)
        #expect(AVSpeechSynthesizerProvider.normalizedQuality(.enhanced) == .enhanced)
        #expect(AVSpeechSynthesizerProvider.normalizedQuality(.premium) == .premium)
    }

    @Test("Native inventory preserves identifiers and uses each platform voice quality")
    @MainActor func platformInventory() async throws {
        let provider = AVSpeechSynthesizerProvider()
        let inventory = try await provider.voices(modelId: AVSpeechSynthesizerProvider.modelID)
        let platform = Dictionary(uniqueKeysWithValues: AVSpeechSynthesisVoice.speechVoices().map { ($0.identifier, $0) })
        #expect(inventory.count == platform.count)
        for item in inventory {
            let source = try #require(platform[item.id])
            #expect(item.name == source.name)
            #expect(item.language == source.language)
            #expect(item.available)
            #expect(item.quality == AVSpeechSynthesizerProvider.normalizedQuality(source.quality))
        }
    }

    #if os(macOS)
    @Test("Native quality survives the external provider hop; cloud and unknown stay absent")
    func externalProviderWire() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("voices.js")
        try """
        const qualities = ['standard','enhanced','premium','future-quality',null,undefined];
        const voices = qualities.map((quality,i) => ({id:'id-'+i,name:'Premium Enhanced Name',
          language:'en-GB',backend:'avspeech',modelId:'avspeech:system',available:i!==1,default:i===2,quality}));
        voices.push({id:'cloud',name:'Premium',backend:'cloud',modelId:'cloud:v1',available:true,default:false,quality:'premium'});
        require('readline').createInterface({input:process.stdin}).on('line',line => {
          const r=JSON.parse(line);
          process.stdout.write(JSON.stringify({id:r.id,result:{voices}})+'\\n');
        });
        """.write(to: script, atomically: true, encoding: .utf8)
        let provider = ExternalTTSProvider(id: "fixture", command: ["/usr/bin/env", "bun", script.path])
        do {
            let voices = try await provider.voices(modelId: "avspeech:system")
            #expect(voices.map(\.quality) == [.standard, .enhanced, .premium, nil, nil, nil, nil])
            #expect(voices.map(\.id) == ["id-0", "id-1", "id-2", "id-3", "id-4", "id-5", "cloud"])
            #expect(voices[1].available == false)
            #expect(voices[2].isDefault)
            #expect(voices[0].language == "en-GB")
            #expect(voices[0].name == "Premium Enhanced Name")
            await provider.shutdown()
        } catch {
            await provider.shutdown()
            throw error
        }
    }
    #endif
}
