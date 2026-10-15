// Per-construct line matchers used by `BlockParser`.
//
// Each recogniser answers one question about a single line and returns the
// verbatim pieces the renderer needs. None of them rewrites the input, which is
// what keeps byte fidelity (see `BlockParser`).

import Foundation

// MARK: - ATX heading

enum ATXHeading {
    struct Match {
        var level: Int
        var text: String
    }

    /// `# Title`, `##Title##` (closing sequence), up to three leading spaces.
    static func match(_ content: String) -> Match? {
        var value = Substring(content)
        var spaces = 0
        while spaces < 3, value.first == " " {
            value = value.dropFirst()
            spaces += 1
        }
        var hashes = 0
        while hashes < 6, value.first == "#" {
            value = value.dropFirst()
            hashes += 1
        }
        guard hashes >= 1 else { return nil }
        // A space (or end of line) is required after the hashes.
        if value.first == "#" { return nil }
        guard let first = value.first, first == " " || first == "\t" else { return nil }
        var body = value
        // Strip one leading space run; the renderer re-adds a canonical one.
        while body.first == " " || body.first == "\t" { body = body.dropFirst() }
        // Strip an optional closing sequence of hashes.
        var trimmed = body[...]
        while trimmed.last == "#" { trimmed = trimmed.dropLast() }
        if trimmed.last == " " || trimmed.count != body.count {
            while trimmed.last == " " { trimmed = trimmed.dropLast() }
            if !trimmed.contains("#") { body = trimmed }
        }
        return Match(level: hashes, text: String(body))
    }
}

// MARK: - Setext heading

enum SetextHeading {
    /// `===` -> level 1, `---` -> level 2.
    static func level(for underline: String) -> Int? {
        let trimmed = underline.trimmingInlineWhitespace()
        guard !trimmed.isEmpty, trimmed.count >= 2 else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }
}

// MARK: - Horizontal rule

enum HorizontalRule {
    struct Match {
        var character: Character
        var length: Int
    }

    static func match(_ content: String) -> Match? {
        var value = Substring(content)
        var spaces = 0
        while spaces < 3, value.first == " " {
            value = value.dropFirst()
            spaces += 1
        }
        guard let first = value.first, "-*_".contains(first) else { return nil }
        var count = 0
        for character in value where character == first || character == " " || character == "\t" {
            if character == first { count += 1 }
        }
        guard count >= 3, value.allSatisfy({ $0 == first || $0 == " " || $0 == "\t" }) else {
            return nil
        }
        return Match(character: first, length: count)
    }
}

// MARK: - Fenced code

enum Fence {
    struct Opening {
        var character: Character
        var length: Int
        /// Everything after the opening run, verbatim.
        var info: String
        /// First word of `info`, lowercased - the language.
        var language: String
        var indent: Int
    }

    /// An opening fence needs three or more backticks/tildes and an info string
    /// that contains no backticks when the fence is a backtick fence.
    static func opening(in content: String, baseIndent: Int) -> Opening? {
        var value = Substring(content)
        var spaces = 0
        while spaces < 3, value.first == " " {
            value = value.dropFirst()
            spaces += 1
        }
        guard let marker = value.first, marker == "`" || marker == "~" else { return nil }
        var length = 0
        while length < value.count, value[value.index(value.startIndex, offsetBy: length)] == marker {
            length += 1
        }
        guard length >= 3 else { return nil }
        let info = String(value.dropFirst(length)).trimmingInlineWhitespace()
        if marker == "`", info.contains("`") { return nil }
        let language =
            info.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first
            .map { String($0).lowercased() } ?? ""
        return Opening(
            character: marker, length: length, info: info, language: language, indent: spaces
        )
    }

    /// Returns the closing run length when the line closes `opening`.
    static func closing(_ content: String, for opening: Opening) -> Int? {
        var value = Substring(content)
        var spaces = 0
        while spaces < 3, value.first == " " {
            value = value.dropFirst()
            spaces += 1
        }
        var length = 0
        while length < value.count,
            value[value.index(value.startIndex, offsetBy: length)] == opening.character
        {
            length += 1
        }
        guard length >= opening.length else { return nil }
        let rest = value.dropFirst(length)
        guard rest.trimmingInlineWhitespace().isEmpty else { return nil }
        return length
    }
}

// MARK: - Math block

enum MathFence {
    struct Opening {
        var open: String
        var close: String
        var tag: String?
        var isSingleLine: Bool
    }

    /// `$$`, `$${tag}`, `\[` - optionally on one line for the single-line form.
    static func opening(in content: String) -> Opening? {
        let trimmed = content.trimmingInlineWhitespace()
        if trimmed.hasPrefix("\\["), trimmed.hasSuffix("\\]"), trimmed.count > 4 {
            return Opening(open: "\\[", close: "\\]", tag: nil, isSingleLine: true)
        }
        guard trimmed.hasPrefix("$$") else { return nil }
        let body = trimmed.dropFirst(2)
        if body.hasSuffix("$$"), body.count >= 2 {
            let inner = body.dropLast(2).trimmingInlineWhitespace()
            return Opening(
                open: "$$", close: "$$", tag: parseTag(inner), isSingleLine: true
            )
        }
        return Opening(open: "$$", close: "$$", tag: parseTag(String(body)), isSingleLine: false)
    }

    /// `\[` opens the legacy (pre-MathJax-3) block form, closed by `\]`.
    static func isLegacyOpening(_ content: String) -> Bool {
        content.trimmingInlineWhitespace() == "\\["
    }

    static func closing(_ content: String) -> String? {
        let trimmed = content.trimmingInlineWhitespace()
        if trimmed == "$$" || trimmed == "\\]" { return trimmed }
        return nil
    }

    private static func parseTag(_ body: String) -> String? {
        let trimmed = body.trimmingInlineWhitespace()
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = trimmed.dropFirst().dropLast().trimmingInlineWhitespace()
        return inner.isEmpty ? nil : String(inner)
    }
}

// MARK: - Blockquote

enum Blockquote {
    static func isQuote(_ content: String, baseIndent: Int) -> Bool {
        var value = Substring(content)
        var spaces = 0
        while spaces < 3, value.first == " " {
            value = value.dropFirst()
            spaces += 1
        }
        _ = baseIndent
        guard value.first == ">" else { return false }
        // CommonMark: the marker must be followed by a space or end the line,
        // so `>not a quote` stays a paragraph.
        let rest = value.dropFirst()
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }
}

// MARK: - Alert

enum Alert {
    /// `> [!NOTE]` - Github-style callouts.
    static func match(_ content: String) -> AlertKind? {
        var value = Substring(content)
        while value.first == " " { value = value.dropFirst() }
        guard value.first == ">" else { return nil }
        value = value.dropFirst()
        while value.first == " " { value = value.dropFirst() }
        guard value.hasPrefix("[!") else { return nil }
        let body = value.dropFirst(2)
        guard let close = body.firstIndex(of: "]") else { return nil }
        let name = String(body[body.startIndex..<close])
        guard name.allSatisfy({ $0.isLetter }) else { return nil }
        return AlertKind(token: name)
    }
}

// MARK: - Table of contents

enum TableOfContents {
    /// `[TOC]`, `{:toc}`, `[[_TOC_]]`, `[toc]`.
    static func token(in content: String) -> String? {
        let trimmed = content.trimmingInlineWhitespace()
        if trimmed.lowercased() == "[toc]" { return trimmed }
        if trimmed == "{:toc}" { return trimmed }
        if trimmed == "[[_TOC_]]" { return trimmed }
        if trimmed == "[TOC]" { return trimmed }
        return nil
    }
}

// MARK: - Link and footnote definitions

enum LinkDefinition {
    struct Match {
        var isFootnote: Bool
        var label: String
        var destination: String
        var title: String?
    }

    /// `[label]: dest "title"` and `[^label]: body`.
    static func match(_ content: String) -> Match? {
        var value = Substring(content)
        while value.first == " " { value = value.dropFirst() }
        guard value.first == "[" else { return nil }

        let isFootnote = value.count > 1 && value.dropFirst().first == "^"
        let body = isFootnote ? value.dropFirst(2) : value.dropFirst()
        guard let close = body.firstIndex(of: "]") else { return nil }
        let label = String(body[body.startIndex..<close])
        guard !label.isEmpty else { return nil }
        let rest = body[body.index(after: close)...]
        guard rest.hasPrefix(":") else { return nil }
        var tail = rest.dropFirst()

        if isFootnote {
            let text = tail.trimmingInlineWhitespace()
            return Match(
                isFootnote: true, label: label, destination: "", title: text.isEmpty ? nil : text
            )
        }
        while tail.first == " " || tail.first == "\t" { tail = tail.dropFirst() }
        var destination = Substring(tail)
        if destination.first == "<" {
            guard let angle = destination.firstIndex(of: ">") else { return nil }
            destination = destination[destination.index(after: destination.startIndex)..<angle]
            tail = tail[tail.index(after: angle)...]
        } else {
            var cut = tail.endIndex
            for index in tail.indices where tail[index] == " " || tail[index] == "\t" {
                cut = index
                break
            }
            destination = tail[..<cut]
            tail = tail[cut...]
        }
        guard !destination.isEmpty else { return nil }
        var title: String?
        let remainder = tail.trimmingInlineWhitespace()
        if remainder.count >= 2, let quote = remainder.first,
            quote == "\"" || quote == "'", remainder.last == quote
        {
            title = String(remainder.dropFirst().dropLast())
        }
        return Match(
            isFootnote: false, label: label, destination: String(destination), title: title
        )
    }
}

// MARK: - HTML block

enum HTMLBlock {
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "canvas", "dd", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
        "h6", "header", "hr", "iframe", "li", "main", "nav", "noscript", "ol", "output",
        "p", "pre", "script", "section", "style", "table", "tbody", "td", "tfoot", "th",
        "thead", "tr", "ul", "video",
    ]

    static func isOpening(_ content: String) -> Bool {
        var value = Substring(content)
        while value.first == " " { value = value.dropFirst() }
        guard value.first == "<" else { return false }
        let body = value.dropFirst()
        if body.hasPrefix("!--") { return true }
        guard
            let tagEnd = body.firstIndex(where: {
                $0 == " " || $0 == ">" || $0 == "/"
                    || $0 == "\t" || $0 == "\n"
            })
        else { return false }
        let name = String(body[body.startIndex..<tagEnd]).lowercased()
        return blockTags.contains(name)
    }
}

// MARK: - List item

enum ListItem {
    struct Opening {
        var isOrdered: Bool
        var bullet: Character
        var delimiter: Character
        var startNumber: Int
        /// `nil` when the item has no `[ ]` marker at all; `true`/`false` for an
        /// unchecked/checked task.
        var taskState: Bool?
        /// Columns consumed by leading indentation plus the marker itself.
        var markerColumn: Int
        /// Column at which the item's content starts.
        var contentColumn: Int
    }

    /// Matches `- `, `* `, `+ `, `1. `, `1) `, `- [ ] `, `- [x] `.
    static func match(_ content: String, baseIndent: Int) -> Opening? {
        _ = baseIndent
        let characters = Array(content)
        var cursor = 0
        var indent = 0
        while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" {
            indent += characters[cursor] == "\t" ? 4 : 1
            cursor += 1
        }
        guard indent < 4, cursor < characters.count else { return nil }
        guard cursor < characters.count else { return nil }
        let marker = characters[cursor]

        var isOrdered = false
        var startNumber = 1
        var delimiter: Character = "."
        var bullet: Character = marker
        var afterMarker = cursor + 1

        if marker == "-" || marker == "*" || marker == "+" {
            bullet = marker
        } else if isASCIIDigit(marker) {
            // ASCII digits only. `Character.isNumber` is true for CJK numerals too, so
            // `二. 使用atomic.Value` parsed as an ordered item - which both mis-rendered
            // the paragraph and swallowed the blank line before it.
            var digits = cursor
            while digits < characters.count, isASCIIDigit(characters[digits]) { digits += 1 }
            guard digits > cursor, digits < characters.count,
                characters[digits] == "." || characters[digits] == ")"
            else { return nil }
            startNumber = Int(String(characters[cursor..<digits])) ?? 1
            isOrdered = true
            delimiter = characters[digits]
            afterMarker = digits + 1
        } else {
            return nil
        }

        // The marker must be followed by whitespace (or end the line).
        guard afterMarker < characters.count else { return nil }
        let separator = characters[afterMarker]
        guard separator == " " || separator == "\t" else { return nil }

        var contentStart = afterMarker + 1
        while contentStart < characters.count,
            characters[contentStart] == " " || characters[contentStart] == "\t"
        {
            contentStart += 1
        }
        var taskState: Bool?
        var hasTaskMarker = false
        if contentStart + 3 < characters.count,
            characters[contentStart] == "[",
            characters[contentStart + 2] == "]",
            characters[contentStart + 1] == " "
                || characters[contentStart + 1] == "x"
                || characters[contentStart + 1] == "X"
        {
            let flag = characters[contentStart + 1]
            taskState = flag == "x" || flag == "X"
            hasTaskMarker = true
            // The checkbox is *content*, not marker: `contentColumn` stays where the
            // item's text begins (CommonMark - and what makes
            // `  - [x] 子任务` a child of `- [ ] 阶段一` instead of a sibling).
        }

        return Opening(
            isOrdered: isOrdered,
            bullet: bullet,
            delimiter: delimiter,
            startNumber: startNumber,
            taskState: hasTaskMarker ? taskState : nil,
            markerColumn: afterMarker,
            contentColumn: contentStart
        )
    }
}

// MARK: - Table

enum TableRecognizer {
    struct Row {
        var cells: [String]
    }

    struct Parsed {
        var header: Row
        var delimiterRow: String
        var alignments: [TableState.ColumnAlignment]
        var body: [Row]
        var rowTexts: [String]
    }

    /// A table starts where a pipe-delimited row is immediately followed by a
    /// delimiter row of the same column count.
    static func match(rows: [String], at index: Int) -> Parsed? {
        guard index + 1 < rows.count else { return nil }
        let headerText = rows[index]
        let delimiterText = rows[index + 1]
        guard headerText.contains("|"), isDelimiterRow(delimiterText) else { return nil }

        let headerCells = split(headerText)
        let alignments = delimiterCells(delimiterText)
            .map { TableState.ColumnAlignment.parse($0) }
        guard !headerCells.isEmpty, alignments.count == headerCells.count else { return nil }

        var body: [Row] = []
        var cursor = index + 2
        while cursor < rows.count {
            let text = rows[cursor]
            guard text.contains("|"), !isDelimiterRow(text) else { break }
            body.append(parseRow(text))
            cursor += 1
        }

        var rowTexts: [String] = [headerText, delimiterText]
        rowTexts.append(contentsOf: rows[(index + 2)..<cursor])

        return Parsed(
            header: parseRow(headerText),
            delimiterRow: delimiterText,
            alignments: alignments,
            body: body,
            rowTexts: rowTexts
        )
    }

    /// Each cell is one or more dashes with optional `:` at either end.
    static func isDelimiterRow(_ content: String) -> Bool {
        let cells = delimiterCells(content)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            guard !cell.isEmpty, cell.contains("-") else { return false }
            return cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// Raw delimiter cells, with whitespace trimmed and the optional outer pipes
    /// removed.
    static func delimiterCells(_ content: String) -> [String] {
        var body = Substring(content.trimmingInlineWhitespace())
        if body.first == "|" { body = body.dropFirst() }
        if body.last == "|", body.count > 1 { body = body.dropLast() }
        return body.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingInlineWhitespace() }
    }

    /// Splits a row into cells, honouring `\|` escapes and keeping the leading
    /// and trailing pipe flags.
    static func split(_ content: String) -> [String] {
        parseRow(content).cells
    }

    static func parseRow(_ content: String) -> Row {
        let characters = Array(content)
        var cells: [String] = []
        var current = ""
        var sawContent = false
        var index = 0
        let pipeDelimited = content.trimmingInlineWhitespace().hasPrefix("|")

        func flush() {
            var trimmed = Substring(current)
            while trimmed.last == " " || trimmed.last == "\t" || trimmed.last == "\r" {
                trimmed = trimmed.dropLast()
            }
            cells.append(String(trimmed))
            current = ""
            sawContent = false
        }

        // Skip a leading pipe without starting an empty cell.
        var cursor = 0
        if pipeDelimited { cursor = 1 }
        index = cursor
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                current.append("|")
                sawContent = true
                index += 2
                continue
            }
            if character == "|" {
                flush()
                index += 1
                while index < characters.count,
                    characters[index] == " " || characters[index] == "\t"
                {
                    index += 1
                }
                continue
            }
            if !sawContent, character == " " || character == "\t" {
                index += 1
                continue
            }
            sawContent = true
            current.append(character)
            index += 1
        }
        flush()

        // A trailing `\r` (CRLF line) is source punctuation, not cell content.
        let trailingPipe = characters.last == "|"
        if trailingPipe, !cells.isEmpty, cells.last == "", cells.count > 1 {
            cells.removeLast()
        }
        return Row(cells: cells)
    }
}

/// ASCII `0`-`9`.
///
/// `Character.isNumber` is also true for CJK numerals, which made `二. 使用atomic.Value`
/// parse as an ordered list item - mis-rendering the paragraph and swallowing the blank
/// line in front of it.
private func isASCIIDigit(_ character: Character) -> Bool {
    character.isASCII && character.isNumber
}
