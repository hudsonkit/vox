import Testing
import VoxCore
@testable import HudsonSpeechEngine

struct ParakeetTextProcessingTests {
    @Test("Batch word timings group 83 model pieces into 41 whitespace words")
    func wordTimingsDoNotExposeSubwordPiecesAsWords() {
        var vocabulary: [Int: String] = [:]
        for index in 0..<41 {
            vocabulary[index * 2 + 1] = "▁word"
            vocabulary[index * 2 + 2] = String(index)
        }
        vocabulary[83] = "."
        let ids = Array(1...83)
        let text = ParakeetTextProcessing.convertTokensToText(ids, vocabulary: vocabulary)
        let words = ParakeetTextProcessing.createWordTimings(tokenIds: ids,
            timestamps: Array(0..<83), confidences: Array(repeating: 0.9, count: 83),
            tokenDurations: Array(repeating: 1, count: 83), vocabulary: vocabulary)
        #expect(text.split(whereSeparator: \.isWhitespace).count == 41)
        #expect(words.count == 41)
        #expect(words.last?.word == "word40.")
    }

    @Test("Word spans preserve token intervals and minimum piece confidence")
    func combinesPiecesPunctuationAndConfidence() {
        let words = ParakeetTextProcessing.createWordTimings(tokenIds: [1, 2, 3, 4],
            timestamps: [0, 1, 2, 5], confidences: [0.9, 0.7, 0.85, 0.99],
            tokenDurations: [1, 2, 1, 1], vocabulary: [1: "▁water", 2: "mel", 3: "on", 4: "."])
        #expect(words.count == 1)
        #expect(words.first?.word == "watermelon.")
        #expect(words.first?.start == 0)
        #expect(abs((words.first?.end ?? 0) - 0.48) < 1e-9)
        #expect(words.first?.confidence == 0.7)
    }

    @Test("Same-frame pieces preserve order and punctuation stays attached")
    func sameFramePiecesStayOrdered() {
        let words = ParakeetTextProcessing.createWordTimings(tokenIds: [1, 2, 3, 4, 5],
            timestamps: [2, 2, 2, 2, 3], confidences: [0.9, 0.8, 0.7, 0.6, 0.95],
            tokenDurations: [], vocabulary: [1: "▁can", 2: "'", 3: "t", 4: ",", 5: "▁stop!"])
        #expect(words.map(\.word) == ["can't,", "stop!"])
        #expect(words[0] == WordTiming(word: "can't,", start: 0.16, end: 0.24, confidence: 0.6))
    }

    @Test("Word grouping respects Unicode/whitespace and ignores missing vocabulary entries")
    func whitespaceAndMissingPiecesDoNotInventWords() {
        let ids = [1, 2, 99, 3, 4, 5]
        let words = ParakeetTextProcessing.createWordTimings(tokenIds: ids,
            timestamps: Array(0..<ids.count), confidences: [0.9, 0.8, 0.9, 0.01, 0.7, 0.6],
            tokenDurations: [], vocabulary: [1: "▁你", 2: "好", 3: "▁", 4: "世", 5: "界!\n"])
        #expect(words.map(\.word) == ["你好", "世界!"])
        #expect(words[1].start == 0.32, "A separator is not the next word's acoustic onset")
        #expect(words[1].confidence == 0.6, "Whitespace-only pieces do not affect word confidence")
    }

    @Test("One piece containing multiple words shares its source interval without invented subdivisions")
    func multiwordPieceRetainsItsActualInterval() {
        let words = ParakeetTextProcessing.createWordTimings(tokenIds: [1], timestamps: [2],
            confidences: [0.8], tokenDurations: [3], vocabulary: [1: "▁New▁York"])
        #expect(words.map(\.word) == ["New", "York"])
        #expect(words.allSatisfy { $0.start == 0.16 && $0.end == 0.4 && $0.confidence == 0.8 })
    }

    @Test("Incomplete alignment arrays return no timings instead of dropping the tail or fabricating data")
    func rejectsIncompleteAlignmentArrays() {
        let vocabulary = [1: "▁hello", 2: "▁tail"]
        for durations in [[1], [-1, 1]] {
            #expect(ParakeetTextProcessing.createWordTimings(tokenIds: [1, 2], timestamps: [1, 2],
                confidences: [0.9, 0.8], tokenDurations: durations, vocabulary: vocabulary).isEmpty)
        }
        #expect(ParakeetTextProcessing.createWordTimings(tokenIds: [1, 2], timestamps: [1],
            confidences: [0.9, 0.8], tokenDurations: [], vocabulary: vocabulary).isEmpty)
        #expect(ParakeetTextProcessing.createWordTimings(tokenIds: [1], timestamps: [-1],
            confidences: [0.9], tokenDurations: [], vocabulary: vocabulary).isEmpty)
    }

    @Test("SentencePiece tokens join into readable text")
    func convertsTokensToReadableText() {
        let vocabulary = [
            1: "▁hello",
            2: "▁world",
            3: "!"
        ]

        #expect(
            ParakeetTextProcessing.convertTokensToText([1, 2, 3], vocabulary: vocabulary) == "hello world!"
        )
    }

    @Test("Word timings drop blank tokens and map frame durations")
    func createsWordTimingsFromDecoderOutputs() {
        let vocabulary = [
            1: "▁hello",
            2: "▁world",
            3: "▁"
        ]

        let timings = ParakeetTextProcessing.createWordTimings(
            tokenIds: [2, 3, 1],
            timestamps: [5, 6, 1],
            confidences: [0.8, 0.2, 0.9],
            tokenDurations: [2, 1, 1],
            vocabulary: vocabulary
        )

        #expect(timings.count == 2)
        #expect(timings[0] == WordTiming(word: "hello", start: 0.08, end: 0.16, confidence: 0.9))
        #expect(timings[1] == WordTiming(word: "world", start: 0.4, end: 0.56, confidence: 0.8))
    }
}
