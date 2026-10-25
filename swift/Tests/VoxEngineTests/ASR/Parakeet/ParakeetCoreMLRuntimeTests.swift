import Foundation
import Testing
import VoxCore
@testable import HudsonSpeechEngine

@Suite(.timeLimit(.minutes(1)))
struct ParakeetCoreMLRuntimeTests {
    @Test("Warmup and overlapping transcriptions share initialization and wait for priming")
    func overlappingWarmupAndTranscriptions() async throws {
        let events = RuntimeEvents()
        let progress = RuntimeProgress()
        let probe = SessionProbe()
        let runtime = ParakeetCoreMLRuntime(
            loadSession: { _ in try await probe.load() },
            observeEvent: { events.record($0) }
        )
        let directory = URL(fileURLWithPath: "/unused-model-fixture")
        let warmup = Task { try await runtime.load(from: directory) { progress.record($0, caller: "warmup") } }
        await probe.waitForFirstLoad()
        let first = Task {
            try await runtime.load(from: directory) { progress.record($0, caller: "first") }
            return try await runtime.transcribe(samples: [1])
        }
        let second = Task {
            try await runtime.load(from: directory) { progress.record($0, caller: "second") }
            return try await runtime.transcribe(samples: [2])
        }
        await events.waitForLoadDecisions(3)
        #expect(events.count(.loadStarted) == 1)
        await probe.releaseLoading()
        await probe.waitForPriming()
        let direct = Task { try await runtime.transcribe(samples: [3]) }
        await events.waitFor(.transcriptionJoinedLoad)
        let lateWarmup = Task {
            try await runtime.load(from: directory) { progress.record($0, caller: "late") }
        }
        await events.waitForLoadDecisions(4)
        #expect(await runtime.isPreloaded() == false)
        #expect(events.count(.ready) == 0)
        #expect(await probe.transcriptionCount == 0)
        for caller in ["warmup", "first", "second", "late"] {
            #expect(progress.statuses(caller).last == "warming")
        }
        await probe.releasePriming()
        try await warmup.value
        #expect(try await first.value.text == "1")
        #expect(try await second.value.text == "2")
        #expect(try await direct.value.text == "3")
        try await lateWarmup.value
        #expect(await probe.loadCount == 1)
        #expect(await probe.primeCount == 1)
        #expect(await runtime.isPreloaded())
        for caller in ["warmup", "first", "second", "late"] {
            #expect(progress.statuses(caller).filter { $0 == "ready" }.count == 1)
        }
        events.printTrace(label: "overlapping-warmup-transcribe")
    }

    @Test("A failed shared load reaches every waiter and can be retried")
    func failedFlightCanBeRetried() async throws {
        let events = RuntimeEvents()
        let probe = SessionProbe(failedLoads: 1)
        let runtime = ParakeetCoreMLRuntime(
            loadSession: { _ in try await probe.load() },
            observeEvent: { events.record($0) }
        )
        let directory = URL(fileURLWithPath: "/unused-model-fixture")
        let warmup = Task { try await runtime.load(from: directory) { _ in } }
        await probe.waitForFirstLoad()
        let joined = Task { try await runtime.load(from: directory) { _ in } }
        await events.waitForLoadDecisions(2)
        await probe.releaseLoading()
        await #expect(throws: FixtureError.self) { try await warmup.value }
        await #expect(throws: FixtureError.self) { try await joined.value }
        #expect(await runtime.isPreloaded() == false)
        #expect(events.count(.loadFailed) == 1)
        await probe.releasePriming()
        try await runtime.load(from: directory) { _ in }
        #expect(await probe.loadCount == 2)
        #expect(await probe.primeCount == 1)
        #expect(await runtime.isPreloaded())
        events.printTrace(label: "failed-flight-retry")
    }

    @Test("Canceling the initiating waiter does not cancel shared initialization")
    func canceledWaiterDoesNotPoisonFlight() async throws {
        let events = RuntimeEvents()
        let probe = SessionProbe()
        let runtime = ParakeetCoreMLRuntime(
            loadSession: { _ in try await probe.load() },
            observeEvent: { events.record($0) }
        )
        let directory = URL(fileURLWithPath: "/unused-model-fixture")
        let warmup = Task { try await runtime.load(from: directory) { _ in } }
        await probe.waitForFirstLoad()
        let joined = Task { try await runtime.load(from: directory) { _ in } }
        await events.waitForLoadDecisions(2)
        warmup.cancel()
        await probe.releaseLoading()
        await probe.waitForPriming()
        #expect(await runtime.isPreloaded() == false)
        await probe.releasePriming()
        await #expect(throws: CancellationError.self) { try await warmup.value }
        try await joined.value
        try await runtime.load(from: directory) { _ in }
        #expect(try await runtime.transcribe(samples: [4]).text == "4")
        #expect(await probe.loadCount == 1)
        #expect(await probe.primeCount == 1)
        #expect(events.count(.loadFailed) == 0)
        events.printTrace(label: "canceled-waiter")
    }

    @Test("Priming errors remain best effort and do not discard loaded models")
    func primingFailurePreservesLoadedSession() async throws {
        let probe = SessionProbe(failPriming: true)
        await probe.releaseLoading()
        await probe.releasePriming()
        let runtime = ParakeetCoreMLRuntime(loadSession: { _ in try await probe.load() }, observeEvent: { _ in })
        try await runtime.load(from: URL(fileURLWithPath: "/unused-model-fixture")) { _ in }
        #expect(await runtime.isPreloaded())
        #expect(try await runtime.transcribe(samples: [5]).text == "5")
        #expect(await probe.loadCount == 1)
    }

    @Test("A runtime with no initialization flight rejects transcription")
    func uninitializedTranscriptionFails() async {
        let probe = SessionProbe()
        let runtime = ParakeetCoreMLRuntime(loadSession: { _ in try await probe.load() }, observeEvent: { _ in })
        await #expect(throws: Error.self) { try await runtime.transcribe(samples: [1]) }
        #expect(await probe.loadCount == 0)
    }

    @Test("A ready session preserves concurrent transcription")
    func readySessionAllowsConcurrentTranscription() async throws {
        let probe = SessionProbe(gateTranscriptions: true)
        await probe.releaseLoading()
        await probe.releasePriming()
        let runtime = ParakeetCoreMLRuntime(loadSession: { _ in try await probe.load() }, observeEvent: { _ in })
        try await runtime.load(from: URL(fileURLWithPath: "/unused-model-fixture")) { _ in }
        let first = Task { try await runtime.transcribe(samples: [6]) }
        let second = Task { try await runtime.transcribe(samples: [7]) }
        await probe.waitForTwoTranscriptions()
        #expect(await probe.transcriptionCount == 2)
        await probe.releaseTranscriptions()
        #expect(try await first.value.text == "6")
        #expect(try await second.value.text == "7")
    }
}

private enum FixtureError: Error { case load, prime }

private actor SessionProbe {
    private(set) var loadCount = 0
    private(set) var primeCount = 0
    private(set) var transcriptionCount = 0
    private var loadingReleased = false
    private var primingReleased = false
    private var loadingWaiters: [CheckedContinuation<Void, Never>] = []
    private var primingWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstLoadWaiter: CheckedContinuation<Void, Never>?
    private var firstPrimeWaiter: CheckedContinuation<Void, Never>?
    private var failedLoads: Int
    private let failPriming: Bool
    private var gateTranscriptions: Bool
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []
    private var twoTranscriptionsWaiter: CheckedContinuation<Void, Never>?

    init(failedLoads: Int = 0, failPriming: Bool = false, gateTranscriptions: Bool = false) {
        self.failedLoads = failedLoads
        self.failPriming = failPriming
        self.gateTranscriptions = gateTranscriptions
    }

    func load() async throws -> ParakeetCoreMLRuntime.Session {
        loadCount += 1
        firstLoadWaiter?.resume()
        firstLoadWaiter = nil
        if !loadingReleased {
            await withCheckedContinuation { loadingWaiters.append($0) }
        }
        if failedLoads > 0 {
            failedLoads -= 1
            throw FixtureError.load
        }
        return ParakeetCoreMLRuntime.Session { samples in
            try await self.transcribe(samples)
        }
    }

    private func transcribe(_ samples: [Float]) async throws -> ParakeetInferenceResult {
        if samples.count > ParakeetConstants.maxModelSamples {
            primeCount += 1
            firstPrimeWaiter?.resume()
            firstPrimeWaiter = nil
            if !primingReleased {
                await withCheckedContinuation { primingWaiters.append($0) }
            }
            if failPriming { throw FixtureError.prime }
            return ParakeetInferenceResult(text: "prime", words: [])
        }
        transcriptionCount += 1
        if transcriptionCount >= 2 {
            twoTranscriptionsWaiter?.resume()
            twoTranscriptionsWaiter = nil
        }
        if gateTranscriptions {
            await withCheckedContinuation { transcriptionWaiters.append($0) }
        }
        return ParakeetInferenceResult(text: String(Int(samples[0])), words: [])
    }

    func waitForFirstLoad() async {
        if loadCount == 0 {
            await withCheckedContinuation { firstLoadWaiter = $0 }
        }
    }

    func waitForPriming() async {
        if primeCount == 0 {
            await withCheckedContinuation { firstPrimeWaiter = $0 }
        }
    }

    func releaseLoading() {
        loadingReleased = true
        let waiters = loadingWaiters
        loadingWaiters = []
        waiters.forEach { $0.resume() }
    }

    func releasePriming() {
        primingReleased = true
        let waiters = primingWaiters
        primingWaiters = []
        waiters.forEach { $0.resume() }
    }

    func waitForTwoTranscriptions() async {
        if transcriptionCount < 2 {
            await withCheckedContinuation { twoTranscriptionsWaiter = $0 }
        }
    }

    func releaseTranscriptions() {
        gateTranscriptions = false
        let waiters = transcriptionWaiters
        transcriptionWaiters = []
        waiters.forEach { $0.resume() }
    }
}

private final class RuntimeEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ParakeetCoreMLRuntime.Event] = []
    private var waiters: [([ParakeetCoreMLRuntime.Event], Int, CheckedContinuation<Void, Never>)] = []

    func record(_ event: ParakeetCoreMLRuntime.Event) {
        lock.lock()
        events.append(event)
        let ready = waiters.filter { waiter in events.filter { waiter.0.contains($0) }.count >= waiter.1 }
        waiters.removeAll { waiter in events.filter { waiter.0.contains($0) }.count >= waiter.1 }
        lock.unlock()
        ready.forEach { $0.2.resume() }
    }

    func count(_ event: ParakeetCoreMLRuntime.Event) -> Int {
        lock.withLock { events.filter { $0 == event }.count }
    }

    func waitForLoadDecisions(_ count: Int) async {
        await waitFor([.loadStarted, .loadJoined], count: count)
    }

    func waitFor(_ event: ParakeetCoreMLRuntime.Event) async {
        await waitFor([event], count: 1)
    }

    private func waitFor(_ matching: [ParakeetCoreMLRuntime.Event], count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let decisions = events.filter { matching.contains($0) }.count
            if decisions >= count {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append((matching, count, continuation))
                lock.unlock()
            }
        }
    }

    func printTrace(label: String) {
        let trace = lock.withLock { events.map(\.rawValue) }
        print("PARAKEET_RUNTIME_TRACE \(label): \(trace.joined(separator: ","))")
    }
}

private final class RuntimeProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var callers: [String: [String]] = [:]

    func record(_ progress: ModelProgress, caller: String) {
        lock.withLock { callers[caller, default: []].append(progress.status) }
    }

    func statuses(_ caller: String) -> [String] {
        lock.withLock { callers[caller, default: []] }
    }
}
