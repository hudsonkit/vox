import Foundation
import VoxCore
import HudsonSpeechEngine

public final class VoxRuntimeService: @unchecked Sendable {
    private let log = VoxLog.service
    private let port: UInt16
    private let socketPath: String?
    private let authToken: String?
    private let privateCapabilityURL: URL?
    private var privateRegistration: PrivateRuntimeRegistration?
    private let bridge: ServiceBridge
    private let asrEngine: EngineManager
    private let annotationEngine: AnnotationManager
    private let ttsEngine: TTSEngineManager
    private let warmup: WarmupCoordinator
    private let performance = PerformanceRecorder()
    private let history: SpeechHistoryRecorder
    private let recorder = MicrophoneFileRecorder()
    private let sessions = LiveSessionCoordinator()
    private let streamingSessions = StreamingSessionCoordinator()
    private let synthesisSessions = SynthesisSessionCoordinator()
    private let startedAt = Date()
    private let preferencesLoader: @Sendable () -> VoxPreferences
    private let defaultSynthesisModelId: String
    private let annotationTasks = ConnectionRequestTasks()
    private let synthesisTasks = ConnectionRequestTasks()

    public init(
        port: UInt16 = VoxDefaults.daemonPort,
        bindAddress: String = VoxDefaults.host,
        engine: EngineManager = EngineManager(),
        annotationEngine: AnnotationManager = AnnotationManager(),
        ttsEngine: TTSEngineManager = TTSEngineManager(),
        history: SpeechHistoryRecorder = SpeechHistoryRecorder(),
        defaultSynthesisModelId: String = TTSDefaults.modelId,
        authToken: String? = nil,
        socketPath: String? = nil,
        privateCapabilityURL: URL? = nil,
        preferencesLoader: @escaping @Sendable () -> VoxPreferences = {
            (try? VoxPreferences.load()) ?? VoxPreferences()
        }
    ) {
        self.port = socketPath == nil ? port : 0
        self.socketPath = socketPath
        self.authToken = authToken
        self.privateCapabilityURL = privateCapabilityURL
        self.bridge = ServiceBridge(port: port, serviceName: "Vox", bindAddress: bindAddress, authToken: authToken, socketPath: socketPath)
        self.asrEngine = engine
        self.annotationEngine = annotationEngine
        self.ttsEngine = ttsEngine
        self.history = history
        self.warmup = WarmupCoordinator(asrEngine: engine, ttsEngine: ttsEngine)
        self.preferencesLoader = preferencesLoader
        self.defaultSynthesisModelId = defaultSynthesisModelId
    }

    public func start() throws {
        registerHandlers()
        try bridge.start()
        let runtime = RuntimeInfo(
            version: VoxVersion.current,
            serviceName: "Vox",
            port: port,
            pid: getpid(),
            startedAt: startedAt,
            socketPath: socketPath
        )
        do {
            if socketPath != nil {
                guard let authToken else { throw POSIXError(.EACCES) }
                privateRegistration = try PrivateRuntimeRegistration(runtime: runtime, authToken: authToken,
                    url: privateCapabilityURL ?? RuntimePaths.runtimeFileURL())
            } else { try RuntimeRegistry.write(runtime) }
        } catch {
            bridge.stop()
            throw error
        }

        let speechPreferences = preferencesLoader().speech
        if speechPreferences.modelDownloadPolicy.warmsAtServiceStart {
            let modelId = resolveTranscriptionModelId(speechPreferences.preferredTranscriptionModelId)
            Task { [warmup] in
                _ = await warmup.start(modelId: modelId, requestedBy: "service-start")
            }
        }
    }

    public func stop() {
        annotationTasks.cancelAll()
        synthesisTasks.cancelAll()
        bridge.stop()
        Task { await streamingSessions.shutdown() }
        if socketPath != nil { privateRegistration?.invalidate(); privateRegistration = nil }
        else { try? RuntimeRegistry.remove() }
    }

    func performSynthesizeGenerate(params: [String: Any]?) async throws -> SynthesisOutput {
        let text = (params?["text"] as? String) ?? ""
        let requestedModelId = params?["modelId"] as? String
        let requestedVoiceId = params?["voiceId"] as? String
        let modelId = resolveSynthesisModelId(requestedModelId)
        let voiceId = resolveSynthesisVoiceId(
            requestedVoiceId,
            resolvedModelId: modelId,
            requestedModelId: requestedModelId
        )
        let format = (params?["format"] as? String) ?? TTSDefaults.format
        let speed = params?["speed"] as? Double
        let instructions = params?["instructions"] as? String
        let providerCredentials = providerCredentials(from: params)
        let speechTimingRequest = parseSpeechTimingRequest(params: params, text: text)

        return try await performSynthesizeGenerate(
            request: SynthesisRequest(
                text: text,
                modelId: modelId,
                voiceId: voiceId,
                format: format,
                speed: speed,
                instructions: instructions,
                providerCredentials: providerCredentials
            ),
            speechTimingRequest: speechTimingRequest
        )
    }

    func performSynthesizeVoices(params: [String: Any]?) async throws -> [TTSVoiceInfo] {
        try await performSynthesizeVoices(modelId: params?["modelId"] as? String,
            providerCredentials: providerCredentials(from: params))
    }

    func performSynthesizeModels() async -> [TTSModelInfo] {
        await ttsEngine.models()
    }

    func performModelsInstall(
        params: [String: Any]?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        let modelId = resolveTranscriptionModelId(params?["modelId"] as? String)
        return try await performModelsInstall(modelId: modelId, progress: progress)
    }

    func performModelsInstall(
        modelId: String,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        try await asrEngine.install(modelId: modelId, progress: progress)
    }

    func performModelsPreload(
        params: [String: Any]?,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        let modelId = resolveTranscriptionModelId(params?["modelId"] as? String)
        return try await performModelsPreload(modelId: modelId, progress: progress)
    }

    func performModelsPreload(
        modelId: String,
        progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> ASRModelInfo {
        try await asrEngine.preload(modelId: modelId, progress: progress)
    }

    func performWarmupStatus(params: [String: Any]?) async -> WarmupStatus {
        let modelId = resolveTranscriptionModelId(params?["modelId"] as? String)
        let requestedBy = params?["clientId"] as? String
        return await performWarmupStatus(modelId: modelId, requestedBy: requestedBy)
    }

    func performWarmupStatus(modelId: String, requestedBy: String?) async -> WarmupStatus {
        await warmup.status(modelId: modelId, requestedBy: requestedBy)
    }

    func performWarmupStart(params: [String: Any]?) async -> WarmupStatus {
        let modelId = resolveTranscriptionModelId(params?["modelId"] as? String)
        let requestedBy = params?["clientId"] as? String
        return await performWarmupStart(modelId: modelId, requestedBy: requestedBy)
    }

    func performWarmupStart(modelId: String, requestedBy: String?) async -> WarmupStatus {
        await warmup.start(modelId: modelId, requestedBy: requestedBy)
    }

    func performWarmupSchedule(params: [String: Any]?) async -> WarmupStatus {
        let modelId = resolveTranscriptionModelId(params?["modelId"] as? String)
        let requestedBy = params?["clientId"] as? String
        let delayMs = max((params?["delayMs"] as? Int) ?? 0, 0)
        return await performWarmupSchedule(modelId: modelId, delayMs: delayMs, requestedBy: requestedBy)
    }

    func performWarmupSchedule(modelId: String, delayMs: Int, requestedBy: String?) async -> WarmupStatus {
        await warmup.schedule(modelId: modelId, delayMs: delayMs, requestedBy: requestedBy)
    }

    func performTranscribeFile(params: [String: Any]?) async throws -> ASRRouteTranscriptionResult {
        guard let path = params?["path"] as? String else {
            throw NSError(domain: "VoxService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing path"
            ])
        }

        let modelId = resolveTranscriptionModelId(params?["modelId"] as? String)
        let clientId = (params?["clientId"] as? String) ?? "unknown"
        return try await performTranscribeFile(path: path, modelId: modelId, clientId: clientId)
    }

    func performTranscribeFile(path: String, modelId: String, clientId: String) async throws -> ASRRouteTranscriptionResult {
        let output = try await asrEngine.transcribe(url: URL(fileURLWithPath: path), modelId: modelId)
        let sample = PerformanceSample(
            clientId: clientId,
            route: "transcribe.file",
            modelId: modelId,
            outcome: "ok",
            textLength: output.text.count,
            metrics: output.metrics.performanceMetrics
        )
        return ASRRouteTranscriptionResult(output: output, performanceSample: sample)
    }

    func performAnnotateFile(params: [String: Any]?) async throws -> AnnotationRouteResult {
        guard let path = params?["path"] as? String else {
            throw NSError(domain: "VoxService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing path"
            ])
        }

        let modelId = (params?["modelId"] as? String) ?? "speaker-diarization:v1"
        let clientId = (params?["clientId"] as? String) ?? "unknown"
        let text = params?["text"] as? String
        let words = parseAnnotationWords(params?["words"] as? [[String: Any]])

        return try await performAnnotateFile(
            path: path,
            modelId: modelId,
            clientId: clientId,
            text: text,
            words: words,
            providerCredentials: AnnotationLentCredentials.parse(from: params),
            diarize: params?["diarize"] as? Bool ?? true,
            tagAudioEvents: params?["tagAudioEvents"] as? Bool,
            languageCode: params?["languageCode"] as? String,
            numSpeakers: params?["numSpeakers"] as? Int
        )
    }

    func performAnnotateFile(
        path: String,
        modelId: String,
        clientId: String,
        text: String?,
        words: [WordTiming]?,
        providerCredentials: [String: String] = [:], diarize: Bool = true,
        tagAudioEvents: Bool? = nil, languageCode: String? = nil, numSpeakers: Int? = nil
    ) async throws -> AnnotationRouteResult {
        let transcription: AnnotationInputTranscription? = {
            guard text != nil || words != nil else { return nil }
            return AnnotationInputTranscription(text: text ?? "", words: words ?? [])
        }()

        let request = AnnotationRequest(
            url: URL(fileURLWithPath: path),
            modelId: modelId,
            transcription: transcription, providerCredentials: providerCredentials,
            diarize: diarize, tagAudioEvents: tagAudioEvents, languageCode: languageCode, numSpeakers: numSpeakers
        )
        let output = try await annotationEngine.annotate(request: request)
        let sample = PerformanceSample(
            clientId: clientId,
            route: "annotate.file",
            modelId: modelId,
            outcome: "ok",
            textLength: output.text?.count ?? 0,
            metrics: output.metrics.performanceMetrics
        )
        return AnnotationRouteResult(output: output, performanceSample: sample)
    }

    private func parseAnnotationWords(_ rawWords: [[String: Any]]?) -> [WordTiming]? {
        rawWords?.compactMap { entry in
            guard let word = entry["word"] as? String, !word.isEmpty else {
                return nil
            }

            let confidence: Float
            if let floatConfidence = entry["confidence"] as? Float {
                confidence = floatConfidence
            } else if let doubleConfidence = entry["confidence"] as? Double {
                confidence = Float(doubleConfidence)
            } else if let intConfidence = entry["confidence"] as? Int {
                confidence = Float(intConfidence)
            } else {
                confidence = 0
            }

            return WordTiming(
                word: word,
                start: entry["start"] as? Double ?? 0,
                end: entry["end"] as? Double ?? 0,
                confidence: confidence
            )
        }
    }

    private func performSynthesizeGenerate(
        request: SynthesisRequest,
        speechTimingRequest: SpeechTimingRequest? = nil
    ) async throws -> SynthesisOutput {
        let output = try await ttsEngine.synthesize(request)
        guard let speechTimingRequest else {
            return output
        }

        guard let speechTiming = await generateSpeechTiming(
            output: output,
            request: request,
            timingRequest: speechTimingRequest
        ) else {
            return output
        }

        return SynthesisOutput(
            modelId: output.modelId,
            voiceId: output.voiceId,
            format: output.format,
            contentType: output.contentType,
            audioData: output.audioData,
            elapsedMs: output.elapsedMs,
            metrics: output.metrics,
            speechTiming: speechTiming
        )
    }

    private func performSynthesizeVoices(modelId: String?, providerCredentials: [String: String] = [:]) async throws -> [TTSVoiceInfo] {
        guard providerCredentials.isEmpty || modelId != nil else { throw TTSVoiceCredentialsError.modelRequired }
        return try await ttsEngine.voices(modelId: modelId, providerCredentials: providerCredentials)
    }

    private func currentPreferences() -> VoxPreferences {
        preferencesLoader()
    }

    private func resolveTranscriptionModelId(_ requestedModelId: String?) -> String {
        let normalizedRequestedModelId = normalizePreferenceValue(requestedModelId)
        if let normalizedRequestedModelId {
            return normalizedRequestedModelId
        }

        let preferences = currentPreferences()
        return normalizePreferenceValue(preferences.speech.preferredTranscriptionModelId) ?? "parakeet:v3"
    }

    private func requireInstalledModelWhenDownloadsAreDisabled(modelId: String) async throws {
        guard currentPreferences().speech.modelDownloadPolicy == .never else { return }

        let models = await asrEngine.models()
        let model = models.first { $0.id == modelId }
        guard model?.installed == true else {
            throw NSError(domain: "VoxService", code: 12, userInfo: [
                NSLocalizedDescriptionKey:
                    "model_download_disabled: \(modelId) is not installed; choose an automatic download policy or install it explicitly"
            ])
        }
    }

    private func resolveSynthesisModelId(_ requestedModelId: String?) -> String {
        let normalizedRequestedModelId = normalizePreferenceValue(requestedModelId)
        if let normalizedRequestedModelId {
            return normalizedRequestedModelId
        }

        let preferences = currentPreferences()
        return normalizePreferenceValue(preferences.speech.preferredSynthesisModelId) ?? defaultSynthesisModelId
    }

    private func resolveSynthesisVoiceId(
        _ requestedVoiceId: String?,
        resolvedModelId: String,
        requestedModelId: String?
    ) -> String? {
        if let requestedVoiceId = normalizePreferenceValue(requestedVoiceId) {
            return requestedVoiceId
        }

        let preferences = currentPreferences()
        let preferredVoiceId = normalizePreferenceValue(preferences.speech.preferredSynthesisVoiceId)
        guard let preferredVoiceId else {
            return nil
        }

        let preferredModelId = normalizePreferenceValue(preferences.speech.preferredSynthesisModelId) ?? defaultSynthesisModelId
        let normalizedRequestedModelId = normalizePreferenceValue(requestedModelId)

        // Only apply the user-level voice default when the resolved model matches
        // the voice's preferred model. Explicit model overrides keep provider defaults.
        guard resolvedModelId == preferredModelId,
              normalizedRequestedModelId == nil || normalizedRequestedModelId == preferredModelId
        else {
            return nil
        }

        return preferredVoiceId
    }

    private func normalizePreferenceValue(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func historyListFilter(from params: [String: Any]?) -> SpeechHistoryListFilter {
        let limit = intParam(params?["limit"]) ?? 50
        return SpeechHistoryListFilter(
            kind: speechHistoryKind(params?["kind"] as? String),
            source: speechHistorySource(params?["source"] as? String),
            clientId: normalizePreferenceValue(params?["clientId"] as? String),
            modelId: normalizePreferenceValue(params?["modelId"] as? String),
            sessionId: normalizePreferenceValue(params?["sessionId"] as? String),
            outcome: normalizePreferenceValue(params?["outcome"] as? String),
            query: normalizePreferenceValue(params?["query"] as? String),
            before: normalizePreferenceValue(params?["before"] as? String),
            limit: limit
        )
    }

    private func speechHistoryKind(_ raw: String?) -> SpeechHistoryKind? {
        guard let raw = normalizePreferenceValue(raw) else { return nil }
        return SpeechHistoryKind(rawValue: raw)
    }

    private func speechHistorySource(_ raw: String?) -> SpeechHistorySource? {
        guard let raw = normalizePreferenceValue(raw) else { return nil }
        return SpeechHistorySource(rawValue: raw)
    }

    private func intParam(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return Int(double)
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func providerCredentials(from params: [String: Any]?) -> [String: String] {
        TTSLentCredentials.parse(from: params)
    }

    private func parseSpeechTimingRequest(params: [String: Any]?, text: String) -> SpeechTimingRequest? {
        guard let params else {
            return nil
        }

        let rawTiming = params["speechTiming"] ?? params["alignment"]
        guard let rawTiming else {
            return nil
        }

        var timingParams: [String: Any] = [:]
        if let enabled = rawTiming as? Bool {
            guard enabled else {
                return nil
            }
        } else if let rawTiming = rawTiming as? [String: Any] {
            if let enabled = rawTiming["enabled"] as? Bool, !enabled {
                return nil
            }
            timingParams = rawTiming
        } else {
            return nil
        }

        let modelId = resolveTranscriptionModelId(timingParams["modelId"] as? String)
        let rawCues = (timingParams["cues"] as? [[String: Any]]) ?? []
        var fallbackTextSearchStart = 0
        let cues = rawCues.compactMap { entry -> SpeechTimingCueRequest? in
            guard let id = entry["id"] as? String, !id.isEmpty else {
                return nil
            }

            let cueText = normalizePreferenceValue(entry["text"] as? String)
            var textStart = intValue(entry["textStart"])
            var textEnd = intValue(entry["textEnd"])

            if textStart == nil || textEnd == nil, let cueText {
                if let range = findTextRange(cueText, in: text, from: fallbackTextSearchStart) {
                    textStart = range.location
                    textEnd = range.location + range.length
                    fallbackTextSearchStart = range.location + range.length
                }
            }

            return SpeechTimingCueRequest(
                id: id,
                text: cueText,
                textStart: textStart,
                textEnd: textEnd
            )
        }

        return SpeechTimingRequest(modelId: modelId, cues: cues)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let doubleValue = value as? Double {
            return Int(doubleValue)
        }
        if let stringValue = value as? String {
            return Int(stringValue)
        }
        return nil
    }

    private func findTextRange(_ needle: String, in haystack: String, from offset: Int) -> NSRange? {
        let nsHaystack = haystack as NSString
        let clampedOffset = max(0, min(offset, nsHaystack.length))
        let searchRange = NSRange(location: clampedOffset, length: nsHaystack.length - clampedOffset)
        let found = nsHaystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
        guard found.location != NSNotFound else {
            return nil
        }
        return found
    }

    private struct SourceToken {
        let normalized: String
        let range: NSRange
    }

    private struct ResolvedSpeechTimingWord {
        let timing: SpeechTimingWord
        let sourceRange: NSRange?
    }

    private func generateSpeechTiming(
        output: SynthesisOutput,
        request: SynthesisRequest,
        timingRequest: SpeechTimingRequest
    ) async -> SpeechTiming? {
        let extensionName = output.format.isEmpty ? "wav" : output.format
        let audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vox-speech-timing-\(UUID().uuidString).\(extensionName)")

        do {
            try output.audioData.write(to: audioURL, options: .atomic)
            defer {
                try? FileManager.default.removeItem(at: audioURL)
            }

            let startedAt = Date()
            let transcription = try await asrEngine.transcribe(url: audioURL, modelId: timingRequest.modelId)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            let resolvedWords = resolveSpeechTimingWords(
                transcription.words,
                sourceText: request.text
            )
            let cues = resolveSpeechTimingCues(
                timingRequest.cues,
                resolvedWords: resolvedWords,
                sourceText: request.text,
                audioDurationMs: output.metrics.audioDurationMs
            )

            return SpeechTiming(
                source: resolvedWords.isEmpty ? "estimated" : "asr",
                modelId: transcription.modelId,
                elapsedMs: elapsedMs,
                words: resolvedWords.map(\.timing),
                cues: cues
            )
        } catch is CancellationError {
            return nil
        } catch {
            log.warning("speechTiming generation failed requestId=\(request.requestId) modelId=\(timingRequest.modelId) error=\(error.localizedDescription)")
            return nil
        }
    }

    private func resolveSpeechTimingWords(
        _ words: [WordTiming],
        sourceText: String
    ) -> [ResolvedSpeechTimingWord] {
        let tokens = tokenizeSourceText(sourceText)
        var nextTokenIndex = 0

        return words.map { word in
            let normalizedWord = normalizeTimingToken(word.word)
            var sourceRange: NSRange?

            if !normalizedWord.isEmpty {
                while nextTokenIndex < tokens.count {
                    let token = tokens[nextTokenIndex]
                    nextTokenIndex += 1
                    if token.normalized == normalizedWord {
                        sourceRange = token.range
                        break
                    }
                }
            }

            let timing = SpeechTimingWord(
                word: word.word,
                startMs: milliseconds(word.start),
                endMs: milliseconds(word.end),
                confidence: word.confidence,
                sourceTextStart: sourceRange?.location,
                sourceTextEnd: sourceRange.map { $0.location + $0.length }
            )
            return ResolvedSpeechTimingWord(timing: timing, sourceRange: sourceRange)
        }
    }

    private func resolveSpeechTimingCues(
        _ cues: [SpeechTimingCueRequest],
        resolvedWords: [ResolvedSpeechTimingWord],
        sourceText: String,
        audioDurationMs: Int
    ) -> [SpeechTimingCue] {
        let textLength = max((sourceText as NSString).length, 1)
        let cueCount = max(cues.count, 1)

        return cues.enumerated().map { index, cue in
            let cueRange = normalizedCueRange(cue, textLength: textLength)
            let matchingWords: [ResolvedSpeechTimingWord] = cueRange.map { range in
                resolvedWords.filter { word in
                    guard let sourceRange = word.sourceRange else {
                        return false
                    }
                    return sourceRange.location < range.location + range.length
                        && sourceRange.location + sourceRange.length > range.location
                }
            } ?? []

            if !matchingWords.isEmpty {
                let startMs = matchingWords.map(\.timing.startMs).min() ?? 0
                let endMs = matchingWords.map(\.timing.endMs).max() ?? startMs
                let averageConfidence = matchingWords.reduce(Float(0)) { $0 + $1.timing.confidence } / Float(matchingWords.count)
                return SpeechTimingCue(
                    id: cue.id,
                    startMs: startMs,
                    endMs: endMs,
                    confidence: averageConfidence,
                    source: "asr"
                )
            }

            let estimatedRange = cueRange ?? NSRange(
                location: (textLength * index) / cueCount,
                length: textLength / cueCount
            )
            return estimatedCue(
                id: cue.id,
                range: estimatedRange,
                textLength: textLength,
                audioDurationMs: audioDurationMs
            )
        }
    }

    private func normalizedCueRange(_ cue: SpeechTimingCueRequest, textLength: Int) -> NSRange? {
        guard let textStart = cue.textStart, let textEnd = cue.textEnd else {
            return nil
        }
        let start = max(0, min(textStart, textLength))
        let end = max(start, min(textEnd, textLength))
        return NSRange(location: start, length: end - start)
    }

    private func estimatedCue(id: String, range: NSRange, textLength: Int, audioDurationMs: Int) -> SpeechTimingCue {
        let durationMs = max(audioDurationMs, 0)
        let startMs = textLength > 0 ? Int((Double(range.location) / Double(textLength)) * Double(durationMs)) : 0
        let endOffset = range.location + range.length
        let endMs = textLength > 0 ? Int((Double(endOffset) / Double(textLength)) * Double(durationMs)) : durationMs
        return SpeechTimingCue(
            id: id,
            startMs: startMs,
            endMs: max(startMs, endMs),
            confidence: 0,
            source: "estimated"
        )
    }

    private func tokenizeSourceText(_ text: String) -> [SourceToken] {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "[\\p{L}\\p{N}']+") else {
            return []
        }
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            let raw = nsText.substring(with: match.range)
            let normalized = normalizeTimingToken(raw)
            guard !normalized.isEmpty else {
                return nil
            }
            return SourceToken(normalized: normalized, range: match.range)
        }
    }

    private func normalizeTimingToken(_ token: String) -> String {
        String(token.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    private func milliseconds(_ seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    private func registerHandlers() {
        bridge.onClientDisconnected = { [weak self] connectionID in
            Task { await self?.streamingSessions.disconnect(connectionID: connectionID) }
            guard let self else { return }
            Task {
                await self.handleDisconnect(connectionID: connectionID)
            }
        }

        sessions.onRecordingTimeout = { [weak self] session in
            guard let self else { return }
            Task {
                await self.recorder.cancel()
                session.state = .cancelled
                self.log.warning("Auto-cancelled live session \(session.sessionId) for client \(session.clientId) — exceeded \(Int(LiveSessionCoordinator.maxRecordingSeconds))s recording limit")
                session.progress("session.state", [
                    "sessionId": session.sessionId,
                    "state": SessionState.cancelled.rawValue,
                    "previous": SessionState.recording.rawValue,
                    "reason": "recording_timeout"
                ])
                session.reply(nil, "session_cancelled:recording_timeout")
            }
        }

        sessions.onStartingTimeout = { [weak self] session in
            guard let self else { return }
            Task {
                await self.recorder.cancel()
                session.state = .cancelled
                self.log.warning("Auto-cancelled live session \(session.sessionId) for client \(session.clientId) — exceeded \(Int(LiveSessionCoordinator.maxStartingSeconds))s startup limit")
                session.progress("session.state", [
                    "sessionId": session.sessionId,
                    "state": SessionState.cancelled.rawValue,
                    "previous": SessionState.starting.rawValue,
                    "reason": "starting_timeout"
                ])
                session.reply(nil, "session_cancelled:starting_timeout")
            }
        }

        bridge.handle("health") { [weak self] _, reply in
            guard let self else { return }
            reply([
                "service": "Vox",
                "version": VoxVersion.current,
                "port": Int(self.port),
                "pid": Int(getpid()),
                "startedAt": ISO8601DateFormatter().string(from: self.startedAt)
            ], nil)
        }

        bridge.handle("doctor.run") { [weak self] _, reply in
            guard let self else { return }
            Task {
                let report = await self.makeDoctorReport()
                reply(report.dictionaryValue(), nil)
            }
        }

        bridge.handle("microphone.requestAccess") { _, reply in
            Task {
                let status = await MicrophonePermission.requestAccessStatusString()
                reply([
                    "status": status,
                    "detail": MicrophonePermission.detail(for: status),
                    "remediation": MicrophonePermission.remediation(for: status)?.dictionaryValue() ?? NSNull()
                ], nil)
            }
        }

        bridge.handle("models.list") { [weak self] _, reply in
            guard let self else { return }
            Task {
                let models = await self.asrEngine.models()
                reply(["models": models.map { $0.dictionaryValue() }], nil)
            }
        }

        bridge.handle("models.catalog") { _, reply in
            reply(ModelCatalogStore.shared.current.dictionaryValue(), nil)
        }

        bridge.handle("models.refreshCatalog") { _, reply in
            Task {
                do {
                    let catalog = try await ModelCatalogStore.shared.refresh()
                    reply(catalog.dictionaryValue(), nil)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handleStreaming("models.install") { [weak self] params, progress, reply in
            guard let self else { return }
            let modelId = self.resolveTranscriptionModelId(params?["modelId"] as? String)
            Task {
                do {
                    let model = try await self.performModelsInstall(modelId: modelId) { update in
                        progress("models.progress", update.dictionaryValue())
                    }
                    reply(["model": model.dictionaryValue()], nil)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handleStreaming("models.preload") { [weak self] params, progress, reply in
            guard let self else { return }
            let modelId = self.resolveTranscriptionModelId(params?["modelId"] as? String)
            Task {
                do {
                    let model = try await self.performModelsPreload(modelId: modelId) { update in
                        progress("models.progress", update.dictionaryValue())
                    }
                    reply(["model": model.dictionaryValue()], nil)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handle("warmup.status") { [weak self] params, reply in
            guard let self else { return }
            let modelId = self.resolveTranscriptionModelId(params?["modelId"] as? String)
            let requestedBy = params?["clientId"] as? String
            Task {
                let status = await self.performWarmupStatus(modelId: modelId, requestedBy: requestedBy)
                reply(["warmup": status.dictionaryValue()], nil)
            }
        }

        bridge.handle("warmup.start") { [weak self] params, reply in
            guard let self else { return }
            let modelId = self.resolveTranscriptionModelId(params?["modelId"] as? String)
            let requestedBy = params?["clientId"] as? String
            Task {
                let status = await self.performWarmupStart(modelId: modelId, requestedBy: requestedBy)
                reply(["warmup": status.dictionaryValue()], nil)
            }
        }

        bridge.handle("warmup.schedule") { [weak self] params, reply in
            guard let self else { return }
            let modelId = self.resolveTranscriptionModelId(params?["modelId"] as? String)
            let requestedBy = params?["clientId"] as? String
            let delayMs = max((params?["delayMs"] as? Int) ?? 0, 0)
            Task {
                let status = await self.performWarmupSchedule(modelId: modelId, delayMs: delayMs, requestedBy: requestedBy)
                reply(["warmup": status.dictionaryValue()], nil)
            }
        }

        bridge.handle("history.list") { [weak self] params, reply in
            guard let self else { return }
            let filter = self.historyListFilter(from: params)
            Task {
                do {
                    let records = try await self.history.list(filter: filter)
                    reply([
                        "records": records.map { $0.dictionaryValue() },
                        "nextCursor": NSNull()
                    ], nil)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handle("history.get") { [weak self] params, reply in
            guard let self else { return }
            let id = self.normalizePreferenceValue(params?["id"] as? String)
            Task {
                do {
                    guard let id else {
                        reply(nil, "Missing history id")
                        return
                    }
                    let record = try await self.history.get(id: id)
                    reply(["record": record?.dictionaryValue() ?? NSNull()], nil)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handle("history.delete") { [weak self] params, reply in
            guard let self else { return }
            let id = self.normalizePreferenceValue(params?["id"] as? String)
            Task {
                do {
                    guard let id else {
                        reply(nil, "Missing history id")
                        return
                    }
                    let deleted = try await self.history.delete(id: id)
                    reply(["deleted": deleted, "id": id], nil)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handle("history.clear") { [weak self] params, reply in
            guard let self else { return }
            let filter = self.historyListFilter(from: params)
            Task {
                do {
                    let deleted = try await self.history.clear(filter: filter)
                    reply(["deleted": deleted], nil)
                } catch {
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handle("transcribe.file") { [weak self] params, reply in
            guard let self else { return }
            let path = params?["path"] as? String
            let clientId = (params?["clientId"] as? String) ?? "unknown"
            let modelId = self.resolveTranscriptionModelId(params?["modelId"] as? String)
            Task {
                do {
                    guard let path else {
                        throw NSError(domain: "VoxService", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Missing path"
                        ])
                    }
                    let result = try await self.performTranscribeFile(path: path, modelId: modelId, clientId: clientId)
                    await self.performance.record(result.performanceSample)
                    let historyRecord = SpeechHistoryRecord.transcription(
                        source: .file,
                        route: "transcribe.file",
                        clientId: clientId,
                        modelId: result.output.modelId,
                        output: result.output,
                        completedAt: result.performanceSample.timestamp
                    )
                    await self.history.record(historyRecord)
                    var payload = result.output.dictionaryValue()
                    payload["historyId"] = historyRecord.id
                    reply(payload, nil)
                } catch {
                    await self.performance.record(PerformanceSample(
                        clientId: clientId,
                        route: "transcribe.file",
                        modelId: modelId,
                        outcome: "error",
                        textLength: 0,
                        error: error.localizedDescription
                    ))
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handle("annotation.models") { [weak self] _, reply in
            guard let self else { return }
            Task { reply(["models": await self.annotationEngine.models().map { $0.dictionaryValue() }], nil) }
        }

        bridge.handle("annotate.file") { [weak self] params, reply in
            guard let self else { return }
            let path = params?["path"] as? String
            let modelId = (params?["modelId"] as? String) ?? "speaker-diarization:v1"
            let clientId = (params?["clientId"] as? String) ?? "unknown"
            let connectionID = (params?["_connectionID"] as? String) ?? "unknown"
            let text = params?["text"] as? String
            let words = self.parseAnnotationWords(params?["words"] as? [[String: Any]])
            let credentials = AnnotationLentCredentials.parse(from: params)
            let diarize = params?["diarize"] as? Bool ?? true
            let events = params?["tagAudioEvents"] as? Bool
            let language = params?["languageCode"] as? String
            let speakers = params?["numSpeakers"] as? Int
            let (id, ticket) = self.annotationTasks.reserve(connectionID: connectionID)
            let task = Task {
                defer { self.annotationTasks.finish(connectionID: connectionID, id: id, ticket: ticket) }
                do {
                    try Task.checkCancellation()
                    guard let path else { throw RemoteAnnotationError.invalidFile }
                    let result = try await self.performAnnotateFile(path: path, modelId: modelId,
                        clientId: clientId, text: text, words: words, providerCredentials: credentials,
                        diarize: diarize, tagAudioEvents: events, languageCode: language, numSpeakers: speakers)
                    try Task.checkCancellation()
                    await self.performance.record(result.performanceSample)
                    reply(result.output.dictionaryValue(), nil)
                } catch {
                    let cancelled = error is CancellationError || Task.isCancelled
                    let message = cancelled ? "annotation_cancelled:connection_closed" : error.localizedDescription
                    await self.performance.record(PerformanceSample(clientId: clientId, route: "annotate.file",
                        modelId: modelId, outcome: cancelled ? "cancelled" : "error", textLength: 0, error: message))
                    reply(nil, message)
                }
            }
            ticket.attach(task)
        }

        bridge.handle("synthesize.voices") { [weak self] params, reply in
            guard let self else { return }
            let modelId = params?["modelId"] as? String
            let credentials = self.providerCredentials(from: params)
            let connectionID = params?["_connectionID"] as? String ?? "unknown"
            let (id, ticket) = self.synthesisTasks.reserve(connectionID: connectionID)
            let task = Task {
                defer { self.synthesisTasks.finish(connectionID: connectionID, id: id, ticket: ticket) }
                do {
                    try Task.checkCancellation()
                    let voices = try await self.performSynthesizeVoices(modelId: modelId, providerCredentials: credentials)
                    try Task.checkCancellation()
                    reply(["voices": voices.map { $0.dictionaryValue() }], nil)
                } catch {
                    reply(nil, Task.isCancelled || error is CancellationError
                          ? "request_cancelled:connection_closed" : error.localizedDescription)
                }
            }
            ticket.attach(task)
        }

        bridge.handle("synthesize.models") { [weak self] _, reply in
            guard let self else { return }
            Task {
                let models = await self.performSynthesizeModels()
                reply([
                    "models": models.map { $0.dictionaryValue() }
                ], nil)
            }
        }

        bridge.handle("synthesize.generate") { [weak self] params, reply in
            guard let self else { return }
            let requestedModelId = params?["modelId"] as? String
            let modelId = self.resolveSynthesisModelId(requestedModelId)
            let requestedVoiceId = params?["voiceId"] as? String
            let voiceId = self.resolveSynthesisVoiceId(
                requestedVoiceId,
                resolvedModelId: modelId,
                requestedModelId: requestedModelId
            )
            let clientId = (params?["clientId"] as? String) ?? "unknown"
            let text = (params?["text"] as? String) ?? ""
            let format = (params?["format"] as? String) ?? TTSDefaults.format
            let speed = params?["speed"] as? Double
            let instructions = params?["instructions"] as? String
            let providerCredentials = self.providerCredentials(from: params)
            let speechTimingRequest = self.parseSpeechTimingRequest(params: params, text: text)
            let connectionID = (params?["_connectionID"] as? String) ?? "unknown"
            let request = SynthesisRequest(
                text: text,
                modelId: modelId,
                voiceId: voiceId,
                format: format,
                speed: speed,
                instructions: instructions,
                providerCredentials: providerCredentials
            )

            let (taskID, ticket) = self.synthesisTasks.reserve(connectionID: connectionID)
            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.synthesisTasks.finish(connectionID: connectionID, id: taskID, ticket: ticket)
                }
                let routeStartedAt = Date()
                self.log.info("synthesize.generate started requestId=\(request.requestId) connectionId=\(connectionID) clientId=\(clientId) modelId=\(modelId) voiceId=\(voiceId ?? "default") textLength=\(text.count)")
                do {
                    try Task.checkCancellation()
                    let output = try await self.performSynthesizeGenerate(
                        request: request,
                        speechTimingRequest: speechTimingRequest
                    )
                    try Task.checkCancellation()
                    let routeElapsedMs = Int(Date().timeIntervalSince(routeStartedAt) * 1000)
                    await self.performance.record(PerformanceSample(
                        clientId: clientId,
                        route: "synthesize.generate",
                        modelId: output.modelId,
                        voiceId: output.voiceId,
                        outcome: "ok",
                        textLength: text.count,
                        metrics: output.metrics.performanceMetrics
                    ))
                    self.log.info("synthesize.generate completed requestId=\(request.requestId) connectionId=\(connectionID) clientId=\(clientId) modelId=\(output.modelId) voiceId=\(output.voiceId) routeElapsedMs=\(routeElapsedMs) providerElapsedMs=\(output.elapsedMs) audioBytes=\(output.audioData.count)")
                    reply(output.dictionaryValue(), nil)
                } catch is CancellationError {
                    let routeElapsedMs = Int(Date().timeIntervalSince(routeStartedAt) * 1000)
                    await self.performance.record(PerformanceSample(
                        clientId: clientId,
                        route: "synthesize.generate",
                        modelId: modelId,
                        voiceId: voiceId,
                        outcome: "cancelled",
                        textLength: text.count,
                        error: "request_cancelled:connection_closed"
                    ))
                    self.log.warning("synthesize.generate cancelled requestId=\(request.requestId) connectionId=\(connectionID) clientId=\(clientId) modelId=\(modelId) voiceId=\(voiceId ?? "default") routeElapsedMs=\(routeElapsedMs)")
                } catch {
                    let routeElapsedMs = Int(Date().timeIntervalSince(routeStartedAt) * 1000)
                    await self.performance.record(PerformanceSample(
                        clientId: clientId,
                        route: "synthesize.generate",
                        modelId: modelId,
                        voiceId: voiceId,
                        outcome: "error",
                        textLength: text.count,
                        error: error.localizedDescription
                    ))
                    self.log.error("synthesize.generate failed requestId=\(request.requestId) connectionId=\(connectionID) clientId=\(clientId) modelId=\(modelId) voiceId=\(voiceId ?? "default") routeElapsedMs=\(routeElapsedMs) error=\(error.localizedDescription)")
                    reply(nil, error.localizedDescription)
                }
            }
            ticket.attach(task)
        }

        bridge.handle("transcribe.stream.status") { _, reply in
            Task {
                do { reply(try Self.codableDictionary(await NativeStreamingASR.shared.status()), nil) }
                catch { reply(nil, error.localizedDescription) }
            }
        }
        bridge.handle("transcribe.stream.start") { [weak self] params, reply in
            guard let self else { return }
            let parameters = StreamParameters(params)
            Task {
                do {
                    guard let connectionID = parameters.connectionID, let clientId = parameters.clientId, !clientId.isEmpty else { throw StreamingASRError.invalidSession }
                    let modelId = parameters.modelId ?? StreamingASRDefaults.modelId
                    let id = try await self.streamingSessions.start(connectionID: connectionID, clientId: clientId, modelId: modelId)
                    reply(["sessionId": id.uuidString, "modelId": modelId, "sampleRate": 16000, "channels": 1, "encoding": "float32le", "maxPacketSamples": 16000, "nextSequence": 0], nil)
                } catch { reply(nil, error.localizedDescription) }
            }
        }
        bridge.handle("transcribe.stream.append") { [weak self] params, reply in
            guard let self else { return }
            let parameters = StreamParameters(params)
            Task {
                do {
                    let (id, connectionID, clientId) = try Self.streamIdentity(parameters)
                    guard let sequence = parameters.sequence, let audio = parameters.audioBase64 else { throw StreamingASRError.invalidAudio }
                    let updates = try await self.streamingSessions.append(id: id, connectionID: connectionID, clientId: clientId, sequence: sequence, samples: StreamingPCM.decode(audio))
                    reply(["sessionId": id.uuidString, "nextSequence": sequence + 1, "updates": try updates.map(Self.codableDictionary)], nil)
                } catch { reply(nil, error.localizedDescription) }
            }
        }
        bridge.handle("transcribe.stream.finish") { [weak self] params, reply in
            guard let self else { return }
            let parameters = StreamParameters(params)
            Task {
                do {
                    let (id, connectionID, clientId) = try Self.streamIdentity(parameters)
                    let result = try await self.streamingSessions.finish(id: id, connectionID: connectionID, clientId: clientId)
                    reply(["sessionId": id.uuidString, "result": try Self.codableDictionary(result)], nil)
                } catch { reply(nil, error.localizedDescription) }
            }
        }
        bridge.handle("transcribe.stream.cancel") { [weak self] params, reply in
            guard let self else { return }
            let parameters = StreamParameters(params)
            Task {
                do {
                    let (id, connectionID, clientId) = try Self.streamIdentity(parameters)
                    try await self.streamingSessions.cancel(id: id, connectionID: connectionID, clientId: clientId)
                    reply(["sessionId": id.uuidString, "cancelled": true], nil)
                } catch { reply(nil, error.localizedDescription) }
            }
        }

        bridge.handle("transcribe.sessionStatus") { [weak self] _, reply in
            guard let self else { return }
            if let session = self.sessions.status() {
                reply(["session": session.dictionaryValue()], nil)
            } else {
                reply(["session": NSNull()], nil)
            }
        }

        bridge.handle("synthesize.sessionStatus") { [weak self] _, reply in
            guard let self else { return }
            if let session = self.synthesisSessions.status() {
                reply(["session": session.dictionaryValue()], nil)
            } else {
                reply(["session": NSNull()], nil)
            }
        }

        bridge.handleStreaming("transcribe.startSession") { [weak self] params, progress, reply in
            guard let self else { return }
            let modelId = self.resolveTranscriptionModelId(params?["modelId"] as? String)
            let clientId = (params?["clientId"] as? String) ?? "unknown"
            let connectionID = (params?["_connectionID"] as? String) ?? UUID().uuidString

            Task {
                var startingSession: LiveSessionCoordinator.Session?
                do {
                    let speechPreferences = self.preferencesLoader().speech
                    try await self.ensureMicrophoneAccessForLiveSession()
                    let session = try self.sessions.begin(
                        connectionID: connectionID,
                        clientId: clientId,
                        modelId: modelId,
                        progress: progress,
                        reply: reply
                    )
                    startingSession = session
                    self.log.info("Starting live session \(session.sessionId) for client \(clientId) model \(modelId)")
                    self.sessions.startStartingTimer()
                    session.progress("session.state", [
                        "sessionId": session.sessionId,
                        "state": SessionState.starting.rawValue,
                        "previous": NSNull()
                    ])
                    _ = try await self.recorder.start(
                        preferredInputDeviceID: speechPreferences.preferredInputDeviceId
                    )
                    guard self.sessions.current(id: session.sessionId) != nil else {
                        await self.recorder.cancel()
                        return
                    }
                    session.state = .recording
                    self.sessions.startRecordingTimer()
                    session.progress("session.state", [
                        "sessionId": session.sessionId,
                        "state": SessionState.recording.rawValue,
                        "previous": SessionState.starting.rawValue
                    ])
                    if speechPreferences.modelDownloadPolicy.warmsOnFirstUse {
                        _ = await self.warmup.start(modelId: modelId, requestedBy: clientId)
                    }
                } catch {
                    if let session = startingSession {
                        _ = self.sessions.finish(id: session.sessionId)
                        await self.recorder.cancel()
                        let previousState = session.state
                        session.state = .error
                        session.progress("session.state", [
                            "sessionId": session.sessionId,
                            "state": SessionState.error.rawValue,
                            "previous": previousState.rawValue
                        ])
                        self.log.error("Failed to start live session \(session.sessionId) for client \(clientId): \(error.localizedDescription)")
                    } else if let active = self.sessions.status() {
                        self.log.warning("Failed to start live session for client \(clientId): \(error.localizedDescription) active=\(active.sessionId) state=\(active.state.rawValue) owner=\(active.clientId)")
                    } else {
                        self.log.error("Failed to start live session for client \(clientId): \(error.localizedDescription)")
                    }
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handleStreaming("synthesize.startSession") { [weak self] params, progress, reply in
            guard let self else { return }
            let text = (params?["text"] as? String) ?? ""
            let requestedModelId = params?["modelId"] as? String
            let modelId = self.resolveSynthesisModelId(requestedModelId)
            let voiceId = self.resolveSynthesisVoiceId(
                params?["voiceId"] as? String,
                resolvedModelId: modelId,
                requestedModelId: requestedModelId
            )
            let format = (params?["format"] as? String) ?? TTSDefaults.format
            let speed = params?["speed"] as? Double
            let instructions = params?["instructions"] as? String
            let providerCredentials = self.providerCredentials(from: params)
            let clientId = (params?["clientId"] as? String) ?? "unknown"
            let connectionID = (params?["_connectionID"] as? String) ?? UUID().uuidString

            Task {
                do {
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        reply(nil, "Missing text")
                        return
                    }

                    let session = try self.synthesisSessions.begin(
                        connectionID: connectionID,
                        clientId: clientId,
                        modelId: modelId,
                        voiceId: voiceId,
                        textLength: text.count,
                        progress: progress,
                        reply: reply
                    )
                    self.log.info("Starting synthesis session \(session.sessionId) for client \(clientId) model \(modelId) voice \(voiceId ?? "default")")
                    session.progress("session.state", [
                        "sessionId": session.sessionId,
                        "state": SessionState.starting.rawValue,
                        "previous": NSNull()
                    ])

                    session.state = .processing
                    session.progress("session.state", [
                        "sessionId": session.sessionId,
                        "state": SessionState.processing.rawValue,
                        "previous": SessionState.starting.rawValue
                    ])

                    _ = await self.warmup.start(modelId: modelId, requestedBy: clientId)

                    session.task = Task { [weak self] in
                        guard let self else { return }

                        do {
                            let output = try await self.ttsEngine.synthesize(SynthesisRequest(
                                requestId: session.sessionId,
                                text: text,
                                modelId: modelId,
                                voiceId: voiceId,
                                format: format,
                                speed: speed,
                                instructions: instructions,
                                providerCredentials: providerCredentials
                            ))

                            guard !Task.isCancelled else { return }

                            for (index, chunk) in Self.audioChunks(from: output.audioData).enumerated() {
                                guard !Task.isCancelled else { return }
                                session.progress("session.audio", [
                                    "sessionId": session.sessionId,
                                    "sequence": index,
                                    "modelId": output.modelId,
                                    "voiceId": output.voiceId,
                                    "format": output.format,
                                    "contentType": output.contentType,
                                    "audioBase64": chunk.base64EncodedString(),
                                    "audioBytes": chunk.count
                                ])
                            }

                            _ = self.synthesisSessions.finish(id: session.sessionId)
                            await self.performance.record(PerformanceSample(
                                clientId: session.clientId,
                                route: "synthesize.startSession",
                                modelId: output.modelId,
                                voiceId: output.voiceId,
                                outcome: "ok",
                                textLength: session.textLength,
                                metrics: output.metrics.performanceMetrics
                            ))

                            session.state = .done
                            session.progress("session.final", [
                                "sessionId": session.sessionId,
                                "modelId": output.modelId,
                                "voiceId": output.voiceId,
                                "format": output.format,
                                "contentType": output.contentType,
                                "audioBytes": output.audioData.count,
                                "elapsedMs": output.elapsedMs,
                                "metrics": output.metrics.dictionaryValue()
                            ])
                            session.progress("session.state", [
                                "sessionId": session.sessionId,
                                "state": SessionState.done.rawValue,
                                "previous": SessionState.processing.rawValue
                            ])
                            session.reply([
                                "sessionId": session.sessionId,
                                "modelId": output.modelId,
                                "voiceId": output.voiceId,
                                "format": output.format,
                                "contentType": output.contentType,
                                "audioBytes": output.audioData.count,
                                "elapsedMs": output.elapsedMs,
                                "metrics": output.metrics.dictionaryValue()
                            ], nil)
                        } catch is CancellationError {
                            return
                        } catch {
                            await self.performance.record(PerformanceSample(
                                clientId: session.clientId,
                                route: "synthesize.startSession",
                                modelId: session.modelId,
                                voiceId: session.voiceId,
                                outcome: "error",
                                textLength: session.textLength,
                                error: error.localizedDescription
                            ))
                            self.log.error("Failed synthesis session \(session.sessionId) for client \(session.clientId): \(error.localizedDescription)")
                            if let finished = self.synthesisSessions.finish(id: session.sessionId) {
                                finished.state = .error
                                finished.progress("session.state", [
                                    "sessionId": finished.sessionId,
                                    "state": SessionState.error.rawValue,
                                    "previous": SessionState.processing.rawValue
                                ])
                                finished.reply(nil, error.localizedDescription)
                            }
                        }
                    }
                } catch {
                    if let active = self.synthesisSessions.status() {
                        self.log.warning("Failed to start synthesis session for client \(clientId): \(error.localizedDescription) active=\(active.sessionId) state=\(active.state.rawValue) owner=\(active.clientId)")
                    } else {
                        self.log.error("Failed to start synthesis session for client \(clientId): \(error.localizedDescription)")
                    }
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handle("transcribe.stopSession") { [weak self] params, reply in
            guard let self else { return }
            let requestedID = params?["sessionId"] as? String
            Task {
                do {
                    guard let session = self.sessions.markProcessing(id: requestedID) else {
                        reply(nil, "No active live session")
                        return
                    }

                    session.progress("session.state", [
                        "sessionId": session.sessionId,
                        "state": SessionState.processing.rawValue,
                        "previous": SessionState.recording.rawValue
                    ])

                    let audioURL = try await self.recorder.stop()
                    defer { try? FileManager.default.removeItem(at: audioURL) }

                    try await self.requireInstalledModelWhenDownloadsAreDisabled(modelId: session.modelId)
                    let output = try await self.asrEngine.transcribe(url: audioURL, modelId: session.modelId)
                    guard let finished = self.sessions.finish(id: session.sessionId) else {
                        return
                    }
                    let sample = PerformanceSample(
                        clientId: finished.clientId,
                        route: "transcribe.live",
                        modelId: finished.modelId,
                        outcome: "ok",
                        textLength: output.text.count,
                        metrics: output.metrics.performanceMetrics
                    )
                    await self.performance.record(sample)
                    let historyRecord = SpeechHistoryRecord.transcription(
                        source: .live,
                        route: "transcribe.live",
                        sessionId: finished.sessionId,
                        clientId: finished.clientId,
                        modelId: output.modelId,
                        output: output,
                        startedAt: finished.startedAt,
                        completedAt: sample.timestamp
                    )
                    await self.history.record(historyRecord)

                    finished.state = .done
                    self.log.info("Completed live session \(finished.sessionId) for client \(finished.clientId) elapsed=\(output.elapsedMs)ms textLength=\(output.text.count)")
                    let finalPayload: [String: Any] = [
                        "sessionId": finished.sessionId,
                        "text": output.text,
                        "elapsedMs": output.elapsedMs,
                        "metrics": output.metrics.dictionaryValue(),
                        "words": output.words.map { $0.dictionaryValue() },
                        "historyId": historyRecord.id
                    ]
                    finished.progress("session.final", finalPayload)
                    finished.progress("session.state", [
                        "sessionId": finished.sessionId,
                        "state": SessionState.done.rawValue,
                        "previous": SessionState.processing.rawValue
                    ])
                    finished.reply(finalPayload, nil)

                    reply([
                        "stopped": true,
                        "sessionId": finished.sessionId,
                        "historyId": historyRecord.id,
                        "result": finalPayload
                    ], nil)
                } catch {
                    if let session = self.sessions.current(id: requestedID) {
                        await self.performance.record(PerformanceSample(
                            clientId: session.clientId,
                            route: "transcribe.live",
                            modelId: session.modelId,
                            outcome: "error",
                            textLength: 0,
                            error: error.localizedDescription
                        ))
                    }
                    await self.recorder.cancel()
                    self.log.error("Failed to stop live session \(requestedID ?? "current"): \(error.localizedDescription)")
                    if let session = self.sessions.finish(id: requestedID) {
                        session.reply(nil, error.localizedDescription)
                    }
                    reply(nil, error.localizedDescription)
                }
            }
        }

        bridge.handle("transcribe.cancelSession") { [weak self] params, reply in
            guard let self else { return }
            let requestedID = params?["sessionId"] as? String
            Task {
                guard let session = self.sessions.finish(id: requestedID) else {
                    reply(nil, "No active live session")
                    return
                }

                let previousState = session.state
                await self.recorder.cancel()
                session.state = .cancelled
                self.log.warning("Cancelled live session \(session.sessionId) for client \(session.clientId)")
                session.progress("session.state", [
                    "sessionId": session.sessionId,
                    "state": SessionState.cancelled.rawValue,
                    "previous": previousState.rawValue
                ])
                session.reply([
                    "cancelled": true,
                    "sessionId": session.sessionId
                ], nil)
                reply([
                    "cancelled": true,
                    "sessionId": session.sessionId
                ], nil)
            }
        }

        bridge.handle("synthesize.cancel") { [weak self] params, reply in
            guard let self else { return }
            let requestedID = params?["sessionId"] as? String
            Task {
                guard let session = self.synthesisSessions.finish(id: requestedID) else {
                    reply(nil, "No active synthesis session")
                    return
                }

                session.task?.cancel()
                session.task = nil
                session.state = .cancelled
                await self.performance.record(PerformanceSample(
                    clientId: session.clientId,
                    route: "synthesize.startSession",
                    modelId: session.modelId,
                    voiceId: session.voiceId,
                    outcome: "cancelled",
                    textLength: session.textLength
                ))
                self.log.warning("Cancelled synthesis session \(session.sessionId) for client \(session.clientId)")
                session.progress("session.state", [
                    "sessionId": session.sessionId,
                    "state": SessionState.cancelled.rawValue,
                    "previous": SessionState.processing.rawValue
                ])
                session.reply([
                    "cancelled": true,
                    "sessionId": session.sessionId
                ], nil)
                reply([
                    "cancelled": true,
                    "sessionId": session.sessionId
                ], nil)
            }
        }
    }

    private static func streamIdentity(_ params: StreamParameters) throws -> (UUID, String, String) {
        guard let raw = params.sessionId, let id = UUID(uuidString: raw),
              let connectionID = params.connectionID,
              let clientId = params.clientId, !clientId.isEmpty else { throw StreamingASRError.invalidSession }
        return (id, connectionID, clientId)
    }
    private static func codableDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any] ?? [:]
    }

    private func ensureMicrophoneAccessForLiveSession() async throws {
        let status = await MicrophonePermission.requestAccessStatusString()
        switch status {
        case "authorized":
            return
        case "denied", "restricted":
            throw NSError(domain: "VoxService", code: 27, userInfo: [
                NSLocalizedDescriptionKey: "Microphone access is not allowed for Vox."
            ])
        case "not_determined":
            throw NSError(domain: "VoxService", code: 26, userInfo: [
                NSLocalizedDescriptionKey: "Microphone access was not granted for Vox."
            ])
        default:
            throw NSError(domain: "VoxService", code: 28, userInfo: [
                NSLocalizedDescriptionKey: "Microphone access is unavailable."
            ])
        }
    }

    private func makeDoctorReport() async -> DoctorReport {
        let runtimeExists: Bool
        if socketPath != nil {
            runtimeExists = (try? PrivateRuntimeCapability.read(from: privateCapabilityURL ?? RuntimePaths.runtimeFileURL())) != nil
        } else { runtimeExists = ((try? RuntimeRegistry.read()) != nil) }
        let asrModels = await asrEngine.models()
        let asrModel = asrModels.first
        let ttsModels = await ttsEngine.models()
        let ttsModel = ttsModels.first
        let microphoneStatus = MicrophonePermission.statusString()
        let checks = [
            DoctorCheck(name: "runtime", status: runtimeExists ? "ok" : "error", detail: runtimeExists ? "runtime.json written" : "runtime.json missing"),
            DoctorCheck(
                name: "microphone",
                status: microphoneStatusToLevel(microphoneStatus),
                detail: MicrophonePermission.detail(for: microphoneStatus),
                remediation: MicrophonePermission.remediation(for: microphoneStatus)
            ),
            DoctorCheck(name: "backend", status: (asrModel?.available ?? false) ? "ok" : "error", detail: (asrModel?.available ?? false) ? "Parakeet available" : "Parakeet unavailable"),
            DoctorCheck(name: "model", status: (asrModel?.installed ?? false) ? "ok" : "warning", detail: (asrModel?.installed ?? false) ? "Parakeet model installed" : "Parakeet model not installed"),
            DoctorCheck(name: "synthesis", status: (ttsModel?.available ?? false) ? "ok" : "warning", detail: (ttsModel?.available ?? false) ? "\(ttsModel?.name ?? "TTS") available" : "Speech synthesis unavailable")
        ]

        return DoctorReport(ready: checks.allSatisfy { $0.status != "error" }, checks: checks)
    }

    private func microphoneStatusToLevel(_ status: String) -> String {
        switch status {
        case "authorized":
            return "ok"
        case "not_determined":
            return "warning"
        default:
            return "error"
        }
    }

    private func handleDisconnect(connectionID: String) async {
        annotationTasks.cancel(connectionID: connectionID)
        synthesisTasks.cancel(connectionID: connectionID)

        if let session = sessions.finish(connectionID: connectionID) {
            await recorder.cancel()
            log.warning("Connection \(connectionID) closed, cancelled live session \(session.sessionId) for client \(session.clientId)")
            session.reply(nil, "session_cancelled:connection_closed")
            return
        }

        if let session = synthesisSessions.finish(connectionID: connectionID) {
            session.task?.cancel()
            session.task = nil
            await performance.record(PerformanceSample(
                clientId: session.clientId,
                route: "synthesize.startSession",
                modelId: session.modelId,
                voiceId: session.voiceId,
                outcome: "cancelled",
                textLength: session.textLength,
                error: "session_cancelled:connection_closed"
            ))
            log.warning("Connection \(connectionID) closed, cancelled synthesis session \(session.sessionId) for client \(session.clientId)")
            session.reply(nil, "session_cancelled:connection_closed")
        }
    }

    private static func audioChunks(from data: Data, chunkSize: Int = 24 * 1024) -> [Data] {
        guard !data.isEmpty else { return [] }

        var chunks: [Data] = []
        var index = 0
        while index < data.count {
            let upperBound = min(index + chunkSize, data.count)
            chunks.append(data.subdata(in: index..<upperBound))
            index = upperBound
        }
        return chunks
    }
}

struct ASRRouteTranscriptionResult: Sendable {
    let output: TranscriptionOutput
    let performanceSample: PerformanceSample
}

struct AnnotationRouteResult: Sendable {
    let output: AnnotationOutput
    let performanceSample: PerformanceSample
}

private struct StreamParameters: Sendable {
    let sessionId: String?
    let connectionID: String?
    let clientId: String?
    let modelId: String?
    let sequence: Int?
    let audioBase64: String?
    init(_ params: [String: Any]?) {
        sessionId = params?["sessionId"] as? String
        connectionID = params?["_connectionID"] as? String
        clientId = params?["clientId"] as? String
        modelId = params?["modelId"] as? String
        sequence = params?["sequence"] as? Int
        audioBase64 = params?["audioBase64"] as? String
    }
}
