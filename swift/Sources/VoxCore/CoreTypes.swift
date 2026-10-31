import AVFoundation
import Foundation

public struct RuntimeInfo: Codable, Sendable, Equatable {
    public let version: String
    public let serviceName: String
    public let port: UInt16
    public let socketPath: String?
    public let pid: Int32
    public let startedAt: Date

    public init(version: String, serviceName: String, port: UInt16, pid: Int32, startedAt: Date, socketPath: String? = nil) {
        self.version = version
        self.serviceName = serviceName
        self.port = socketPath == nil ? port : 0
        self.socketPath = socketPath
        self.pid = pid
        self.startedAt = startedAt
    }

    public func dictionaryValue() -> [String: Any] {
        var value: [String: Any] = [
            "version": version,
            "serviceName": serviceName,
            "port": Int(port),
            "pid": Int(pid),
            "startedAt": ISO8601DateFormatter().string(from: startedAt)
        ]
        if let socketPath { value["socketPath"] = socketPath; value["transport"] = "unix+ws+json-rpc" }
        return value
    }
}

public enum RuntimeRegistry {
    public static func read() throws -> RuntimeInfo? {
        let url = RuntimePaths.runtimeFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RuntimeInfo.self, from: data)
    }

    public static func write(_ runtime: RuntimeInfo) throws {
        try RuntimePaths.ensureDirectories()
        let data = try JSONEncoder().encode(runtime)
        try data.write(to: RuntimePaths.runtimeFileURL(), options: .atomic)
    }

    public static func remove() throws {
        let url = RuntimePaths.runtimeFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

public struct DoctorRemediation: Codable, Sendable, Equatable {
    public let action: String
    public let label: String
    public let detail: String

    public init(action: String, label: String, detail: String) {
        self.action = action
        self.label = label
        self.detail = detail
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "action": action,
            "label": label,
            "detail": detail
        ]
    }
}

public struct DoctorCheck: Codable, Sendable, Equatable {
    public let name: String
    public let status: String
    public let detail: String
    public let remediation: DoctorRemediation?

    public init(name: String, status: String, detail: String, remediation: DoctorRemediation? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.remediation = remediation
    }

    public func dictionaryValue() -> [String: Any] {
        var payload: [String: Any] = [
            "name": name,
            "status": status,
            "detail": detail
        ]
        if let remediation {
            payload["remediation"] = remediation.dictionaryValue()
        }
        return payload
    }
}

public struct DoctorReport: Codable, Sendable, Equatable {
    public let ready: Bool
    public let checks: [DoctorCheck]

    public init(ready: Bool, checks: [DoctorCheck]) {
        self.ready = ready
        self.checks = checks
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "ready": ready,
            "checks": checks.map { $0.dictionaryValue() }
        ]
    }
}

public struct ASRModelInfo: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let backend: String
    public let installed: Bool
    public let preloaded: Bool
    public let available: Bool
    public let computePlacement: CoreMLPlacement?
    /// Actual configured native-model idle timeout; nil for providers without this capability.
    /// Zero explicitly disables idle eviction.
    public let idleUnloadSeconds: Double?

    public init(id: String, name: String, backend: String, installed: Bool, preloaded: Bool, available: Bool, computePlacement: CoreMLPlacement? = nil, idleUnloadSeconds: Double? = nil) {
        self.id = id
        self.name = name
        self.backend = backend
        self.installed = installed
        self.preloaded = preloaded
        self.available = available
        self.computePlacement = computePlacement
        self.idleUnloadSeconds = idleUnloadSeconds
    }

    public func dictionaryValue() -> [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "name": name,
            "backend": backend,
            "installed": installed,
            "preloaded": preloaded,
            "available": available,
            "computePlacement": computePlacement?.dictionaryValue() ?? NSNull()
        ]
        if let idleUnloadSeconds { result["idleUnloadSeconds"] = idleUnloadSeconds }
        return result
    }
}

public struct TTSModelInfo: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let backend: String
    public let installed: Bool
    public let preloaded: Bool
    public let available: Bool

    public init(id: String, name: String, backend: String, installed: Bool, preloaded: Bool, available: Bool) {
        self.id = id
        self.name = name
        self.backend = backend
        self.installed = installed
        self.preloaded = preloaded
        self.available = available
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "backend": backend,
            "installed": installed,
            "preloaded": preloaded,
            "available": available
        ]
    }
}

public struct TTSVoiceInfo: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let language: String?
    public let backend: String
    public let modelId: String
    public let available: Bool
    public let isDefault: Bool

    public init(
        id: String,
        name: String,
        language: String? = nil,
        backend: String,
        modelId: String,
        available: Bool,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.backend = backend
        self.modelId = modelId
        self.available = available
        self.isDefault = isDefault
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "id": id,
            "name": name,
            "language": language ?? NSNull(),
            "backend": backend,
            "modelId": modelId,
            "available": available,
            "default": isDefault
        ]
    }
}

public struct ModelProgress: Sendable, Equatable {
    public let modelId: String
    public let progress: Double
    public let status: String

    public init(modelId: String, progress: Double, status: String) {
        self.modelId = modelId
        self.progress = progress
        self.status = status
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "modelId": modelId,
            "progress": progress,
            "status": status
        ]
    }
}

public struct WarmupStatus: Codable, Sendable, Equatable {
    public let modelId: String
    public let state: String
    public let requestedBy: String?
    public let scheduledFor: Date?
    public let startedAt: Date?
    public let completedAt: Date?
    public let lastError: String?

    public init(
        modelId: String,
        state: String,
        requestedBy: String? = nil,
        scheduledFor: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.modelId = modelId
        self.state = state
        self.requestedBy = requestedBy
        self.scheduledFor = scheduledFor
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.lastError = lastError
    }

    public func dictionaryValue() -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "modelId": modelId,
            "state": state,
            "requestedBy": requestedBy ?? NSNull(),
            "scheduledFor": scheduledFor.map { formatter.string(from: $0) } ?? NSNull(),
            "startedAt": startedAt.map { formatter.string(from: $0) } ?? NSNull(),
            "completedAt": completedAt.map { formatter.string(from: $0) } ?? NSNull(),
            "lastError": lastError ?? NSNull()
        ]
    }
}

public struct WordTiming: Codable, Sendable, Equatable {
    public let word: String
    public let start: Double   // seconds
    public let end: Double     // seconds
    public let confidence: Float

    public init(word: String, start: Double, end: Double, confidence: Float) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    public func dictionaryValue() -> [String: Any] {
        ["word": word, "start": start, "end": end, "confidence": confidence]
    }
}

public struct SpeakerSegment: Codable, Sendable, Equatable {
    public let speakerId: String
    public let start: Double
    public let end: Double
    public let confidence: Float?

    public init(speakerId: String, start: Double, end: Double, confidence: Float? = nil) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "speakerId": speakerId,
            "start": start,
            "end": end,
            "confidence": confidence ?? NSNull()
        ]
    }
}

public struct AttributedWordTiming: Codable, Sendable, Equatable {
    public let word: String
    public let start: Double
    public let end: Double
    public let confidence: Float?
    public let logProbability: Double?
    public let speakerConfidence: Float?
    public let speakerId: String?
    public let language: String?

    public init(
        word: String,
        start: Double,
        end: Double,
        confidence: Float? = nil,
        speakerId: String? = nil,
        logProbability: Double? = nil,
        speakerConfidence: Float? = nil, language: String? = nil
    ) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
        self.speakerId = speakerId
        self.language = language
        self.logProbability = logProbability
        self.speakerConfidence = speakerConfidence
    }

    public init(wordTiming: WordTiming, speakerId: String? = nil) {
        self.word = wordTiming.word
        self.start = wordTiming.start
        self.end = wordTiming.end
        self.confidence = wordTiming.confidence
        self.speakerId = speakerId
        self.language = nil
        self.logProbability = nil
        self.speakerConfidence = nil
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "word": word,
            "start": start,
            "end": end,
            "confidence": confidence ?? NSNull(),
            "logProbability": logProbability ?? NSNull(),
            "speakerConfidence": speakerConfidence ?? NSNull(),
            "language": language ?? NSNull(),
            "speakerId": speakerId ?? NSNull()
        ]
    }
}

public struct TranscriptionOutput: Sendable, Equatable {
    public let modelId: String
    public let text: String
    public let elapsedMs: Int
    public let metrics: TranscriptionMetrics
    public let words: [WordTiming]

    public init(modelId: String, text: String, elapsedMs: Int, metrics: TranscriptionMetrics, words: [WordTiming] = []) {
        self.modelId = modelId
        self.text = text
        self.elapsedMs = elapsedMs
        self.metrics = metrics
        self.words = words
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "modelId": modelId,
            "text": text,
            "elapsedMs": elapsedMs,
            "metrics": metrics.dictionaryValue(),
            "words": words.map { $0.dictionaryValue() }
        ]
    }
}

public struct SpeechTimingCueRequest: Sendable, Equatable {
    public let id: String
    public let text: String?
    public let textStart: Int?
    public let textEnd: Int?

    public init(id: String, text: String? = nil, textStart: Int? = nil, textEnd: Int? = nil) {
        self.id = id
        self.text = text
        self.textStart = textStart
        self.textEnd = textEnd
    }
}

public struct SpeechTimingRequest: Sendable, Equatable {
    public let modelId: String
    public let cues: [SpeechTimingCueRequest]

    public init(modelId: String, cues: [SpeechTimingCueRequest] = []) {
        self.modelId = modelId
        self.cues = cues
    }
}

public struct SpeechTimingWord: Sendable, Equatable {
    public let word: String
    public let startMs: Int
    public let endMs: Int
    public let confidence: Float
    public let sourceTextStart: Int?
    public let sourceTextEnd: Int?

    public init(
        word: String,
        startMs: Int,
        endMs: Int,
        confidence: Float,
        sourceTextStart: Int? = nil,
        sourceTextEnd: Int? = nil
    ) {
        self.word = word
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
        self.sourceTextStart = sourceTextStart
        self.sourceTextEnd = sourceTextEnd
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "word": word,
            "startMs": startMs,
            "endMs": endMs,
            "confidence": confidence,
            "sourceTextStart": sourceTextStart ?? NSNull(),
            "sourceTextEnd": sourceTextEnd ?? NSNull()
        ]
    }
}

public struct SpeechTimingCue: Sendable, Equatable {
    public let id: String
    public let startMs: Int
    public let endMs: Int
    public let confidence: Float
    public let source: String

    public init(id: String, startMs: Int, endMs: Int, confidence: Float, source: String) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
        self.source = source
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "id": id,
            "startMs": startMs,
            "endMs": endMs,
            "confidence": confidence,
            "source": source
        ]
    }
}

public struct SpeechTiming: Sendable, Equatable {
    public let source: String
    public let modelId: String
    public let elapsedMs: Int
    public let words: [SpeechTimingWord]
    public let cues: [SpeechTimingCue]

    public init(
        source: String,
        modelId: String,
        elapsedMs: Int,
        words: [SpeechTimingWord],
        cues: [SpeechTimingCue]
    ) {
        self.source = source
        self.modelId = modelId
        self.elapsedMs = elapsedMs
        self.words = words
        self.cues = cues
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "source": source,
            "modelId": modelId,
            "elapsedMs": elapsedMs,
            "words": words.map { $0.dictionaryValue() },
            "cues": cues.map { $0.dictionaryValue() }
        ]
    }
}

public struct AnnotationOutput: Codable, Sendable, Equatable {
    public let modelId: String
    public let text: String?
    public let elapsedMs: Int
    public let metrics: AnnotationMetrics
    public let words: [AttributedWordTiming]
    public let speakers: [SpeakerSegment]
    public let providerId: String?
    public let providerRequestId: String?
    public let providerModelIds: [String]
    public let duration: Double?
    public let durationSource: String?
    public let language: String?
    public let languageConfidence: Float?
    public let languages: [String]
    public let audioEvents: [AnnotationAudioEvent]
    public let speakerSegmentsSource: String?
    public let unsupportedFields: [String]
    public let unavailableFields: [String]

    public init(modelId: String, text: String? = nil, elapsedMs: Int, metrics: AnnotationMetrics,
                words: [AttributedWordTiming] = [], speakers: [SpeakerSegment] = [],
                providerId: String? = nil, providerRequestId: String? = nil, providerModelIds: [String] = [],
                duration: Double? = nil, durationSource: String? = nil,
                language: String? = nil, languageConfidence: Float? = nil, languages: [String] = [],
                audioEvents: [AnnotationAudioEvent] = [], speakerSegmentsSource: String? = nil,
                unsupportedFields: [String] = [], unavailableFields: [String] = []) {
        self.modelId = modelId; self.text = text; self.elapsedMs = elapsedMs; self.metrics = metrics
        self.words = words; self.speakers = speakers; self.providerId = providerId
        self.providerRequestId = providerRequestId; self.providerModelIds = providerModelIds; self.duration = duration; self.durationSource = durationSource
        self.language = language; self.languageConfidence = languageConfidence; self.languages = languages
        self.audioEvents = audioEvents; self.speakerSegmentsSource = speakerSegmentsSource
        self.unsupportedFields = unsupportedFields; self.unavailableFields = unavailableFields
    }
    public func dictionaryValue() -> [String: Any] {
        ["modelId": modelId, "text": text ?? NSNull(), "elapsedMs": elapsedMs,
         "metrics": metrics.dictionaryValue(), "words": words.map { $0.dictionaryValue() },
         "speakers": speakers.map { $0.dictionaryValue() }, "providerId": providerId ?? NSNull(),
         "providerRequestId": providerRequestId ?? NSNull(), "providerModelIds": providerModelIds, "duration": duration ?? NSNull(),
         "durationSource": durationSource ?? NSNull(), "language": language ?? NSNull(),
         "languageConfidence": languageConfidence ?? NSNull(), "languages": languages,
         "audioEvents": audioEvents.map { $0.dictionaryValue() },
         "speakerSegmentsSource": speakerSegmentsSource ?? NSNull(),
         "unsupportedFields": unsupportedFields, "unavailableFields": unavailableFields]
    }
}

public struct SynthesisOutput: Sendable, Equatable {
    public let modelId: String
    public let voiceId: String
    public let format: String
    public let contentType: String
    public let audioData: Data
    public let elapsedMs: Int
    public let metrics: SynthesisMetrics
    public let speechTiming: SpeechTiming?

    public init(
        modelId: String,
        voiceId: String,
        format: String,
        contentType: String,
        audioData: Data,
        elapsedMs: Int,
        metrics: SynthesisMetrics
    ) {
        self.init(
            modelId: modelId,
            voiceId: voiceId,
            format: format,
            contentType: contentType,
            audioData: audioData,
            elapsedMs: elapsedMs,
            metrics: metrics,
            speechTiming: nil
        )
    }

    public init(
        modelId: String,
        voiceId: String,
        format: String,
        contentType: String,
        audioData: Data,
        elapsedMs: Int,
        metrics: SynthesisMetrics,
        speechTiming: SpeechTiming?
    ) {
        self.modelId = modelId
        self.voiceId = voiceId
        self.format = format
        self.contentType = contentType
        self.audioData = audioData
        self.elapsedMs = elapsedMs
        self.metrics = metrics
        self.speechTiming = speechTiming
    }

    public func dictionaryValue() -> [String: Any] {
        var payload: [String: Any] = [
            "modelId": modelId,
            "voiceId": voiceId,
            "format": format,
            "contentType": contentType,
            "audioBase64": audioData.base64EncodedString(),
            "audioBytes": audioData.count,
            "elapsedMs": elapsedMs,
            "metrics": metrics.dictionaryValue()
        ]
        if let speechTiming {
            payload["speechTiming"] = speechTiming.dictionaryValue()
        }
        return payload
    }
}

public struct TranscriptionMetrics: Codable, Sendable, Equatable {
    public let traceId: String
    public let audioDurationMs: Int
    public let inputBytes: Int
    public let wasPreloaded: Bool
    public let fileCheckMs: Int
    public let modelCheckMs: Int
    public let modelLoadMs: Int
    public let audioLoadMs: Int
    public let audioPrepareMs: Int
    public let inferenceMs: Int
    public let totalMs: Int

    public init(
        traceId: String,
        audioDurationMs: Int,
        inputBytes: Int,
        wasPreloaded: Bool,
        fileCheckMs: Int,
        modelCheckMs: Int,
        modelLoadMs: Int,
        audioLoadMs: Int,
        audioPrepareMs: Int,
        inferenceMs: Int,
        totalMs: Int
    ) {
        self.traceId = traceId
        self.audioDurationMs = audioDurationMs
        self.inputBytes = inputBytes
        self.wasPreloaded = wasPreloaded
        self.fileCheckMs = fileCheckMs
        self.modelCheckMs = modelCheckMs
        self.modelLoadMs = modelLoadMs
        self.audioLoadMs = audioLoadMs
        self.audioPrepareMs = audioPrepareMs
        self.inferenceMs = inferenceMs
        self.totalMs = totalMs
    }

    public var realtimeFactor: Double {
        guard audioDurationMs > 0 else { return 0 }
        return Double(inferenceMs) / Double(audioDurationMs)
    }

    private enum CodingKeys: String, CodingKey {
        case traceId
        case audioDurationMs
        case inputBytes
        case wasPreloaded
        case fileCheckMs
        case modelCheckMs
        case modelLoadMs
        case audioLoadMs
        case audioPrepareMs
        case inferenceMs
        case totalMs
        case realtimeFactor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        traceId = try container.decode(String.self, forKey: .traceId)
        audioDurationMs = try container.decode(Int.self, forKey: .audioDurationMs)
        inputBytes = try container.decode(Int.self, forKey: .inputBytes)
        wasPreloaded = try container.decode(Bool.self, forKey: .wasPreloaded)
        fileCheckMs = try container.decode(Int.self, forKey: .fileCheckMs)
        modelCheckMs = try container.decode(Int.self, forKey: .modelCheckMs)
        modelLoadMs = try container.decode(Int.self, forKey: .modelLoadMs)
        audioLoadMs = try container.decode(Int.self, forKey: .audioLoadMs)
        audioPrepareMs = try container.decode(Int.self, forKey: .audioPrepareMs)
        inferenceMs = try container.decode(Int.self, forKey: .inferenceMs)
        totalMs = try container.decode(Int.self, forKey: .totalMs)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(traceId, forKey: .traceId)
        try container.encode(audioDurationMs, forKey: .audioDurationMs)
        try container.encode(inputBytes, forKey: .inputBytes)
        try container.encode(wasPreloaded, forKey: .wasPreloaded)
        try container.encode(fileCheckMs, forKey: .fileCheckMs)
        try container.encode(modelCheckMs, forKey: .modelCheckMs)
        try container.encode(modelLoadMs, forKey: .modelLoadMs)
        try container.encode(audioLoadMs, forKey: .audioLoadMs)
        try container.encode(audioPrepareMs, forKey: .audioPrepareMs)
        try container.encode(inferenceMs, forKey: .inferenceMs)
        try container.encode(totalMs, forKey: .totalMs)
        try container.encode(realtimeFactor, forKey: .realtimeFactor)
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "traceId": traceId,
            "audioDurationMs": audioDurationMs,
            "inputBytes": inputBytes,
            "wasPreloaded": wasPreloaded,
            "fileCheckMs": fileCheckMs,
            "modelCheckMs": modelCheckMs,
            "modelLoadMs": modelLoadMs,
            "audioLoadMs": audioLoadMs,
            "audioPrepareMs": audioPrepareMs,
            "inferenceMs": inferenceMs,
            "totalMs": totalMs,
            "realtimeFactor": realtimeFactor
        ]
    }

    public var performanceMetrics: PerformanceMetrics {
        PerformanceMetrics(
            traceId: traceId,
            audioDurationMs: audioDurationMs,
            wasPreloaded: wasPreloaded,
            modelCheckMs: modelCheckMs,
            modelLoadMs: modelLoadMs,
            inferenceMs: inferenceMs,
            totalMs: totalMs,
            inputBytes: inputBytes,
            fileCheckMs: fileCheckMs,
            audioLoadMs: audioLoadMs,
            audioPrepareMs: audioPrepareMs
        )
    }
}

public struct AnnotationMetrics: Codable, Sendable, Equatable {
    public let traceId: String
    public let audioDurationMs: Int
    public let inputBytes: Int
    public let wasPreloaded: Bool
    public let fileCheckMs: Int
    public let modelCheckMs: Int
    public let modelLoadMs: Int
    public let audioLoadMs: Int
    public let audioPrepareMs: Int
    public let diarizationMs: Int
    public let totalMs: Int

    public init(
        traceId: String,
        audioDurationMs: Int,
        inputBytes: Int,
        wasPreloaded: Bool,
        fileCheckMs: Int,
        modelCheckMs: Int,
        modelLoadMs: Int,
        audioLoadMs: Int,
        audioPrepareMs: Int,
        diarizationMs: Int,
        totalMs: Int
    ) {
        self.traceId = traceId
        self.audioDurationMs = audioDurationMs
        self.inputBytes = inputBytes
        self.wasPreloaded = wasPreloaded
        self.fileCheckMs = fileCheckMs
        self.modelCheckMs = modelCheckMs
        self.modelLoadMs = modelLoadMs
        self.audioLoadMs = audioLoadMs
        self.audioPrepareMs = audioPrepareMs
        self.diarizationMs = diarizationMs
        self.totalMs = totalMs
    }

    public var realtimeFactor: Double {
        guard audioDurationMs > 0 else { return 0 }
        return Double(diarizationMs) / Double(audioDurationMs)
    }

    private enum CodingKeys: String, CodingKey {
        case traceId
        case audioDurationMs
        case inputBytes
        case wasPreloaded
        case fileCheckMs
        case modelCheckMs
        case modelLoadMs
        case audioLoadMs
        case audioPrepareMs
        case diarizationMs
        case totalMs
        case realtimeFactor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        traceId = try container.decode(String.self, forKey: .traceId)
        audioDurationMs = try container.decode(Int.self, forKey: .audioDurationMs)
        inputBytes = try container.decode(Int.self, forKey: .inputBytes)
        wasPreloaded = try container.decode(Bool.self, forKey: .wasPreloaded)
        fileCheckMs = try container.decode(Int.self, forKey: .fileCheckMs)
        modelCheckMs = try container.decode(Int.self, forKey: .modelCheckMs)
        modelLoadMs = try container.decode(Int.self, forKey: .modelLoadMs)
        audioLoadMs = try container.decode(Int.self, forKey: .audioLoadMs)
        audioPrepareMs = try container.decode(Int.self, forKey: .audioPrepareMs)
        diarizationMs = try container.decode(Int.self, forKey: .diarizationMs)
        totalMs = try container.decode(Int.self, forKey: .totalMs)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(traceId, forKey: .traceId)
        try container.encode(audioDurationMs, forKey: .audioDurationMs)
        try container.encode(inputBytes, forKey: .inputBytes)
        try container.encode(wasPreloaded, forKey: .wasPreloaded)
        try container.encode(fileCheckMs, forKey: .fileCheckMs)
        try container.encode(modelCheckMs, forKey: .modelCheckMs)
        try container.encode(modelLoadMs, forKey: .modelLoadMs)
        try container.encode(audioLoadMs, forKey: .audioLoadMs)
        try container.encode(audioPrepareMs, forKey: .audioPrepareMs)
        try container.encode(diarizationMs, forKey: .diarizationMs)
        try container.encode(totalMs, forKey: .totalMs)
        try container.encode(realtimeFactor, forKey: .realtimeFactor)
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "traceId": traceId,
            "audioDurationMs": audioDurationMs,
            "inputBytes": inputBytes,
            "wasPreloaded": wasPreloaded,
            "fileCheckMs": fileCheckMs,
            "modelCheckMs": modelCheckMs,
            "modelLoadMs": modelLoadMs,
            "audioLoadMs": audioLoadMs,
            "audioPrepareMs": audioPrepareMs,
            "diarizationMs": diarizationMs,
            "totalMs": totalMs,
            "realtimeFactor": realtimeFactor
        ]
    }

    public var performanceMetrics: PerformanceMetrics {
        PerformanceMetrics(
            traceId: traceId,
            audioDurationMs: audioDurationMs,
            wasPreloaded: wasPreloaded,
            modelCheckMs: modelCheckMs,
            modelLoadMs: modelLoadMs,
            inferenceMs: diarizationMs,
            totalMs: totalMs,
            inputBytes: inputBytes,
            fileCheckMs: fileCheckMs,
            audioLoadMs: audioLoadMs,
            audioPrepareMs: audioPrepareMs
        )
    }
}

public struct SynthesisMetrics: Codable, Sendable, Equatable {
    public let traceId: String
    public let characterCount: Int
    public let audioDurationMs: Int
    public let outputBytes: Int
    public let wasPreloaded: Bool
    public let modelCheckMs: Int
    public let modelLoadMs: Int
    public let voiceResolveMs: Int
    public let synthesisMs: Int
    public let totalMs: Int

    public init(
        traceId: String,
        characterCount: Int,
        audioDurationMs: Int,
        outputBytes: Int,
        wasPreloaded: Bool,
        modelCheckMs: Int,
        modelLoadMs: Int,
        voiceResolveMs: Int,
        synthesisMs: Int,
        totalMs: Int
    ) {
        self.traceId = traceId
        self.characterCount = characterCount
        self.audioDurationMs = audioDurationMs
        self.outputBytes = outputBytes
        self.wasPreloaded = wasPreloaded
        self.modelCheckMs = modelCheckMs
        self.modelLoadMs = modelLoadMs
        self.voiceResolveMs = voiceResolveMs
        self.synthesisMs = synthesisMs
        self.totalMs = totalMs
    }

    public var inferenceMs: Int {
        synthesisMs
    }

    public var realtimeFactor: Double {
        guard audioDurationMs > 0 else { return 0 }
        return Double(synthesisMs) / Double(audioDurationMs)
    }

    private enum CodingKeys: String, CodingKey {
        case traceId
        case characterCount
        case audioDurationMs
        case outputBytes
        case wasPreloaded
        case modelCheckMs
        case modelLoadMs
        case voiceResolveMs
        case synthesisMs
        case inferenceMs
        case totalMs
        case realtimeFactor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        traceId = try container.decode(String.self, forKey: .traceId)
        characterCount = try container.decode(Int.self, forKey: .characterCount)
        audioDurationMs = try container.decode(Int.self, forKey: .audioDurationMs)
        outputBytes = try container.decode(Int.self, forKey: .outputBytes)
        wasPreloaded = try container.decode(Bool.self, forKey: .wasPreloaded)
        modelCheckMs = try container.decode(Int.self, forKey: .modelCheckMs)
        modelLoadMs = try container.decode(Int.self, forKey: .modelLoadMs)
        voiceResolveMs = try container.decode(Int.self, forKey: .voiceResolveMs)
        if let decodedSynthesisMs = try container.decodeIfPresent(Int.self, forKey: .synthesisMs) {
            synthesisMs = decodedSynthesisMs
        } else {
            synthesisMs = try container.decode(Int.self, forKey: .inferenceMs)
        }
        totalMs = try container.decode(Int.self, forKey: .totalMs)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(traceId, forKey: .traceId)
        try container.encode(characterCount, forKey: .characterCount)
        try container.encode(audioDurationMs, forKey: .audioDurationMs)
        try container.encode(outputBytes, forKey: .outputBytes)
        try container.encode(wasPreloaded, forKey: .wasPreloaded)
        try container.encode(modelCheckMs, forKey: .modelCheckMs)
        try container.encode(modelLoadMs, forKey: .modelLoadMs)
        try container.encode(voiceResolveMs, forKey: .voiceResolveMs)
        try container.encode(synthesisMs, forKey: .synthesisMs)
        try container.encode(inferenceMs, forKey: .inferenceMs)
        try container.encode(totalMs, forKey: .totalMs)
        try container.encode(realtimeFactor, forKey: .realtimeFactor)
    }

    public func dictionaryValue() -> [String: Any] {
        [
            "traceId": traceId,
            "characterCount": characterCount,
            "audioDurationMs": audioDurationMs,
            "outputBytes": outputBytes,
            "wasPreloaded": wasPreloaded,
            "modelCheckMs": modelCheckMs,
            "modelLoadMs": modelLoadMs,
            "voiceResolveMs": voiceResolveMs,
            "synthesisMs": synthesisMs,
            "inferenceMs": inferenceMs,
            "totalMs": totalMs,
            "realtimeFactor": realtimeFactor
        ]
    }

    public var performanceMetrics: PerformanceMetrics {
        PerformanceMetrics(
            traceId: traceId,
            audioDurationMs: audioDurationMs,
            wasPreloaded: wasPreloaded,
            modelCheckMs: modelCheckMs,
            modelLoadMs: modelLoadMs,
            inferenceMs: inferenceMs,
            totalMs: totalMs,
            characterCount: characterCount,
            outputBytes: outputBytes,
            voiceResolveMs: voiceResolveMs,
            synthesisMs: synthesisMs
        )
    }
}

public struct PerformanceMetrics: Codable, Sendable, Equatable {
    public let traceId: String
    public let audioDurationMs: Int
    public let wasPreloaded: Bool
    public let modelCheckMs: Int
    public let modelLoadMs: Int
    public let inferenceMs: Int
    public let totalMs: Int
    public let inputBytes: Int?
    public let fileCheckMs: Int?
    public let audioLoadMs: Int?
    public let audioPrepareMs: Int?
    public let characterCount: Int?
    public let outputBytes: Int?
    public let voiceResolveMs: Int?
    public let synthesisMs: Int?

    public init(
        traceId: String,
        audioDurationMs: Int,
        wasPreloaded: Bool,
        modelCheckMs: Int,
        modelLoadMs: Int,
        inferenceMs: Int,
        totalMs: Int,
        inputBytes: Int? = nil,
        fileCheckMs: Int? = nil,
        audioLoadMs: Int? = nil,
        audioPrepareMs: Int? = nil,
        characterCount: Int? = nil,
        outputBytes: Int? = nil,
        voiceResolveMs: Int? = nil,
        synthesisMs: Int? = nil
    ) {
        self.traceId = traceId
        self.audioDurationMs = audioDurationMs
        self.wasPreloaded = wasPreloaded
        self.modelCheckMs = modelCheckMs
        self.modelLoadMs = modelLoadMs
        self.inferenceMs = inferenceMs
        self.totalMs = totalMs
        self.inputBytes = inputBytes
        self.fileCheckMs = fileCheckMs
        self.audioLoadMs = audioLoadMs
        self.audioPrepareMs = audioPrepareMs
        self.characterCount = characterCount
        self.outputBytes = outputBytes
        self.voiceResolveMs = voiceResolveMs
        self.synthesisMs = synthesisMs
    }

    public var realtimeFactor: Double {
        guard audioDurationMs > 0 else { return 0 }
        return Double(inferenceMs) / Double(audioDurationMs)
    }

    private enum CodingKeys: String, CodingKey {
        case traceId
        case audioDurationMs
        case wasPreloaded
        case modelCheckMs
        case modelLoadMs
        case inferenceMs
        case totalMs
        case inputBytes
        case fileCheckMs
        case audioLoadMs
        case audioPrepareMs
        case characterCount
        case outputBytes
        case voiceResolveMs
        case synthesisMs
        case realtimeFactor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        traceId = try container.decode(String.self, forKey: .traceId)
        audioDurationMs = try container.decode(Int.self, forKey: .audioDurationMs)
        wasPreloaded = try container.decode(Bool.self, forKey: .wasPreloaded)
        modelCheckMs = try container.decode(Int.self, forKey: .modelCheckMs)
        modelLoadMs = try container.decode(Int.self, forKey: .modelLoadMs)
        inferenceMs = try container.decode(Int.self, forKey: .inferenceMs)
        totalMs = try container.decode(Int.self, forKey: .totalMs)
        inputBytes = try container.decodeIfPresent(Int.self, forKey: .inputBytes)
        fileCheckMs = try container.decodeIfPresent(Int.self, forKey: .fileCheckMs)
        audioLoadMs = try container.decodeIfPresent(Int.self, forKey: .audioLoadMs)
        audioPrepareMs = try container.decodeIfPresent(Int.self, forKey: .audioPrepareMs)
        characterCount = try container.decodeIfPresent(Int.self, forKey: .characterCount)
        outputBytes = try container.decodeIfPresent(Int.self, forKey: .outputBytes)
        voiceResolveMs = try container.decodeIfPresent(Int.self, forKey: .voiceResolveMs)
        synthesisMs = try container.decodeIfPresent(Int.self, forKey: .synthesisMs)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(traceId, forKey: .traceId)
        try container.encode(audioDurationMs, forKey: .audioDurationMs)
        try container.encode(wasPreloaded, forKey: .wasPreloaded)
        try container.encode(modelCheckMs, forKey: .modelCheckMs)
        try container.encode(modelLoadMs, forKey: .modelLoadMs)
        try container.encode(inferenceMs, forKey: .inferenceMs)
        try container.encode(totalMs, forKey: .totalMs)
        try container.encodeIfPresent(inputBytes, forKey: .inputBytes)
        try container.encodeIfPresent(fileCheckMs, forKey: .fileCheckMs)
        try container.encodeIfPresent(audioLoadMs, forKey: .audioLoadMs)
        try container.encodeIfPresent(audioPrepareMs, forKey: .audioPrepareMs)
        try container.encodeIfPresent(characterCount, forKey: .characterCount)
        try container.encodeIfPresent(outputBytes, forKey: .outputBytes)
        try container.encodeIfPresent(voiceResolveMs, forKey: .voiceResolveMs)
        try container.encodeIfPresent(synthesisMs, forKey: .synthesisMs)
        try container.encode(realtimeFactor, forKey: .realtimeFactor)
    }

    public func dictionaryValue() -> [String: Any] {
        var dictionary: [String: Any] = [
            "traceId": traceId,
            "audioDurationMs": audioDurationMs,
            "wasPreloaded": wasPreloaded,
            "modelCheckMs": modelCheckMs,
            "modelLoadMs": modelLoadMs,
            "inferenceMs": inferenceMs,
            "totalMs": totalMs,
            "realtimeFactor": realtimeFactor
        ]
        dictionary["inputBytes"] = inputBytes ?? NSNull()
        dictionary["fileCheckMs"] = fileCheckMs ?? NSNull()
        dictionary["audioLoadMs"] = audioLoadMs ?? NSNull()
        dictionary["audioPrepareMs"] = audioPrepareMs ?? NSNull()
        dictionary["characterCount"] = characterCount ?? NSNull()
        dictionary["outputBytes"] = outputBytes ?? NSNull()
        dictionary["voiceResolveMs"] = voiceResolveMs ?? NSNull()
        dictionary["synthesisMs"] = synthesisMs ?? NSNull()
        return dictionary
    }
}

public struct PerformanceSample: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let clientId: String
    public let route: String
    public let modelId: String
    public let voiceId: String?
    public let outcome: String
    public let textLength: Int
    public let error: String?
    public let metrics: PerformanceMetrics?

    public init(
        timestamp: Date = Date(),
        clientId: String,
        route: String,
        modelId: String,
        voiceId: String? = nil,
        outcome: String,
        textLength: Int,
        error: String? = nil,
        metrics: PerformanceMetrics? = nil
    ) {
        self.timestamp = timestamp
        self.clientId = clientId
        self.route = route
        self.modelId = modelId
        self.voiceId = voiceId
        self.outcome = outcome
        self.textLength = textLength
        self.error = error
        self.metrics = metrics
    }
}

public enum SessionState: String, Sendable {
    case starting
    case recording
    case processing
    case done
    case cancelled
    case error
}

public enum MicrophonePermission {
    public static func statusString() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not_determined"
        @unknown default:
            return "unknown"
        }
    }

    public static func requestAccessStatusString() async -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return statusString()
        default:
            return statusString()
        }
    }

    public static func detail(for status: String) -> String {
        switch status {
        case "authorized":
            return "Microphone access authorized"
        case "not_determined":
            return "Microphone access has not been requested"
        case "denied":
            return "Microphone access denied"
        case "restricted":
            return "Microphone access restricted"
        default:
            return "Microphone access unavailable"
        }
    }

    public static func remediation(for status: String) -> DoctorRemediation? {
        switch status {
        case "not_determined":
            return DoctorRemediation(
                action: "request_microphone_access",
                label: "Request Access",
                detail: "Ask the system for microphone access from Vox."
            )
        case "denied", "restricted":
            return DoctorRemediation(
                action: "open_microphone_privacy_settings",
                label: "Open Settings",
                detail: "Enable Vox in system microphone privacy settings."
            )
        default:
            return nil
        }
    }
}
