import AVFoundation
import Foundation
import Testing
@testable import VoxAppleSpeech

@Suite(.serialized, .timeLimit(.minutes(1)))
struct ReadoutSinkTests {
    @Test("Production speech sink calls genuine pause/continue and carries metadata on range/pause events")
    func liveControls() async throws {
        let queue = ControlQueue(), engine = ControlSpeechEngine(), events = SinkEvents()
        let sink = AVSpeechSynthesizerSink(engine: engine, scheduler: queue)
        sink.setCallback(events.append)
        let utterance = AVSpeechUtterance(string: "Hello world")
        sink.speak(utterance, generation: 9, requestId: "original")
        queue.flush()
        let pause = Task { await sink.pause(generation: 9) }
        try await queue.waitForWork(); queue.flush()
        #expect(await pause.value)
        let resume = Task { await sink.resume(generation: 9) }
        try await queue.waitForWork(); queue.flush()
        #expect(await resume.value)
        #expect(engine.counts == [1, 1, 1, 0]) // speak, pause, continue, stop
        for kind: SystemSpeechEvent.Kind in [.didPause, .didContinue, .willSpeakRange(.init(location: 6, length: 5))] {
            sink.handleEngineEvent(kind, identifier: ObjectIdentifier(utterance))
        }
        #expect(events.values.map(\.kind) == [.didPause, .didContinue, .willSpeakRange(.init(location: 6, length: 5))])
        #expect(events.values.allSatisfy { $0.generation == 9 && $0.requestId == "original" })
        #expect(sink.playbackCapabilities == .systemSpeech)
    }

    @Test("Queued controls and late old-generation stop cannot affect a replacement")
    func staleQueuedControls() async throws {
        let queue = ControlQueue(), engine = ControlSpeechEngine()
        let sink = AVSpeechSynthesizerSink(engine: engine, scheduler: queue)
        let first = AVSpeechUtterance(string: "Old"), second = AVSpeechUtterance(string: "New")
        sink.speak(first, generation: 1, requestId: "same")
        queue.flush()
        let pause = Task { await sink.pause(generation: 1) }
        try await queue.waitForWork()
        sink.stop(generation: 1) // cancellation recorded before queued pause reaches AVFoundation
        sink.speak(second, generation: 2, requestId: "same")
        queue.flush()
        #expect(await pause.value == false)
        #expect(engine.counts == [2, 0, 0, 1])
        sink.stop(generation: 1) // old utterance metadata still awaits didCancel
        queue.flush()
        #expect(engine.counts == [2, 0, 0, 1], "A late old stop must not globally stop the new utterance")
        let resume = Task { await sink.resume(generation: 1) }
        try await queue.waitForWork(); queue.flush()
        #expect(await resume.value == false)
        #expect(sink.currentSpeakingGeneration == 2)
    }

    @Test("Production generated-audio sink pauses/resumes without prepare, stop, detach or new playback")
    func generatedControls() {
        let engine = ControlAudioEngine(), queue = InlineAudioQueue()
        let sink = AVAudioPlayerSink(engine: engine, scheduler: queue)
        #expect(sink.setVolume(0.25))
        for invalid: Float in [.nan, .infinity, -0.1, 1.1] { #expect(!sink.setVolume(invalid)) }
        #expect(engine.volumes == [0.25])
        #expect(sink.play())
        #expect(sink.pause())
        #expect(sink.resume())
        #expect(engine.counts == [1, 1, 1, 1, 0]) // prepare, play, pause, resume, stop
        #expect(sink.playbackCapabilities == .generatedAudio)
    }
}

private final class ControlQueue: SpeechWorkScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@Sendable () -> Void] = []
    func enqueue(_ item: @escaping @Sendable () -> Void) { lock.withLock { work.append(item) } }
    func flush() {
        let items = lock.withLock { let items = work; work.removeAll(); return items }
        for item in items { item() }
    }
    func waitForWork() async throws {
        for _ in 0..<500 {
            if lock.withLock({ !work.isEmpty }) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw SinkFailure.timeout
    }
}
private enum SinkFailure: Error { case timeout }
private final class ControlSpeechEngine: SpeechSynthesizerEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [0, 0, 0, 0]
    var counts: [Int] { lock.withLock { stored } }
    func speak(_ utterance: AVSpeechUtterance) { lock.withLock { stored[0] += 1 } }
    func pauseSpeaking() -> Bool { lock.withLock { stored[1] += 1 }; return true }
    func continueSpeaking() -> Bool { lock.withLock { stored[2] += 1 }; return true }
    func stopSpeaking() { lock.withLock { stored[3] += 1 } }
}
private final class SinkEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SystemSpeechEvent] = []
    var values: [SystemSpeechEvent] { lock.withLock { stored } }
    func append(_ value: SystemSpeechEvent) { lock.withLock { stored.append(value) } }
}
private final class InlineAudioQueue: AudioPlayerScheduling, @unchecked Sendable {
    func sync<T>(_ work: () -> T) -> T { work() }
    func async(_ work: @escaping @Sendable () -> Void) { work() }
}
private final class ControlAudioEngine: AudioPlayerEngine, @unchecked Sendable {
    var counts = [0, 0, 0, 0, 0]
    var volumes: [Float] = []
    func setVolume(_ volume: Float) -> Bool { volumes.append(volume); return true }
    func setEventHandler(_ handler: (@Sendable (SpeechAudioPlayerEvent) -> Void)?) {}
    func prepareToPlay() { counts[0] += 1 }
    func play() -> Bool { counts[1] += 1; return true }
    func pause() -> Bool { counts[2] += 1; return true }
    func resume() -> Bool { counts[3] += 1; return true }
    func stop() { counts[4] += 1 }
}
