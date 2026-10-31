import AVFoundation
import Foundation
import Testing
import VoxCore
import VoxEngine
@testable import VoxAppleSpeech

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReadoutControlsTests {
    @Test("Native pitch/volume apply before enqueue, survive seek and do not leak into another request")
    func nativeOutputOptions() async throws {
        let f = Fixture()
        let options = SpeechOutputOptions(pitchMultiplier: 0.6, volume: 0.25)
        let id = try await f.controller.start(f.request(), options: options)
        try await f.playing(id)
        #expect(f.sink.spoken.last?.pitch == Float(0.6))
        #expect(f.sink.spoken.last?.volume == Float(0.25))
        #expect(await f.controller.status()?.options == options)
        #expect(f.events.values.allSatisfy { $0.options == options && $0.capabilities.canSetPitch && $0.capabilities.canSetVolume })
        let next = try await f.controller.seek(id, toUTF16Offset: 6)
        try await f.playing(next)
        #expect(f.sink.spoken.last?.pitch == Float(0.6) && f.sink.spoken.last?.volume == Float(0.25))
        #expect(await f.controller.status()?.options == options)
        let plain = try await f.controller.start(f.request())
        try await f.playing(plain)
        #expect(f.sink.spoken.last?.pitch == 1 && f.sink.spoken.last?.volume == 1)
        #expect(await f.controller.status()?.options == SpeechOutputOptions())
        try await f.controller.stop(plain)
    }

    @Test("Output options reject nonfinite/out-of-range values before replacing active playback; boundaries are accepted")
    func outputOptionValidation() async throws {
        let f = Fixture()
        var current = try await f.controller.start(f.request())
        try await f.playing(current)
        for pitch in [Double.nan, .infinity, -.infinity, 0.49, 2.01] {
            await #expect(throws: SpeechOutputControlError.invalidPitchMultiplier) {
                try await f.controller.start(f.request(), options: .init(pitchMultiplier: pitch))
            }
            #expect(await f.controller.status()?.identity == current)
        }
        for volume in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            await #expect(throws: SpeechOutputControlError.invalidVolume) {
                try await f.controller.speak(f.request(), options: .init(volume: volume))
            }
            #expect(await f.controller.status()?.identity == current)
        }
        #expect(f.sink.spoken.count == 1)
        for (pitch, volume) in [(0.5, 0.0), (2.0, 1.0), (1.6, 0.6)] {
            current = try await f.controller.start(f.request(), options: .init(pitchMultiplier: pitch, volume: volume))
            try await f.playing(current)
            #expect(f.sink.spoken.last?.pitch == Float(pitch) && f.sink.spoken.last?.volume == Float(volume))
        }
        try await f.controller.stop(current)
    }

    @Test("Explicit unsupported native options fail rather than silently using platform defaults")
    func unsupportedNativeOptions() async throws {
        for (options, error) in [(SpeechOutputOptions(pitchMultiplier: 1), SpeechOutputControlError.unsupportedPitch),
                                 (SpeechOutputOptions(volume: 1), SpeechOutputControlError.unsupportedVolume)] {
            let f = Fixture(sink: ControlSynthesizer(capabilities: .unavailable))
            let id = try await f.controller.start(f.request(), options: options)
            try await f.events.wait(.failed, id)
            #expect(f.sink.spoken.isEmpty)
            #expect(f.events.values.last?.error == error.localizedDescription)
            #expect(f.events.values.last?.controlError == error)
            #expect(f.events.values.last?.options == options)
            #expect(await f.controller.status() == nil)
        }
    }

    @Test("Generated output supports real player volume but rejects pitch before generation and declined volume before play")
    func generatedOutputOptions() async throws {
        let provider = ReadoutProvider(), events = ControlEvents(), player = ControlPlayer()
        let controller = AppleSpeechOutputController(engine: TTSEngineManager(provider: provider),
            synthesizer: ControlSynthesizer(), playerFactory: { _ in player }, onEvent: events.append)
        let request = SynthesisRequest(text: "Cloud bytes", modelId: "fixture")
        let pitched = try await controller.start(request, options: .init(pitchMultiplier: 1.2))
        try await events.wait(.failed, pitched)
        #expect(events.values.last?.error == SpeechOutputControlError.unsupportedPitch.localizedDescription)
        #expect(events.values.last?.controlError == .unsupportedPitch)
        #expect(await provider.generations == 0 && player.counts[0] == 0)
        let quieter = try await controller.start(request, options: .init(volume: 0.3))
        try await events.wait(.playing, quieter)
        #expect(player.volumes == [Float(0.3)])
        #expect(await controller.status()?.capabilities.canSetVolume == true)
        #expect(await controller.status()?.capabilities.canSetPitch == false)
        try await controller.stop(quieter)
        for advertised in [true, false] {
            let rejectedEvents = ControlEvents(), rejected = ControlPlayer(supportsVolume: advertised, acceptsVolume: false)
            let output = AppleSpeechOutputController(engine: TTSEngineManager(provider: provider),
                synthesizer: ControlSynthesizer(), playerFactory: { _ in rejected }, onEvent: rejectedEvents.append)
            let id = try await output.start(request, options: .init(volume: 0.4))
            try await rejectedEvents.wait(.failed, id)
            #expect(rejected.counts[0] == 0)
            #expect(rejectedEvents.values.last?.error == SpeechOutputControlError.unsupportedVolume.localizedDescription)
            #expect(rejectedEvents.values.last?.controlError == .unsupportedVolume)
            #expect(rejected.volumes.count == (advertised ? 1 : 0))
        }
    }

    @Test("System pause and resume retain the same utterance and acknowledge delegate events")
    func genuinePauseResume() async throws {
        let f = Fixture()
        let id = try await f.controller.start(f.request())
        try await f.playing(id)
        #expect(await f.controller.status()?.capabilities == .systemSpeech)
        #expect(try await f.controller.pause(id))
        #expect(await f.controller.status()?.phase == .playing) // accepted, not yet acknowledged
        await #expect(throws: SpeechOutputControlError.controlPending) { try await f.controller.resume(id) }
        f.sink.emit(.didPause, id)
        try await f.events.wait(.paused, id)
        #expect(try await f.controller.resume(id))
        f.sink.emit(.didContinue, id)
        try await f.events.wait(.resumed, id)
        #expect(f.sink.spoken.count == 1)
        #expect(f.sink.pauses == [id.generation] && f.sink.resumes == [id.generation])
        #expect(f.sink.stops.isEmpty, "pause/continue must not stop and re-synthesize")
        #expect(f.events.values.allSatisfy { $0.identity == id && $0.utf16Range == nil })
        try await f.controller.stop(id)
    }

    @Test("Rejected pause produces no false paused state, unsupported legacy sink stays unsupported")
    func rejectedAndUnsupported() async throws {
        let f = Fixture(sink: ControlSynthesizer(accept: false))
        let id = try await f.controller.start(f.request())
        try await f.playing(id)
        #expect(try await f.controller.pause(id) == false)
        #expect(await f.controller.status()?.phase == .playing)
        #expect(!f.events.values.contains { $0.phase == .paused })
        try await f.controller.stop(id)
        let legacy = Fixture(sink: ControlSynthesizer(capabilities: .unavailable))
        let old = try await legacy.controller.start(legacy.request())
        try await legacy.playing(old)
        await #expect(throws: SpeechOutputControlError.unsupported) { try await legacy.controller.pause(old) }
        await #expect(throws: SpeechOutputControlError.unsupported) { try await legacy.controller.seek(old, toUTF16Offset: 0) }
        try await legacy.controller.stop(old)
    }

    @Test("Ranges preserve original UTF-16 offsets through repeated seek-as-replacement")
    func unicodeSeek() async throws {
        let f = Fixture()
        let text = "Hi 👩🏽‍💻 e\u{301}lan 世界!"
        let original = f.request(text: text)
        let id = try await f.controller.start(original)
        try await f.playing(id)
        let word = (text as NSString).range(of: "e\u{301}lan")
        f.sink.emit(.willSpeakRange(.init(location: word.location, length: word.length)), id)
        try await f.events.wait(.wordRange, id)
        #expect(f.events.ranges(id) == [.init(location: word.location, length: word.length)])
        let sought = try await f.controller.seek(id, toUTF16Offset: word.location)
        #expect(sought.requestId == id.requestId && sought.generation != id.generation)
        try await f.playing(sought)
        #expect(f.sink.spoken.last?.text == "e\u{301}lan 世界!")
        f.sink.emit(.willSpeakRange(.init(location: 0, length: word.length)), sought)
        try await f.events.wait(.wordRange, sought)
        #expect(f.events.ranges(sought) == [.init(location: word.location, length: word.length)])
        let cjk = (text as NSString).range(of: "世界")
        let again = try await f.controller.seek(sought, toUTF16Offset: cjk.location)
        try await f.playing(again)
        #expect(f.sink.spoken.last?.text == "世界!")
        f.sink.emit(.willSpeakRange(.init(location: 0, length: 2)), again)
        try await f.events.wait(.wordRange, again)
        #expect(f.events.ranges(again) == [.init(location: cjk.location, length: 2)])
        #expect(await f.controller.status()?.startingAtUTF16Offset == cjk.location)
        #expect(await f.controller.status()?.originalTextUTF16Length == text.utf16.count)
        #expect(f.events.terminals(id) == 1 && f.events.terminals(sought) == 1)
        try await f.controller.cancel(again)
    }

    @Test("Invalid seek/ranges cannot split Unicode, overflow or mutate the active session")
    func invalidRanges() async throws {
        let f = Fixture()
        let text = "😀 e\u{301}lan "
        let id = try await f.controller.start(f.request(text: text))
        try await f.playing(id)
        for offset in [-1, 1, 4, text.utf16.count, Int.max, text.utf16.count - 1] {
            await #expect(throws: SpeechOutputControlError.invalidUTF16Offset) { try await f.controller.seek(id, toUTF16Offset: offset) }
            #expect(await f.controller.status()?.identity == id)
        }
        for range in [SpeechUTF16Range(location: -1, length: 1), .init(location: 0, length: 0),
                      .init(location: 0, length: Int.max), .init(location: Int.max, length: 1),
                      .init(location: 1, length: 1), .init(location: text.utf16.count, length: 1)] {
            f.sink.emit(.willSpeakRange(range), id)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.events.ranges(id).isEmpty)
        #expect(f.sink.spoken.count == 1)
        try await f.controller.stop(id)
    }

    @Test("Replacement, stop and cancel fence every old event and scoped control even with reused request IDs")
    func staleEventsAndControls() async throws {
        let f = Fixture()
        let request = f.request()
        let old = try await f.controller.start(request)
        try await f.playing(old)
        let current = try await f.controller.seek(old, toUTF16Offset: 1)
        try await f.playing(current)
        let before = f.events.values.count
        let wrong = SpeechOutputIdentity(requestId: "wrong-request", generation: current.generation)
        for stale in [old, wrong] {
            for kind: SystemSpeechEvent.Kind in [.didStart, .didFinish, .didCancel, .didPause, .didContinue, .willSpeakRange(.init(location: 0, length: 1))] {
                f.sink.emit(kind, stale)
            }
            await #expect(throws: SpeechOutputControlError.staleIdentity) { try await f.controller.pause(stale) }
            await #expect(throws: SpeechOutputControlError.staleIdentity) { try await f.controller.resume(stale) }
            await #expect(throws: SpeechOutputControlError.staleIdentity) { try await f.controller.stop(stale) }
            await #expect(throws: SpeechOutputControlError.staleIdentity) { try await f.controller.cancel(stale) }
            await #expect(throws: SpeechOutputControlError.staleIdentity) { try await f.controller.seek(stale, toUTF16Offset: 0) }
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.events.values.count == before)
        #expect(await f.controller.status()?.identity == current)
        #expect(!f.sink.stops.contains(current.generation))
        try await f.controller.cancel(current)
        for kind: SystemSpeechEvent.Kind in [.didPause, .didContinue, .willSpeakRange(.init(location: 0, length: 1)), .didFinish] {
            f.sink.emit(kind, current)
        }
        let next = try await f.controller.start(request)
        try await f.playing(next)
        try await f.controller.stop(next)
        f.sink.emit(.didFinish, next)
        try await Task.sleep(for: .milliseconds(30))
        #expect(f.events.terminals(current) == 1 && f.events.terminals(next) == 1)
        #expect(await f.controller.status() == nil)
    }

    @Test("A pause awaiting the sink cannot update replacement playback")
    func pendingPauseReplacement() async throws {
        let gate = ControlGate()
        let f = Fixture(sink: ControlSynthesizer(gate: gate))
        let old = try await f.controller.start(f.request())
        try await f.playing(old)
        let pending = Task { try await f.controller.pause(old) }
        while !(await gate.entered) { try await Task.sleep(for: .milliseconds(1)) }
        let next = try await f.controller.start(f.request(text: "Replacement"))
        try await f.playing(next)
        await gate.release()
        await #expect(throws: SpeechOutputControlError.staleIdentity) { try await pending.value }
        f.sink.emit(.didPause, old)
        try await Task.sleep(for: .milliseconds(20))
        #expect(await f.controller.status()?.identity == next)
        #expect(await f.controller.status()?.phase == .playing)
        try await f.controller.stop(next)
    }

    @Test("Generated audio pauses its retained player but never fabricates ranges or supports text seek")
    func generatedAudio() async throws {
        let events = ControlEvents(), player = ControlPlayer()
        let controller = AppleSpeechOutputController(engine: TTSEngineManager(provider: ReadoutProvider()),
            synthesizer: ControlSynthesizer(), playerFactory: { _ in player }, onEvent: events.append)
        let id = try await controller.start(SynthesisRequest(text: "Generated audio", modelId: "fixture"))
        try await events.wait(.playing, id)
        #expect(await controller.status()?.capabilities == .generatedAudio)
        #expect(try await controller.pause(id))
        #expect(await controller.status()?.phase == .paused)
        #expect(try await controller.resume(id))
        #expect(player.counts == [1, 1, 1, 0]) // play, pause, resume, stop
        await #expect(throws: SpeechOutputControlError.unsupported) { try await controller.seek(id, toUTF16Offset: 1) }
        #expect(events.values.allSatisfy { $0.utf16Range == nil && !$0.capabilities.canReportUTF16Ranges })
        #expect(events.values.allSatisfy { $0.identity == id })
        try await controller.stop(id)
    }
}

private struct Fixture {
    let sink: ControlSynthesizer
    let events = ControlEvents()
    let controller: AppleSpeechOutputController
    init(sink: ControlSynthesizer = ControlSynthesizer()) {
        self.sink = sink
        self.controller = AppleSpeechOutputController(engine: TTSEngineManager(provider: ReadoutProvider()),
            synthesizer: sink, onEvent: events.append)
    }
    func request(text: String = "Hello world") -> SynthesisRequest {
        SynthesisRequest(requestId: "readout", text: text, modelId: TTSDefaults.localModelId)
    }
    func playing(_ id: SpeechOutputIdentity) async throws {
        try await events.wait(.starting, id)
        sink.emit(.didStart, id)
        try await events.wait(.playing, id)
    }
}

private final class ControlEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SpeechOutputEvent] = []
    var values: [SpeechOutputEvent] { lock.withLock { stored } }
    func append(_ event: SpeechOutputEvent) { lock.withLock { stored.append(event) } }
    func ranges(_ id: SpeechOutputIdentity) -> [SpeechUTF16Range] { values.filter { $0.identity == id }.compactMap(\.utf16Range) }
    func terminals(_ id: SpeechOutputIdentity) -> Int { values.filter { $0.identity == id && [.finished, .cancelled, .failed].contains($0.phase) }.count }
    func wait(_ phase: SpeechOutputPhase, _ id: SpeechOutputIdentity) async throws {
        for _ in 0..<500 {
            if values.contains(where: { $0.phase == phase && $0.identity == id }) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw ReadoutFailure.timeout
    }
}

private enum ReadoutFailure: Error { case timeout }
private actor ControlGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class ControlSynthesizer: SystemSpeechSynthesizing, @unchecked Sendable {
    struct Spoken { let text: String; let id: SpeechOutputIdentity; let pitch: Float; let volume: Float }
    let playbackCapabilities: SpeechPlaybackCapabilities
    private let lock = NSLock()
    private let accept: Bool
    private let gate: ControlGate?
    private var callback: (@Sendable (SystemSpeechEvent) -> Void)?
    private var utterances: [Spoken] = [], pauseCalls: [UInt64] = [], resumeCalls: [UInt64] = [], stopCalls: [UInt64] = []
    var spoken: [Spoken] { lock.withLock { utterances } }
    var pauses: [UInt64] { lock.withLock { pauseCalls } }
    var resumes: [UInt64] { lock.withLock { resumeCalls } }
    var stops: [UInt64] { lock.withLock { stopCalls } }
    init(accept: Bool = true, capabilities: SpeechPlaybackCapabilities = .systemSpeech, gate: ControlGate? = nil) {
        self.accept = accept; self.playbackCapabilities = capabilities; self.gate = gate
    }
    func setCallback(_ callback: @escaping @Sendable (SystemSpeechEvent) -> Void) { lock.withLock { self.callback = callback } }
    func speak(_ utterance: AVSpeechUtterance, generation: UInt64, requestId: String) {
        lock.withLock { utterances.append(Spoken(text: utterance.speechString, id: .init(requestId: requestId, generation: generation), pitch: utterance.pitchMultiplier, volume: utterance.volume)) }
    }
    func stop(generation: UInt64) { lock.withLock { stopCalls.append(generation) } }
    func pause(generation: UInt64) async -> Bool {
        lock.withLock { pauseCalls.append(generation) }
        if let gate { await gate.wait() }
        return accept
    }
    func resume(generation: UInt64) async -> Bool { lock.withLock { resumeCalls.append(generation) }; return accept }
    func emit(_ kind: SystemSpeechEvent.Kind, _ id: SpeechOutputIdentity) {
        let cb = lock.withLock { callback }
        cb?(SystemSpeechEvent(kind: kind, generation: id.generation, requestId: id.requestId))
    }
}

private final class ControlPlayer: SpeechAudioPlaying, @unchecked Sendable {
    let playbackCapabilities: SpeechPlaybackCapabilities
    private let acceptsVolume: Bool
    private let lock = NSLock()
    private var stored = [0, 0, 0, 0]
    private var volumeCalls: [Float] = []
    var volumes: [Float] { lock.withLock { volumeCalls } }
    init(supportsVolume: Bool = true, acceptsVolume: Bool = true) {
        self.acceptsVolume = acceptsVolume
        self.playbackCapabilities = SpeechPlaybackCapabilities(canPauseResume: true, canSetVolume: supportsVolume)
    }
    func setVolume(_ volume: Float) -> Bool {
        lock.withLock { volumeCalls.append(volume) }
        return acceptsVolume
    }
    var counts: [Int] { lock.withLock { stored } }
    func attach(callback: @escaping @Sendable (SpeechAudioPlayerEvent) -> Void) {}
    func detach() {}
    func play() -> Bool { lock.withLock { stored[0] += 1 }; return true }
    func pause() -> Bool { lock.withLock { stored[1] += 1 }; return true }
    func resume() -> Bool { lock.withLock { stored[2] += 1 }; return true }
    func stop() { lock.withLock { stored[3] += 1 } }
}

private actor ReadoutProvider: TTSProvider {
    var generations = 0
    func models() -> [TTSModelInfo] { [.init(id: "fixture", name: "fixture", backend: "fixture", installed: true, preloaded: true, available: true)] }
    func voices(modelId: String?) -> [TTSVoiceInfo] { [] }
    func preload(modelId: String, voiceId: String?, progress: @escaping @Sendable (ModelProgress) -> Void) throws -> TTSModelInfo { throw ReadoutFailure.timeout }
    func synthesize(_ request: SynthesisRequest) -> SynthesisOutput {
        generations += 1
        return .init(modelId: "fixture", voiceId: "voice", format: "wav", contentType: "audio/wav", audioData: Data([0]), elapsedMs: 0,
              metrics: .init(traceId: "fixture", characterCount: request.text.count, audioDurationMs: 1, outputBytes: 1,
                             wasPreloaded: true, modelCheckMs: 0, modelLoadMs: 0, voiceResolveMs: 0, synthesisMs: 0, totalMs: 0))
    }
}
