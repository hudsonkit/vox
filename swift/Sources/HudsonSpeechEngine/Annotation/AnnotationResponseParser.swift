import Foundation
import VoxCore

struct AnnotationResponseParser {
    struct Parsed {
        var text: String
        var words: [AttributedWordTiming] = []
        var speakers: [SpeakerSegment] = []
        var events: [AnnotationAudioEvent] = []
        var language: String?
        var languageConfidence: Float?
        var languages: [String] = []
        var duration: Double?
        var requestId: String?
        var modelIds: [String] = []
        var speakerSource: String?
        var unavailable: [String] = []
    }
    static func parse(_ data: Data, eleven: Bool, diarize: Bool) throws -> Parsed {
        do { return try eleven ? scribe(data, diarize: diarize) : deepgram(data, diarize: diarize) }
        catch { throw RemoteAnnotationError.invalidResponse }
    }
    private static func interval(_ start: Double?, _ end: Double?) throws -> (Double, Double) {
        guard let start, let end, start.isFinite, end.isFinite, start >= 0, end >= start else { throw RemoteAnnotationError.invalidResponse }
        return (start, end)
    }
    private static func probability(_ value: Double?) throws -> Float? {
        guard let value else { return nil }
        guard value.isFinite, (0...1).contains(value) else { throw RemoteAnnotationError.invalidResponse }
        return Float(value)
    }
    private static func duration(_ value: Double?) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, value >= 0 else { throw RemoteAnnotationError.invalidResponse }; return value
    }
    private static func logProbability(_ value: Double?) throws -> Double? {
        guard let value else { return nil }
        guard value.isFinite, value <= 0 else { throw RemoteAnnotationError.invalidResponse }; return value
    }
    private static func scribe(_ data: Data, diarize: Bool) throws -> Parsed {
        let root = try JSONDecoder().decode(Scribe.self, from: data)
        var result = Parsed(text: root.text)
        result.language = root.language_code; result.languageConfidence = try probability(root.language_probability)
        result.languages = root.language_code.map { [$0] } ?? []
        result.duration = try duration(root.audio_duration_secs); result.requestId = root.transcription_id
        result.modelIds = root.model_id.map { [$0] } ?? []
        for token in root.words {
            if token.type == "spacing" { continue }
            guard !token.text.isEmpty else { throw RemoteAnnotationError.invalidResponse }
            let (start, end) = try interval(token.start, token.end)
            let speaker = diarize ? token.speaker_id : nil
            if let speaker, speaker.isEmpty { throw RemoteAnnotationError.invalidResponse }
            let logprob = try logProbability(token.logprob)
            switch token.type {
            case "word": result.words.append(AttributedWordTiming(word: token.text, start: start, end: end,
                confidence: nil, speakerId: speaker, logProbability: logprob))
            case "audio_event": result.events.append(AnnotationAudioEvent(label: token.text, start: start,
                end: end, speakerId: speaker, logProbability: logprob))
            default: throw RemoteAnnotationError.invalidResponse
            }
        }
        result.speakers = deriveSpeakers(result.words)
        result.speakerSource = result.speakers.isEmpty ? nil : "word-span-derived"
        if root.language_code == nil { result.unavailable.append("language") }
        if root.language_probability == nil { result.unavailable.append("languageConfidence") }
        if result.words.contains(where: { $0.logProbability == nil }) { result.unavailable.append("words.logProbability") }
        if diarize && result.words.contains(where: { $0.speakerId == nil }) { result.unavailable.append("words.speakerId") }
        return result
    }
    private static func deepgram(_ data: Data, diarize: Bool) throws -> Parsed {
        let root = try JSONDecoder().decode(Deepgram.self, from: data)
        guard root.results.channels.count == 1, let channel = root.results.channels.first,
              let alternative = channel.alternatives.first else { throw RemoteAnnotationError.invalidResponse }
        var result = Parsed(text: alternative.transcript)
        result.duration = try duration(root.metadata?.duration); result.requestId = root.metadata?.request_id
        result.modelIds = root.metadata?.models ?? []
        result.language = channel.detected_language
        result.languages = channel.languages ?? channel.detected_language.map { [$0] } ?? []
        let utterances = root.results.utterances ?? []
        let utteranceWords = utterances.flatMap { $0.words ?? [] }
        // Channel words are the canonical full transcript. Partial utterance detail
        // must not discard an otherwise present tail or its confidence fields.
        let tokens = alternative.words.isEmpty ? utteranceWords : alternative.words
        for token in tokens {
            guard !(token.punctuated_word ?? token.word).isEmpty else { throw RemoteAnnotationError.invalidResponse }
            let (start, end) = try interval(token.start, token.end)
            if let speaker = token.speaker, speaker < 0 { throw RemoteAnnotationError.invalidResponse }
            result.words.append(AttributedWordTiming(word: token.punctuated_word ?? token.word, start: start, end: end,
                confidence: try probability(token.confidence), speakerId: diarize ? token.speaker.map(String.init) : nil,
                speakerConfidence: diarize ? try probability(token.speaker_confidence) : nil))
        }
        if diarize {
            for utterance in utterances {
                guard let speaker = utterance.speaker else { continue }
                guard speaker >= 0 else { throw RemoteAnnotationError.invalidResponse }
                let (start, end) = try interval(utterance.start, utterance.end)
                // Utterance confidence is transcription confidence, not speaker confidence.
                result.speakers.append(SpeakerSegment(speakerId: String(speaker), start: start, end: end,
                    confidence: try probability(utterance.speaker_confidence)))
            }
            result.speakerSource = result.speakers.isEmpty ? nil : "vendor-utterances"
            if result.speakers.isEmpty {
                result.speakers = deriveSpeakers(result.words)
                result.speakerSource = result.speakers.isEmpty ? nil : "word-span-derived"
            }
        }
        if result.language == nil { result.unavailable.append("language") }
        if result.words.contains(where: { $0.confidence == nil }) { result.unavailable.append("words.confidence") }
        if diarize && result.words.contains(where: { $0.speakerId == nil }) { result.unavailable.append("words.speakerId") }
        if diarize && result.words.contains(where: { $0.speakerConfidence == nil }) { result.unavailable.append("words.speakerConfidence") }
        if result.speakers.contains(where: { $0.confidence == nil }) { result.unavailable.append("speakers.confidence") }
        return result
    }
    private static func deriveSpeakers(_ words: [AttributedWordTiming]) -> [SpeakerSegment] {
        var result: [SpeakerSegment] = []
        var current: SpeakerSegment?
        for word in words {
            guard let speaker = word.speakerId else { if let current { result.append(current) }; current = nil; continue }
            if let previous = current, previous.speakerId == speaker {
                // Preserve source spans; do not invent confidence for a derived aggregate.
                current = SpeakerSegment(speakerId: speaker, start: min(previous.start, word.start), end: max(previous.end, word.end))
            } else {
                if let current { result.append(current) }
                current = SpeakerSegment(speakerId: speaker, start: word.start, end: word.end)
            }
        }
        if let current { result.append(current) }; return result
    }
    private struct Scribe: Decodable {
        let text: String; let words: [ScribeToken]
        let language_code: String?; let language_probability: Double?
        let audio_duration_secs: Double?; let transcription_id: String?; let model_id: String?
    }
    private struct ScribeToken: Decodable {
        let text: String; let type: String; let start: Double?; let end: Double?
        let speaker_id: String?; let logprob: Double?
    }
    private struct Deepgram: Decodable { let metadata: Metadata?; let results: Results }
    private struct Metadata: Decodable { let request_id: String?; let duration: Double?; let models: [String]? }
    private struct Results: Decodable { let channels: [Channel]; let utterances: [Utterance]? }
    private struct Channel: Decodable { let alternatives: [Alternative]; let detected_language: String?; let languages: [String]? }
    private struct Alternative: Decodable { let transcript: String; let words: [DGWord] }
    private struct DGWord: Decodable {
        let word: String; let punctuated_word: String?; let start: Double?; let end: Double?
        let confidence: Double?; let speaker: Int?; let speaker_confidence: Double?
    }
    private struct Utterance: Decodable {
        let start: Double?; let end: Double?; let speaker: Int?; let speaker_confidence: Double?; let words: [DGWord]?
    }
}
