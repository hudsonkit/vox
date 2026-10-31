import Foundation
import VoxCore

enum ParakeetTextProcessing {
    static func convertTokensToText(_ tokenIds: [Int], vocabulary: [Int: String]) -> String {
        guard !tokenIds.isEmpty else { return "" }

        let tokens = tokenIds.compactMap { vocabulary[$0] }.filter { !$0.isEmpty }
        return tokens.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func createWordTimings(
        tokenIds: [Int],
        timestamps: [Int],
        confidences: [Float],
        tokenDurations: [Int],
        vocabulary: [Int: String]
    ) -> [WordTiming] {
        guard !tokenIds.isEmpty else { return [] }
        guard tokenIds.count == timestamps.count, confidences.count == tokenIds.count,
              tokenDurations.isEmpty || tokenDurations.count == tokenIds.count,
              timestamps.allSatisfy({ $0 >= 0 }), tokenDurations.allSatisfy({ $0 >= 0 }) else {
            VoxLog.engine.warning("parakeet.word_timings alignment_unavailable inputTokens=\(tokenIds.count) timestamps=\(timestamps.count) confidences=\(confidences.count) durations=\(tokenDurations.count)")
            return []
        }

        // Decoder symbols can share an emission frame. Keep their original order
        // within that frame so punctuation and subword pieces cannot be permuted.
        let ordered = tokenIds.indices.sorted {
            timestamps[$0] == timestamps[$1] ? $0 < $1 : timestamps[$0] < timestamps[$1]
        }
        var words: [WordTiming] = []
        var word = ""
        var start = 0.0
        var end = 0.0
        var confidence: Float = 1
        func commit() {
            guard !word.isEmpty else { return }
            words.append(WordTiming(word: word, start: start, end: end, confidence: confidence))
            word = ""
        }

        for index in ordered {
            // Match text decoding: absent vocabulary entries do not invent token_N words.
            guard let piece = vocabulary[tokenIds[index]], !piece.isEmpty else { continue }
            let tokenStart = Double(timestamps[index]) * ParakeetConstants.secondsPerEncoderFrame
            let frames = tokenDurations.isEmpty ? 1 : max(1, tokenDurations[index])
            let tokenEnd = tokenStart + Double(frames) * ParakeetConstants.secondsPerEncoderFrame
            for character in piece.replacingOccurrences(of: "▁", with: " ") {
                if character.isWhitespace { commit(); continue }
                if word.isEmpty {
                    start = tokenStart
                    end = tokenEnd
                    confidence = confidences[index]
                } else {
                    start = min(start, tokenStart)
                    end = max(end, tokenEnd)
                    confidence = min(confidence, confidences[index])
                }
                word.append(character)
            }
        }
        commit()
        let decodedWords = convertTokensToText(tokenIds, vocabulary: vocabulary).split(whereSeparator: \.isWhitespace).count
        VoxLog.engine.debug("parakeet.word_timings unit=word inputTokens=\(tokenIds.count) decodedWhitespaceWords=\(decodedWords) outputWords=\(words.count)")
        return words
    }
}
