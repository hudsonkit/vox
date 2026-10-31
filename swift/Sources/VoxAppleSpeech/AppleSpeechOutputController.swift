import AVFoundation
import Foundation
import VoxCore
import VoxEngine

/// Per-audible-surface speech output controller for Apple apps.
///
/// One instance owns one audible surface. There is no process-global playback
/// mutex. `TTSProvider` / `TTSEngineManager` stay generation-only; this type
/// composes the engine for generated-audio models and uses live
/// `AVSpeechSynthesizer.speak()` for `avspeech:system`.
public actor AppleSpeechOutputController {
    private let engine: TTSEngineManager
    private let synthesizer: any SystemSpeechSynthesizing
    private let playerFactory: SpeechAudioPlayerFactory
    private let audioSession: (any SpeechAudioSessionConfiguring)?
    private let preferredLanguages: [String]
    private let onEvent: (@Sendable (SpeechOutputEvent) -> Void)?
    private let lease: PlaybackLease

    private var nextGeneration: UInt64 = 1
    private var current: Session? {
        get { lease.current }
        set { lease.current = newValue }
    }

    public init(
        engine: TTSEngineManager = TTSEngineManager(),
        synthesizer: (any SystemSpeechSynthesizing)? = nil,
        playerFactory: @escaping SpeechAudioPlayerFactory = { try AVAudioPlayerSink.make($0) },
        audioSession: (any SpeechAudioSessionConfiguring)? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages,
        onEvent: (@Sendable (SpeechOutputEvent) -> Void)? = nil
    ) {
        let resolvedSynthesizer = synthesizer ?? AVSpeechSynthesizerSink()
        self.engine = engine
        self.synthesizer = resolvedSynthesizer
        self.playerFactory = playerFactory
        self.audioSession = audioSession
        self.preferredLanguages = preferredLanguages
        self.onEvent = onEvent
        self.lease = PlaybackLease(synthesizer: resolvedSynthesizer)

        resolvedSynthesizer.setCallback { [weak self] event in
            guard let self else { return }
            Task { await self.handleSystemSpeech(event) }
        }
    }

    deinit {
        lease.abandon()
    }

    /// Start speaking. A new request replaces any pending generation or playback.
    public func speak(_ request: SynthesisRequest) {
        _ = enqueue(request, startingAtUTF16Offset: 0)
    }

    /// Start with an identity for fenced controls. Text is never normalized.
    @discardableResult
    public func start(_ request: SynthesisRequest) throws -> SpeechOutputIdentity {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechOutputError.missingText }
        return enqueue(request, startingAtUTF16Offset: 0)
    }

    public func status() -> SpeechOutputStatus? {
        guard let session = current else { return nil }
        return SpeechOutputStatus(identity: session.identity, phase: session.phase, capabilities: session.capabilities,
                                  startingAtUTF16Offset: session.startingAtUTF16Offset,
                                  originalTextUTF16Length: session.originalTextUTF16Length)
    }

    /// Replace speech with a suffix of the ORIGINAL request. This is not audio-time seek.
    /// A new generation fences all old callbacks, even when requestId is unchanged.
    @discardableResult
    public func seek(_ identity: SpeechOutputIdentity, toUTF16Offset offset: Int) throws -> SpeechOutputIdentity {
        let session = try requireSession(identity)
        guard session.capabilities.canSeekByReplacement, session.synthesis.delivery == .liveSystem else {
            throw SpeechOutputControlError.unsupported
        }
        try validateOffset(offset, in: session.request.text)
        return enqueue(session.request, startingAtUTF16Offset: offset)
    }

    /// True pause/continue of the existing utterance/player, never stop/re-synthesis.
    /// For system speech true means accepted; paused/resumed events acknowledge it.
    @discardableResult
    public func pause(_ identity: SpeechOutputIdentity) async throws -> Bool {
        try await control(identity, pausing: true)
    }

    @discardableResult
    public func resume(_ identity: SpeechOutputIdentity) async throws -> Bool {
        try await control(identity, pausing: false)
    }

    public func stop(_ identity: SpeechOutputIdentity) throws {
        _ = try requireSession(identity)
        interruptCurrent(emitting: .cancelled)
    }

    public func cancel(_ identity: SpeechOutputIdentity) throws {
        _ = try requireSession(identity)
        interruptCurrent(emitting: .cancelled)
    }

    private func requireSession(_ identity: SpeechOutputIdentity) throws -> Session {
        guard let session = current, !session.cancelled, session.identity == identity else {
            throw SpeechOutputControlError.staleIdentity
        }
        return session
    }

    private func validateOffset(_ offset: Int, in text: String) throws {
        guard offset >= 0, offset < text.utf16.count,
              let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: offset, limitedBy: text.utf16.endIndex),
              let index = String.Index(utf16Index, within: text),
              text.indices.contains(index),
              !text[index...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechOutputControlError.invalidUTF16Offset
        }
    }

    private func control(_ identity: SpeechOutputIdentity, pausing: Bool) async throws -> Bool {
        let session = try requireSession(identity)
        guard session.capabilities.canPauseResume else { throw SpeechOutputControlError.unsupported }
        guard session.control == nil else { throw SpeechOutputControlError.controlPending }
        guard pausing ? (session.phase == .playing || session.phase == .resumed) : session.phase == .paused else {
            throw SpeechOutputControlError.notReady
        }
        let intent: Session.Control = pausing ? .pausing : .resuming
        session.control = intent
        switch session.synthesis.delivery {
        case .liveSystem:
            let accepted = pausing ? await synthesizer.pause(generation: identity.generation)
                : await synthesizer.resume(generation: identity.generation)
            _ = try requireSession(identity) // replacement/cancel while awaiting the sink
            if !accepted, session.control == intent { session.control = nil }
            return accepted
        case .generatedAudio:
            guard let player = session.player else { session.control = nil; throw SpeechOutputControlError.notReady }
            let accepted = pausing ? player.pause() : player.resume()
            session.control = nil
            if accepted { emit(pausing ? .paused : .resumed, for: session) }
            return accepted
        }
    }

    private func enqueue(_ request: SynthesisRequest, startingAtUTF16Offset offset: Int) -> SpeechOutputIdentity {
        interruptCurrent(emitting: .cancelled)

        let generation = nextGeneration
        nextGeneration += 1
        let session = Session(request: request, generation: generation, engine: engine, startingAtUTF16Offset: offset)
        current = session
        session.task = Task { [weak self] in
            do {
                try await self?.prepare(session)
                guard !session.cancelled else { return }
                switch session.synthesis.delivery {
                case .liveSystem:
                    try await self?.speakLive(session)
                case .generatedAudio:
                    await self?.emit(.generating, for: session)
                    let output = try await session.engine.synthesize(session.request)
                    guard !session.cancelled else { return }
                    try await self?.playGenerated(session, output: output)
                }
            } catch is CancellationError {
                await self?.finishIfActive(session.generation, phase: .cancelled)
            } catch {
                await self?.finishIfActive(
                    session.generation,
                    phase: .failed,
                    error: error.localizedDescription
                )
            }
        }
        return session.identity
    }

    /// Stop current generation and playback. Idempotent.
    public func stop() {
        interruptCurrent(emitting: .cancelled)
    }

    /// Cancel current generation and playback. Idempotent.
    ///
    /// For this controller, cancel has the same effect as stop: the in-flight
    /// `Task`, audio player, and system synthesizer are all terminated,
    /// including during the enqueue window.
    public func cancel() {
        interruptCurrent(emitting: .cancelled)
    }

    private func prepare(_ session: Session) async throws {
        guard !session.request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechOutputError.missingText
        }

        if let audioSession {
            do {
                try audioSession.prepareForSpeechOutput()
            } catch {
                throw SpeechOutputError.audioSessionFailed(error.localizedDescription)
            }
        }

        let models = await engine.models()
        guard isActive(session.generation) else { return }

        let model = models.first { $0.id == session.request.modelId }
        let delivery = SpeechOutputCapabilities.delivery(
            forModelId: session.request.modelId,
            backend: model?.backend
        )
        session.synthesis = SpeechSynthesisIdentity(
            requestedModelId: session.request.modelId,
            modelId: session.request.modelId,
            requestedVoiceId: session.request.voiceId,
            voiceId: session.request.voiceId,
            backend: model?.backend,
            delivery: delivery
        )
        session.audioOutput = SpeechOutputCapabilities.audioOutput(for: delivery)
        session.capabilities = delivery == .liveSystem ? synthesizer.playbackCapabilities : .unavailable
    }

    private func speakLive(_ session: Session) async throws {
        emit(.resolving, for: session)
        let voice = try resolveSystemVoice(voiceId: session.request.voiceId)
        guard isActive(session.generation) else { return }

        session.synthesis.voiceId = voice.identifier
        if session.synthesis.backend == nil {
            session.synthesis.backend = "avspeech"
        }

        let utterance = AVSpeechUtterance(string: session.spokenText)
        utterance.voice = voice
        utterance.prefersAssistiveTechnologySettings = false
        if let speed = session.request.speed {
            utterance.rate = SpeechOutputRate.map(
                speed: speed,
                minimum: AVSpeechUtteranceMinimumSpeechRate,
                defaultRate: AVSpeechUtteranceDefaultSpeechRate,
                maximum: AVSpeechUtteranceMaximumSpeechRate
            )
        }

        guard isActive(session.generation) else { return }
        emit(.starting, for: session)
        guard isActive(session.generation) else { return }
        synthesizer.speak(
            utterance,
            generation: session.generation,
            requestId: session.request.requestId
        )
    }

    private func playGenerated(_ session: Session, output: SynthesisOutput) async throws {
        guard isActive(session.generation) else { return }

        session.synthesis.modelId = output.modelId
        session.synthesis.voiceId = output.voiceId

        let player: any SpeechAudioPlaying
        do {
            player = try playerFactory(output.audioData)
        } catch {
            throw SpeechOutputError.playerFactoryFailed(error.localizedDescription)
        }

        let generation = session.generation
        player.attach { [weak self] event in
            guard let self else { return }
            Task { await self.handlePlayer(event, generation: generation) }
        }
        session.player = player
        // Generated audio has no word-range evidence in this sink contract.
        session.capabilities = SpeechPlaybackCapabilities(canPauseResume: player.playbackCapabilities.canPauseResume)
        emit(.starting, for: session)

        guard isActive(session.generation) else {
            detachPlayer(session)
            return
        }

        let started = player.play()
        if !isActive(session.generation) {
            detachPlayer(session)
            return
        }
        guard started else {
            detachPlayer(session)
            throw SpeechOutputError.playerFailedToStart
        }

        emit(.playing, for: session)
    }

    private func handleSystemSpeech(_ event: SystemSpeechEvent) {
        guard let session = current, !session.cancelled,
              session.identity == SpeechOutputIdentity(requestId: event.requestId, generation: event.generation) else {
            // Never let a mismatched requestId with a current generation stop it.
            if event.kind == .didStart, current?.generation != event.generation {
                synthesizer.stop(generation: event.generation)
            }
            return
        }
        switch event.kind {
        case .didStart:
            guard session.phase == .starting else { return }
            emit(.playing, for: session)
        case .didFinish:
            finishIfActive(event.generation, phase: .finished)
        case .didCancel:
            finishIfActive(event.generation, phase: .cancelled)
        case .didPause:
            guard session.control == .pausing else { return }
            session.control = nil
            emit(.paused, for: session)
        case .didContinue:
            guard session.control == .resuming else { return }
            session.control = nil
            emit(.resumed, for: session)
        case .willSpeakRange(let range):
            guard session.capabilities.canReportUTF16Ranges,
                  session.phase == .starting || session.phase == .playing || session.phase == .resumed,
                  session.control != .pausing,
                  session.accepts(range) else { return }
            let originalRange = SpeechUTF16Range(location: session.startingAtUTF16Offset + range.location, length: range.length)
            emit(.wordRange, for: session, utf16Range: originalRange)
        }
    }

    private func handlePlayer(_ event: SpeechAudioPlayerEvent, generation: UInt64) {
        switch event {
        case .didFinish:
            finishIfActive(generation, phase: .finished)
        case .didFail(let message):
            finishIfActive(generation, phase: .failed, error: SpeechOutputError.playerFailed(message).localizedDescription)
        }
    }

    private func interruptCurrent(emitting phase: SpeechOutputPhase) {
        guard let session = current else { return }
        abandon(session)
        emit(phase, for: session)
        current = nil
    }

    private func finishIfActive(
        _ generation: UInt64,
        phase: SpeechOutputPhase,
        error: String? = nil
    ) {
        guard isActive(generation), let session = current else { return }
        abandon(session)
        emit(phase, for: session, error: error)
        current = nil
    }

    private func abandon(_ session: Session) {
        session.cancelled = true
        session.task?.cancel()
        session.task = nil
        synthesizer.stop(generation: session.generation)
        detachPlayer(session)
    }

    private func detachPlayer(_ session: Session) {
        guard let player = session.player else { return }
        player.stop()
        player.detach()
        session.player = nil
    }

    private func isActive(_ generation: UInt64) -> Bool {
        guard let session = current else { return false }
        return session.generation == generation && !session.cancelled
    }

    private func emit(_ phase: SpeechOutputPhase, for session: Session, error: String? = nil, utf16Range: SpeechUTF16Range? = nil) {
        if phase != .wordRange { session.phase = phase }
        let event = SpeechOutputEvent(
            requestId: session.request.requestId,
            generation: session.generation,
            phase: phase,
            synthesis: session.synthesis,
            audioOutput: session.audioOutput,
            error: error,
            utf16Range: utf16Range,
            capabilities: session.capabilities
        )
        onEvent?(event)
    }

    private func resolveSystemVoice(voiceId: String?) throws -> AVSpeechSynthesisVoice {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let descriptors = voices.map {
            SystemVoiceDescriptor(identifier: $0.identifier, language: $0.language)
        }
        let picked = try SystemVoiceResolver.resolve(
            voiceId: voiceId,
            voices: descriptors,
            preferredLanguages: preferredLanguages
        )
        if let voice = voices.first(where: { $0.identifier == picked.identifier }) {
            return voice
        }
        throw SpeechOutputError.unsupportedVoice(picked.identifier)
    }
}

private final class PlaybackLease: @unchecked Sendable {
    private let lock = NSLock()
    private let synthesizer: any SystemSpeechSynthesizing
    private var session: Session?

    init(synthesizer: any SystemSpeechSynthesizing) {
        self.synthesizer = synthesizer
    }

    var current: Session? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return session
        }
        set {
            lock.lock()
            session = newValue
            lock.unlock()
        }
    }

    func abandon() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        guard let session else { return }
        session.cancelled = true
        session.task?.cancel()
        session.task = nil
        session.player?.stop()
        session.player?.detach()
        session.player = nil
        synthesizer.stop(generation: session.generation)
    }

    deinit {
        abandon()
    }
}

private final class Session: @unchecked Sendable {
    enum Control { case pausing, resuming }
    var control: Control?
    var phase: SpeechOutputPhase = .resolving
    var capabilities: SpeechPlaybackCapabilities = .unavailable
    let startingAtUTF16Offset: Int
    var identity: SpeechOutputIdentity { SpeechOutputIdentity(requestId: request.requestId, generation: generation) }
    let spokenText: String
    private let spokenUTF16: [UInt16]
    let originalTextUTF16Length: Int
    let request: SynthesisRequest
    let generation: UInt64
    let engine: TTSEngineManager
    private let lock = NSLock()
    private var _cancelled = false
    var task: Task<Void, Never>?
    var player: (any SpeechAudioPlaying)?
    var synthesis: SpeechSynthesisIdentity
    var audioOutput: SpeechAudioOutputRoute

    func accepts(_ range: SpeechUTF16Range) -> Bool {
        guard range.location >= 0, range.length > 0,
              range.location <= spokenUTF16.count,
              range.length <= spokenUTF16.count - range.location else { return false }
        // Foundation's NSRange conversion can accept an index inside a surrogate
        // pair. Check scalar boundaries explicitly before exposing a highlight.
        func boundary(_ offset: Int) -> Bool {
            offset == spokenUTF16.count || !(0xDC00...0xDFFF).contains(spokenUTF16[offset])
        }
        return boundary(range.location) && boundary(range.location + range.length)
    }

    var cancelled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _cancelled
        }
        set {
            lock.lock()
            _cancelled = newValue
            lock.unlock()
        }
    }

    init(request: SynthesisRequest, generation: UInt64, engine: TTSEngineManager, startingAtUTF16Offset: Int) {
        self.startingAtUTF16Offset = startingAtUTF16Offset
        let spokenText = String(request.text[String.Index(utf16Offset: startingAtUTF16Offset, in: request.text)...])
        self.spokenText = spokenText
        self.spokenUTF16 = Array(spokenText.utf16)
        self.originalTextUTF16Length = request.text.utf16.count
        self.request = request
        self.generation = generation
        self.engine = engine
        let capability = SpeechOutputCapabilities.capability(forModelId: request.modelId)
        self.synthesis = SpeechSynthesisIdentity(
            requestedModelId: request.modelId,
            modelId: request.modelId,
            requestedVoiceId: request.voiceId,
            voiceId: request.voiceId,
            delivery: capability.delivery
        )
        self.audioOutput = capability.audioOutput
    }
}
