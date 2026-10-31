import Foundation
import VoxCore

public enum RemoteAnnotationError: Error, LocalizedError, Sendable {
    case modelRequired, missingCredentials, invalidCredentials, unsupportedOptions, invalidFile, fileChanged
    case unsupportedContainer, invalidResponse, durationUnavailable, httpStatus(Int), transport, responseTooLarge, busy
    public var errorDescription: String? {
        switch self {
        case .modelRequired: return "annotation_model_required: select elevenlabs:scribe_v2 or deepgram:nova-3 explicitly"
        case .missingCredentials: return "annotation_credentials_required: lend the selected provider key in credentials"
        case .invalidCredentials: return "annotation_invalid_credentials: invalid header value"
        case .unsupportedOptions: return "annotation_unsupported_options: check annotation.models; transcript alignment, Deepgram audio events and Deepgram speaker-count hints are unsupported"
        case .invalidFile: return "annotation_invalid_file: expected a nonempty regular media file within the upload limit"
        case .fileChanged: return "annotation_file_changed: finalize the recording before annotation"
        case .unsupportedContainer: return "annotation_unsupported_container: use a supported audio/video file extension"
        case .invalidResponse: return "annotation_invalid_response: missing or invalid vendor fields"
        case .durationUnavailable: return "annotation_duration_unavailable: neither vendor nor local media metadata supplied duration"
        case .httpStatus(let code): return "annotation_http_error: HTTP \(code)"
        case .transport: return "annotation_transport_error: remote upload failed"
        case .responseTooLarge: return "annotation_response_too_large: response/result exceeds the bounded transport limit"
        case .busy: return "annotation_busy: two annotation requests are already active"
        }
    }
}

/// File-only cloud annotation, separate from native dictation/ASR providers. No ambient
/// credentials, model fallback, result cache, or global account state. Upload is explicit.
public actor RemoteAnnotationProvider: AnnotationProvider {
    public static let elevenLabsModelId = "elevenlabs:scribe_v2"
    public static let deepgramModelId = "deepgram:nova-3"
    private static let elevenLabsEndpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    private static let deepgramEndpoint = URL(string: "https://api.deepgram.com/v1/listen")!
    private let elevenLabsURL: URL
    private let deepgramURL: URL
    private let configuration: URLSessionConfiguration
    private var active = 0

    public init(elevenLabsURL: URL? = nil, deepgramURL: URL? = nil, configuration: URLSessionConfiguration? = nil) {
        let env = ProcessInfo.processInfo.environment
        self.elevenLabsURL = elevenLabsURL ?? Self.endpointOverride(env["VOX_ANNOTATION_ELEVENLABS_URL"], fallback: Self.elevenLabsEndpoint)
        self.deepgramURL = deepgramURL ?? Self.endpointOverride(env["VOX_ANNOTATION_DEEPGRAM_URL"], fallback: Self.deepgramEndpoint)
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 1800; config.timeoutIntervalForResource = 3600
        self.configuration = config
    }
    public func models() -> [AnnotationModelInfo] { Self.modelInfos }
    public nonisolated static var modelInfos: [AnnotationModelInfo] {
        [Self.info(eleven: true), Self.info(eleven: false)]
    }
    private nonisolated static func info(eleven: Bool) -> AnnotationModelInfo {
        AnnotationModelInfo(id: eleven ? elevenLabsModelId : deepgramModelId,
            providerId: eleven ? "elevenlabs" : "deepgram", nativeModelId: eleven ? "scribe_v2" : "nova-3",
            capabilities: ["file": true, "streaming": false, "wordTimestamps": true,
                "speakerDiarization": true, "wordConfidence": !eleven, "wordLogProbabilities": eleven,
                "speakerConfidence": !eleven, "audioEvents": eleven, "language": true,
                "languageConfidence": eleven, "transcriptAlignment": false, "vendorCancellation": false],
            requiresCredentials: [eleven ? "ELEVENLABS_API_KEY" : "DEEPGRAM_API_KEY"],
            unsupportedFields: eleven ? ["words.confidence", "words.speakerConfidence", "speakers.confidence", "transcriptAlignment"]
                : ["audioEvents", "words.logProbability", "languageConfidence", "transcriptAlignment"],
            maxInputBytes: AnnotationUploadFile.maxInputBytes)
    }
    public func annotate(request: AnnotationRequest) async throws -> AnnotationOutput {
        try Task.checkCancellation()
        let started = Date()
        let eleven: Bool
        switch request.modelId {
        case Self.elevenLabsModelId: eleven = true
        case Self.deepgramModelId: eleven = false
        default: throw RemoteAnnotationError.modelRequired
        }
        guard request.transcription == nil, eleven || (request.tagAudioEvents != true && request.numSpeakers == nil),
              request.numSpeakers == nil || (request.diarize && (1...32).contains(request.numSpeakers!))
        else { throw RemoteAnnotationError.unsupportedOptions }
        if let language = request.languageCode {
            let parts = language.split(separator: "-", omittingEmptySubsequences: false)
            let letters = language.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
            let valid = eleven ? (letters && (2...3).contains(language.count))
                : ((language == "multi") || (parts.count <= 2 && (2...3).contains(parts[0].count) && (parts.count == 1 || (2...4).contains(parts[1].count)) && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) } }))
            guard valid else { throw RemoteAnnotationError.unsupportedOptions }
        }
        let keyName = eleven ? "ELEVENLABS_API_KEY" : "DEEPGRAM_API_KEY"
        guard let key = request.providerCredentials[keyName], !key.isEmpty else { throw RemoteAnnotationError.missingCredentials }
        guard key.utf8.count <= 4096, key.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else { throw RemoteAnnotationError.invalidCredentials }
        guard active < 2 else { throw RemoteAnnotationError.busy }
        active += 1; defer { active -= 1 }
        let modelCheckMs = Int(Date().timeIntervalSince(started) * 1000)
        let endpoint = eleven ? elevenLabsURL : deepgramURL
        guard Self.validEndpoint(endpoint) else { throw RemoteAnnotationError.transport }
        let boundary = "VoxAnnotation-" + UUID().uuidString
        var fields: [(String, String)]? = nil
        if eleven {
            fields = [("model_id", "scribe_v2"), ("diarize", request.diarize ? "true" : "false"),
                      ("timestamps_granularity", "word"), ("tag_audio_events", request.tagAudioEvents == false ? "false" : "true"),
                      ("webhook", "false")]
            if let language = request.languageCode { fields?.append(("language_code", language)) }
            if let count = request.numSpeakers { fields?.append(("num_speakers", String(count))) }
        }
        let prepared = try await AnnotationUploadFile.prepare(source: request.url, fields: fields, boundary: boundary)
        defer { prepared.remove() }
        try Task.checkCancellation()
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        if !eleven {
            var query = [URLQueryItem(name: "model", value: "nova-3"), URLQueryItem(name: "punctuate", value: "true"),
                         URLQueryItem(name: "utterances", value: "true"), URLQueryItem(name: "multichannel", value: "false")]
            if request.diarize { query.append(URLQueryItem(name: "diarize_model", value: "v2")) }
            if let language = request.languageCode { query.append(URLQueryItem(name: "language", value: language)) }
            else { query.append(URLQueryItem(name: "detect_language", value: "true")) }
            components?.queryItems = query
        }
        guard let url = components?.url else { throw RemoteAnnotationError.transport }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"; http.timeoutInterval = 1800
        http.cachePolicy = .reloadIgnoringLocalCacheData; http.httpShouldHandleCookies = false
        http.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.setValue(eleven ? key : "Token \(key)", forHTTPHeaderField: eleven ? "xi-api-key" : "Authorization")
        http.setValue(eleven ? "multipart/form-data; boundary=\(boundary)" : try AnnotationUploadFile.mimeType(request.url), forHTTPHeaderField: "Content-Type")
        let remoteStart = Date()
        let (data, _) = try await AnnotationHTTPUpload().perform(http, file: prepared.url, configuration: configuration)
        try Task.checkCancellation()
        let remoteMs = Int(Date().timeIntervalSince(remoteStart) * 1000)
        let parsed = try AnnotationResponseParser.parse(data, eleven: eleven, diarize: request.diarize)
        guard let duration = parsed.duration ?? prepared.duration, duration.isFinite, duration >= 0,
              duration * 1000 <= Double(Int.max) else { throw RemoteAnnotationError.durationUnavailable }
        let metrics = AnnotationMetrics(traceId: UUID().uuidString, audioDurationMs: Int(duration * 1000),
            inputBytes: prepared.inputBytes, wasPreloaded: false, fileCheckMs: prepared.fileCheckMs,
            modelCheckMs: modelCheckMs, modelLoadMs: 0, audioLoadMs: prepared.audioLoadMs,
            audioPrepareMs: prepared.audioPrepareMs, diarizationMs: remoteMs, totalMs: Int(Date().timeIntervalSince(started) * 1000))
        let info = Self.info(eleven: eleven)
        var unavailable = parsed.unavailable
        if parsed.requestId == nil { unavailable.append("providerRequestId") }
        if parsed.modelIds.isEmpty { unavailable.append("providerModelIds") }
        let result = AnnotationOutput(modelId: request.modelId, text: parsed.text, elapsedMs: metrics.totalMs, metrics: metrics,
            words: parsed.words, speakers: parsed.speakers, providerId: info.providerId, providerRequestId: parsed.requestId,
            providerModelIds: parsed.modelIds, duration: duration, durationSource: parsed.duration == nil ? "media-file" : "vendor",
            language: parsed.language, languageConfidence: parsed.languageConfidence, languages: parsed.languages,
            audioEvents: parsed.events, speakerSegmentsSource: parsed.speakerSource,
            unsupportedFields: info.unsupportedFields, unavailableFields: Array(Set(unavailable)).sorted())
        guard try JSONEncoder().encode(result).count <= 8 * 1024 * 1024 else { throw RemoteAnnotationError.responseTooLarge }
        return result
    }
    private nonisolated static func endpointOverride(_ value: String?, fallback: URL) -> URL {
        guard let value else { return fallback }
        // An invalid explicit host override must never silently upload to production.
        return URL(string: value) ?? URL(string: "invalid:")!
    }
    private nonisolated static func validEndpoint(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, let host = url.host else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }
}
