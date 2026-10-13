import Foundation

/// Word and character counting, matching the original's definition.
///
/// The original does not count CJK ideographs as words: it strips CJK punctuation,
/// splits on the remaining separators, and adds one per kana and per Hangul
/// syllable. Reproducing the rule matters because the reading-time estimate is
/// derived from it (`wordsPerMinutes`, default 382) and a reader comparing the two
/// apps would otherwise see the numbers disagree.
///
/// Ported from the original's `getWordCount`:
/// `/[\u3040-\uABFF\uD7A4-\uFAFF]/` -> one word each,
/// `/[( \u3000-\u303F)!-\/:-@\[-`{-~]+/` -> collapsed to a single separator,
/// then split on the remaining separator runs, minus the two empty ends.
public enum Counter {
    /// Kana and Hangul syllables: each character counts as one word.
    private static let syllabicRanges: [ClosedRange<UInt32>] = [
        0x3040...0xABFF,  // Kana, Hangul Jamo, CJK radicals, compatibility
        0xD7A4...0xFAFF,  // Hangul syllables and CJK compatibility ideographs
    ]

    /// CJK punctuation, which is dropped rather than treated as a separator.
    private static let cjkPunctuation: ClosedRange<UInt32> = 0x3000...0x303F

    public struct Count: Equatable, Sendable {
        public var words: Int
        public var characters: Int
        public var charactersNoSpaces: Int
        public var lines: Int
        /// Minutes at the configured reading speed, rounded up, 0 for short text.
        public var readingMinutes: Int

        public var summary: String {
            var parts = ["\(words) \(words == 1 ? "word" : "words")"]
            parts.append("\(characters) characters")
            if readingMinutes > 0 {
                parts.append("~\(readingMinutes) min read")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Counts a document from its plain text.
    public static func count(_ text: String, wordsPerMinute: Int = 382) -> Count {
        var syllabicWords = 0
        var buffer = ""
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if syllabicRanges.contains(where: { $0.contains(value) }) {
                syllabicWords += 1
                buffer.append(" ")
            } else if cjkPunctuation.contains(value) {
                buffer.append(" ")
            } else {
                buffer.unicodeScalars.append(scalar)
            }
        }

        // ASCII words are maximal runs of characters that are neither separators
        // nor syllabic. Separators terminate a run; they never start one, which is
        // why leading and trailing punctuation cost nothing.
        var asciiWords = 0
        var insideWord = false
        for scalar in buffer.unicodeScalars {
            let value = scalar.value
            if syllabicRanges.contains(where: { $0.contains(value) }) {
                insideWord = false
                continue
            }
            let isSeparator =
                value == 0x20 || value == 0x09 || value == 0x0A
                || value == 0x0D || value == 0x0B || value == 0x0C
                || (value >= 0x21 && value <= 0x2F)
                || (value >= 0x3A && value <= 0x40)
                || (value >= 0x5B && value <= 0x60)
                || (value >= 0x7B && value <= 0x7E)
            if isSeparator {
                insideWord = false
            } else if !insideWord {
                insideWord = true
                asciiWords += 1
            }
        }

        let total = syllabicWords + asciiWords
        let characters = text.count
        let charactersNoSpaces = text.unicodeScalars.filter { $0.value != 0x20 }.count
        let lines =
            text.isEmpty
            ? 0
            : text.reduce(into: 1) { count, character in
                if character == "\n" { count += 1 }
            }
        let minutes = wordsPerMinute > 0 ? (total + wordsPerMinute - 1) / wordsPerMinute : 0

        return Count(
            words: max(total, 0),
            characters: characters,
            charactersNoSpaces: charactersNoSpaces,
            lines: lines,
            readingMinutes: total < wordsPerMinute ? 0 : max(minutes, 0)
        )
    }

    /// Counts within a selection, so the status bar can report "42 of 1,200".
    public static func selection(_ selection: String, wordsPerMinute: Int = 382) -> Count {
        count(selection, wordsPerMinute: wordsPerMinute)
    }
}
