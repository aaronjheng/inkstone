import Foundation

/// Display-width arithmetic for CJK text.
///
/// Table column widths and list indentation are measured in *columns*, not
/// characters: a CJK ideograph occupies two. This is a pure string algorithm -
/// no font metrics are involved - which is what keeps `Markdown/` free of any
/// AppKit dependency.
public enum DisplayWidth {
    /// Display columns occupied by `text`.
    static func columns(_ text: String) -> Int {
        var total = 0
        for character in text {
            total += columns(character)
        }
        return total
    }

    /// Display columns occupied by a single extended grapheme cluster.
    ///
    /// Zero for combining marks (so a base plus its diacritics counts once) and
    /// for the variation selectors and zero-width joiner that emoji sequences
    /// are built from; otherwise two for East Asian Wide and Fullwidth, one
    /// for everything else.
    static func columns(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if character.unicodeScalars.count > 1 {
            // A cluster: count only the scalars that carry advance.
            return character.unicodeScalars.reduce(0) { $0 + column(for: $1) }
        }
        return column(for: scalar)
    }

    private static func column(for scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x0300...0x036F,  // combining diacritical marks
            0x1AB0...0x1AFF,
            0x1DC0...0x1DFF,
            0x20D0...0x20FF,
            0xFE00...0xFE0F,  // variation selectors
            0xFE20...0xFE2F,
            0x200B...0x200F,  // zero-width space/joiners, bidi controls
            0x2060...0x2064:
            return 0
        default:
            return isWide(scalar) ? 2 : 1
        }
    }

    /// East Asian Wide (W) and Fullwidth (F) ranges, plus emoji that render
    /// double-width in a monospaced grid.
    static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        switch value {
        case 0x1100...0x115F,  // Hangul Jamo
            0x2E80...0x303E,  // CJK radicals, Kangxi, CJK symbols
            0x3041...0x33FF,  // Hiragana .. CJK compatibility
            0x3400...0x4DBF,  // CJK extension A
            0x4E00...0x9FFF,  // CJK unified ideographs
            0xA000...0xA4CF,  // Yi
            0xAC00...0xD7A3,  // Hangul syllables
            0xF900...0xFAFF,  // CJK compatibility ideographs
            0xFE10...0xFE19,  // vertical forms
            0xFE30...0xFE6F,  // CJK compatibility forms
            0xFF00...0xFF60,  // fullwidth forms
            0xFFE0...0xFFE6,
            0x1F300...0x1F64F,  // emoji
            0x1F900...0x1F9FF,
            0x20000...0x3FFFD:  // CJK extension B+
            return true
        default:
            return false
        }
    }
}
