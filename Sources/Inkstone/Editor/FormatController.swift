import AppKit
import Foundation

/// The commands the Paragraph and Format menus dispatch.
///
/// Raw values ride along as the menu items' `representedObject`, so one action
/// covers every entry: `AppDelegate` looks the value up and hands it to the
/// focused window, which runs it against the editor.
enum FormatAction: String {
    case bold, italic, underline, inlineCode, strikethrough, highlight, inlineMath
    case superscript, `subscript`
    case link, image, clearFormat
    case heading1, heading2, heading3, heading4, heading5, heading6
    case paragraph, increaseHeading, decreaseHeading
    case quote, bulletList, orderedList, taskList
    case codeBlock, mathBlock, table, horizontalRule, tableOfContents, frontMatter
    case footnote
    case tableRowAbove, tableRowBelow, tableDeleteRow
    case tableColumnLeft, tableColumnRight, tableDeleteColumn
    case tableAlignLeft, tableAlignCenter, tableAlignRight
    case indent, outdent

    /// The command for a heading level, for menus that build rows in a loop.
    static func heading(_ level: Int) -> FormatAction {
        switch level {
        case 1: return .heading1
        case 2: return .heading2
        case 3: return .heading3
        case 4: return .heading4
        case 5: return .heading5
        default: return .heading6
        }
    }
}

/// Typora-faithful format commands over the Markdown buffer.
///
/// Every command is a pure rewrite - text and selection in, one replacement slice
/// plus the new selection out - so the result can be reasoned about without a text
/// view and applied as a single undo step by `MarkdownTextView.apply(_:)`. The
/// buffer *is* the Markdown source byte for byte (markers are zero-width on
/// screen, never absent), so these commands edit source markers directly rather
/// than attributed text.
enum FormatController {
    /// A computed rewrite of `range`; an empty range is an insertion.
    struct Edit {
        var range: NSRange
        var text: String
        var selection: NSRange
    }

    /// A rewrite that changes nothing, for the states where a toggle is a no-op
    /// (indent is not a text edit) or already applied.
    static let noOp = Edit(
        range: NSRange(location: 0, length: 0),
        text: "",
        selection: NSRange(location: 0, length: 0)
    )

    static func edit(for action: FormatAction, in text: String, range: NSRange) -> Edit {
        switch action {
        case .bold: return toggleInline(.bold, in: text, range: range)
        case .italic: return toggleInline(.italic, in: text, range: range)
        case .underline: return toggleInline(.underline, in: text, range: range)
        case .inlineCode: return toggleInline(.code, in: text, range: range)
        case .strikethrough: return toggleInline(.strikethrough, in: text, range: range)
        case .highlight: return toggleInline(.highlight, in: text, range: range)
        case .inlineMath: return toggleInline(.inlineMath, in: text, range: range)
        case .superscript: return toggleInline(.superscript, in: text, range: range)
        case .`subscript`: return toggleInline(.`subscript`, in: text, range: range)
        case .link: return insertLink(in: text, range: range)
        case .image: return insertImage(in: text, range: range)
        case .clearFormat: return clearFormat(in: text, range: range)
        case .heading1: return setHeading(1, in: text, range: range)
        case .heading2: return setHeading(2, in: text, range: range)
        case .heading3: return setHeading(3, in: text, range: range)
        case .heading4: return setHeading(4, in: text, range: range)
        case .heading5: return setHeading(5, in: text, range: range)
        case .heading6: return setHeading(6, in: text, range: range)
        case .paragraph: return toParagraph(in: text, range: range)
        case .increaseHeading: return increaseHeading(in: text, range: range)
        case .decreaseHeading: return decreaseHeading(in: text, range: range)
        case .quote: return toggleQuote(in: text, range: range)
        case .bulletList: return toggleBulletList(in: text, range: range)
        case .orderedList: return toggleOrderedList(in: text, range: range)
        case .taskList: return toggleTaskList(in: text, range: range)
        case .codeBlock: return toggleFencedBlock("```", in: text, range: range)
        case .mathBlock: return toggleFencedBlock("$$", in: text, range: range)
        case .table: return insertTable(in: text, range: range)
        case .horizontalRule: return insertHorizontalRule(in: text, range: range)
        case .tableOfContents: return insertTableOfContents(in: text, range: range)
        case .frontMatter: return insertFrontMatter(in: text, range: range)
        case .footnote: return insertFootnote(in: text, range: range)
        case .tableRowAbove: return insertTableRow(above: true, in: text, range: range)
        case .tableRowBelow: return insertTableRow(above: false, in: text, range: range)
        case .tableDeleteRow: return deleteTableRow(in: text, range: range)
        case .tableColumnLeft: return insertTableColumn(left: true, in: text, range: range)
        case .tableColumnRight: return insertTableColumn(left: false, in: text, range: range)
        case .tableDeleteColumn: return deleteTableColumn(in: text, range: range)
        case .tableAlignLeft: return alignTableColumn(.left, in: text, range: range)
        case .tableAlignCenter: return alignTableColumn(.center, in: text, range: range)
        case .tableAlignRight: return alignTableColumn(.right, in: text, range: range)
        // Indentation needs the caret's column inside its line, which is a
        // property of the view rather than the text; the editor routes these.
        case .indent, .outdent: return noOp
        }
    }

    // MARK: - Inline

    enum InlineKind {
        case bold, italic, underline, code, strikethrough, highlight, inlineMath
        case superscript, `subscript`

        /// Candidate pairs, longest first: `**` must be tried before `*`, or
        /// `**bold**` would be mistaken for italic.
        var pairs: [(String, String)] {
            switch self {
            case .bold: return [("**", "**"), ("__", "__")]
            case .italic: return [("*", "*"), ("_", "_")]
            case .underline: return [("<u>", "</u>")]
            case .code: return [("``", "``"), ("`", "`")]
            case .strikethrough: return [("~~", "~~"), ("~", "~")]
            case .highlight: return [("==", "==")]
            case .inlineMath: return [("$", "$")]
            case .superscript: return [("^", "^")]
            case .`subscript`: return [("~", "~")]
            }
        }
    }

    /// Wraps, or unwraps, the selection with an inline marker.
    ///
    /// Unwrapping looks both inside the selection (markers selected along with the
    /// text) and just outside it (markers left behind, caret sitting on the word),
    /// because both are what a user produces before pressing the shortcut again.
    private static func toggleInline(_ kind: InlineKind, in text: String, range: NSRange) -> Edit {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(range.length, ns.length - location)

        for (open, close) in kind.pairs where isWrappedBy(open, close, at: location, length: length, in: ns) {
            let full = NSRange(
                location: location - open.utf16.count,
                length: open.utf16.count + length + close.utf16.count
            )
            // The markers go, the selection stays: the slice covered markers plus
            // text, so the replacement is the text itself.
            let selected = ns.substring(with: NSRange(location: location, length: length))
            return Edit(
                range: full,
                text: selected,
                selection: NSRange(location: full.location, length: length)
            )
        }

        if length > 0 {
            let selected = ns.substring(with: NSRange(location: location, length: length))
            for (open, close) in kind.pairs
            where selected.count >= open.count + close.count
                && selected.hasPrefix(open) && selected.hasSuffix(close)
            {
                let body = String(
                    selected.dropFirst(open.count).dropLast(close.count)
                )
                return Edit(
                    range: NSRange(location: location, length: length),
                    text: body,
                    selection: NSRange(location: location, length: body.utf16.count)
                )
            }
        }

        let (open, close) = kind.pairs[0]
        let selected = ns.substring(with: NSRange(location: location, length: length))
        return Edit(
            range: NSRange(location: location, length: length),
            text: open + selected + close,
            // An empty selection gets the caret between the markers, where typing
            // lands inside the emphasis rather than after it.
            selection: NSRange(location: location + open.utf16.count, length: length)
        )
    }

    /// Whether `open` ends where the selection starts and its `close` begins
    /// where the selection ends - markers left behind by an earlier toggle.
    private static func isWrappedBy(
        _ open: String, _ close: String, at location: Int, length: Int, in ns: NSString
    ) -> Bool {
        guard location >= open.utf16.count else { return false }
        return startsWith(ns, open, at: location - open.utf16.count)
            && startsWith(ns, close, at: location + length)
    }

    // MARK: - Headings

    private static func setHeading(_ level: Int, in text: String, range: NSRange) -> Edit {
        mapLines(in: text, range: range) { _, line in
            let current = heading(of: line)
            // Same level twice is the toggle off the original always had.
            guard current.level != level else { return current.body }
            return String(repeating: "#", count: level) + " " + current.body
        }
    }

    /// One level deeper; a level-6 line stays where it is.
    private static func increaseHeading(in text: String, range: NSRange) -> Edit {
        mapLines(in: text, range: range) { _, line in
            let current = heading(of: line)
            guard current.level < 6 else { return line }
            return String(repeating: "#", count: current.level + 1) + " " + current.body
        }
    }

    /// One level shallower; a level-1 line drops to a paragraph, as in the original.
    private static func decreaseHeading(in text: String, range: NSRange) -> Edit {
        mapLines(in: text, range: range) { _, line in
            let current = heading(of: line)
            guard current.level > 1 else { return current.body }
            return String(repeating: "#", count: current.level - 1) + " " + current.body
        }
    }

    /// The line's heading level, and the body after the marker.
    private static func heading(of line: String) -> (level: Int, body: String) {
        var hashes = 0
        for character in line where character == "#" {
            hashes += 1
            if hashes == 6 { break }
        }
        guard hashes > 0 else { return (0, line) }
        let rest = String(line.dropFirst(hashes))
        guard rest.isEmpty || rest.first == " " else { return (0, line) }
        return (hashes, rest.isEmpty ? rest : String(rest.dropFirst()))
    }

    // MARK: - Block prefixes

    private static func toParagraph(in text: String, range: NSRange) -> Edit {
        mapLines(in: text, range: range) { _, line in
            var body = line
            while body.hasPrefix("> ") || body == ">" {
                body = body == ">" ? "" : String(body.dropFirst(2))
            }
            if let marker = listMarker(of: body) {
                body = String(body.dropFirst(marker.count))
            }
            return heading(of: body).body
        }
    }

    private static func toggleQuote(in text: String, range: NSRange) -> Edit {
        let span = span(of: range, in: text as NSString)
        let everyLineQuoted = span.lines.allSatisfy { line in
            line.isEmpty || line == ">" || line.hasPrefix("> ")
        }
        return mapLines(in: text, range: range) { _, line in
            guard !line.isEmpty else { return line }
            if everyLineQuoted {
                return line == ">" ? "" : String(line.dropFirst(2))
            }
            return "> " + line
        }
    }

    private static func toggleBulletList(in text: String, range: NSRange) -> Edit {
        let span = span(of: range, in: text as NSString)
        let everyLineItem = span.lines.allSatisfy { $0.isEmpty || listMarker(of: $0) != nil }
        return mapLines(in: text, range: range) { _, line in
            guard !line.isEmpty else { return line }
            if everyLineItem, let marker = listMarker(of: line) {
                return String(line.dropFirst(marker.count))
            }
            if listMarker(of: line) != nil { return line }
            return "- " + line
        }
    }

    private static func toggleOrderedList(in text: String, range: NSRange) -> Edit {
        let span = span(of: range, in: text as NSString)
        // "Already ordered" means every line carries one: an unmarked line lets a
        // plain line sit inside an ordered selection without being counted.
        let everyLineOrdered = span.lines.allSatisfy { line in
            guard !line.isEmpty else { return true }
            guard let marker = listMarker(of: line) else { return false }
            return marker.hasSuffix(". ") || marker.hasSuffix(") ")
        }
        var number = 0
        return mapLines(in: text, range: range) { _, line in
            guard !line.isEmpty else { return line }
            if everyLineOrdered {
                if let marker = listMarker(of: line) {
                    return String(line.dropFirst(marker.count))
                }
                return line
            }
            number += 1
            if let marker = listMarker(of: line) {
                return "\(number). " + String(line.dropFirst(marker.count))
            }
            return "\(number). " + line
        }
    }

    private static func toggleTaskList(in text: String, range: NSRange) -> Edit {
        let span = span(of: range, in: text as NSString)
        let everyLineTask = span.lines.allSatisfy { line in
            line.isEmpty || line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ")
                || line.hasPrefix("- [X] ")
        }
        return mapLines(in: text, range: range) { _, line in
            guard !line.isEmpty else { return line }
            if everyLineTask { return String(line.dropFirst(6)) }
            if let marker = listMarker(of: line) {
                return "- [ ] " + String(line.dropFirst(marker.count))
            }
            return "- [ ] " + line
        }
    }

    /// The leading list marker of a line, or `nil` when it is not a list item.
    private static func listMarker(of line: String) -> String? {
        for marker in ["- [ ] ", "- [x] ", "- [X] "] where line.hasPrefix(marker) {
            return marker
        }
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return marker
        }
        let digits = line.prefix { $0.isNumber }
        let rest = line.dropFirst(digits.count)
        if !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return String(digits) + String(rest.prefix(2))
        }
        return nil
    }

    // MARK: - Fenced blocks

    /// Wraps the selected lines in a fence, or unwraps them when already fenced.
    ///
    /// The fence sits on its own lines outside the selection, so a multi-line
    /// selection becomes one block; the caret stays at its column inside the text.
    private static func toggleFencedBlock(_ fence: String, in text: String, range: NSRange) -> Edit {
        let ns = text as NSString
        let span = span(of: range, in: ns)
        let index = lineIndex(for: range.location, in: span)
        let offsetInLine = range.location - span.lineStarts[index]

        let wrapped = [fence] + span.lines + [fence]
        let unwrapped =
            span.lines.count >= 2
                && span.lines.first?.hasPrefix(fence) == true
                && span.lines.last?.hasPrefix(fence) == true
            ? Array(span.lines.dropFirst().dropLast())
            : nil

        if let body = unwrapped, !body.isEmpty {
            let text = body.joined(separator: "\n")
            let starts = lineStarts(of: body, from: span.range.location)
            let newIndex = max(0, min(index - 1, body.count - 1))
            // The caret keeps its column on the corresponding line, clamped to the
            // *new* text - the old selection carried the pre-edit length, which
            // selected whole paragraphs after unwrapping.
            let caret = min(starts[newIndex] + offsetInLine, text.utf16.count)
            return Edit(
                range: span.range,
                text: text,
                selection: NSRange(location: caret, length: 0)
            )
        }

        let starts = lineStarts(of: wrapped, from: span.range.location)
        return Edit(
            range: span.range,
            text: wrapped.joined(separator: "\n"),
            selection: NSRange(location: starts[index + 1] + offsetInLine, length: range.length)
        )
    }

    // MARK: - Inserts

    /// `[](url)` with the destination selected, so typing replaces it and path
    /// completion (which triggers on `/` inside parentheses) kicks in.
    private static func insertLink(in text: String, range: NSRange) -> Edit {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(range.length, ns.length - location)
        let selected =
            length > 0
            ? ns.substring(with: NSRange(location: location, length: length))
            : ""

        // A URL in hand is the destination; the link text stays empty until typed.
        if selected.contains("://") || selected.hasPrefix("www.") {
            return Edit(
                range: NSRange(location: location, length: length),
                text: "[](\(selected))",
                selection: NSRange(location: location + 3, length: 0)
            )
        }
        let inserted = "[\(selected)](url)"
        return Edit(
            range: NSRange(location: location, length: length),
            text: inserted,
            selection: NSRange(
                location: location + selected.utf16.count + 2 + 1,
                length: 3
            )
        )
    }

    /// `![](path)` with the path selected, same completion affordance as a link.
    private static func insertImage(in text: String, range: NSRange) -> Edit {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(range.length, ns.length - location)
        return Edit(
            range: NSRange(location: location, length: length),
            text: "![](path)",
            selection: NSRange(location: location + 4, length: 4)
        )
    }

    /// Unwraps every inline marker and block prefix inside the selection.
    private static func clearFormat(in text: String, range: NSRange) -> Edit {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(range.length, ns.length - location)
        guard length > 0 else { return noOp }

        var body = ns.substring(with: NSRange(location: location, length: length))
        let original = body
        // Repeatedly drop the innermost-leftmost marker pair, so nested markers
        // shed from the outside in: `**bold ~~struck~~**` loses both layers.
        for _ in 0..<16 where !unwrapFirst(in: &body) { break }
        let stripped =
            body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var text = String(line)
                while text.hasPrefix("> ") || text == ">" {
                    text = text == ">" ? "" : String(text.dropFirst(2))
                }
                if let marker = listMarker(of: text) {
                    text = String(text.dropFirst(marker.count))
                }
                return heading(of: text).body
            }
            .joined(separator: "\n")
        // Compared against what was selected, not the already-unwrapped body:
        // shedding markers alone is a change worth an undo step.
        guard stripped != original else { return noOp }
        return Edit(
            range: NSRange(location: location, length: length),
            text: stripped,
            selection: NSRange(location: location, length: stripped.utf16.count)
        )
    }

    /// Drops the leftmost matching marker pair from `body`.
    ///
    /// Kinds are tried longest-marker first, so `**` is consumed before `*` and
    /// emphasis survives inside bold. The first open marker pairs with its first
    /// following close, which unwraps nesting from the outside in across calls.
    private static func unwrapFirst(in body: inout String) -> Bool {
        for kind in [
            InlineKind.bold, .italic, .underline, .code, .strikethrough, .highlight,
            .inlineMath, .superscript, .`subscript`,
        ] {
            for (open, close) in kind.pairs {
                guard let openRange = body.range(of: open) else { continue }
                guard
                    let closeRange = body.range(
                        of: close, range: openRange.upperBound..<body.endIndex
                    )
                else { continue }
                body.removeSubrange(closeRange)
                body.removeSubrange(openRange)
                return true
            }
        }
        return false
    }

    private static func insertTable(in text: String, range: NSRange) -> Edit {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let template =
            "\n| Column 1 | Column 2 | Column 3 |\n| --- | --- | --- |\n|  |  |  |\n"
        // Caret lands in the first data cell, where the original puts it.
        let caret = "\n| Column 1 | Column 2 | Column 3 |\n| --- | --- | --- |\n| ".utf16.count
        return Edit(
            range: NSRange(location: location, length: 0),
            text: template,
            selection: NSRange(location: location + caret, length: 0)
        )
    }

    private static func insertHorizontalRule(in text: String, range: NSRange) -> Edit {
        let location = min(max(range.location, 0), (text as NSString).length)
        return Edit(
            range: NSRange(location: location, length: 0),
            text: "\n---\n",
            selection: NSRange(location: location + 5, length: 0)
        )
    }

    private static func insertTableOfContents(in text: String, range: NSRange) -> Edit {
        let location = min(max(range.location, 0), (text as NSString).length)
        return Edit(
            range: NSRange(location: location, length: 0),
            text: "\n[TOC]\n",
            selection: NSRange(location: location + 7, length: 0)
        )
    }

    /// A YAML front matter block, unless the document already opens with one.
    private static func insertFrontMatter(in text: String, range: NSRange) -> Edit {
        guard !text.hasPrefix("---\n") else { return noOp }
        let block = "---\ntitle: Untitled\n---\n\n"
        let caret = "---\ntitle: ".utf16.count
        return Edit(
            // Front matter is a document header: the edit always sits at the top.
            range: NSRange(location: 0, length: 0),
            text: block,
            selection: NSRange(location: caret, length: 0)
        )
    }

    // MARK: - Footnote

    /// Inserts a `[^n]` reference at the caret and its definition at the end of
    /// the document, where the original puts it.
    ///
    /// The number is one past the highest numeric reference already in the
    /// buffer, so repeated inserts never collide. A selection becomes the
    /// definition's body and is replaced by the reference. The rewrite spans
    /// from the caret to the end of the document - the only shape `Edit` can
    /// express for two distant insertions - so it stays one undo step.
    private static func insertFootnote(in text: String, range: NSRange) -> Edit {
        let ns = text as NSString
        let location = min(max(range.location, 0), ns.length)
        let length = min(range.length, ns.length - location)
        let selected = length > 0 ? ns.substring(with: NSRange(location: location, length: length)) : ""

        var number = 0
        if let pattern = try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#, options: []) {
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            where match.numberOfRanges > 1 {
                number = max(number, Int(ns.substring(with: match.range(at: 1))) ?? 0)
            }
        }
        number += 1

        let tail = ns.substring(from: location + length)
        // The definition goes at the very end. When the caret is already
        // there it still needs its own block: probing `text` found the blank
        // line the reference sits on and emitted nothing, gluing `[^n][^n]:`.
        let separator: String
        if tail.isEmpty {
            separator = "\n\n"
        } else if tail.hasSuffix("\n\n") { separator = "" } else if tail.hasSuffix("\n") {
            separator = "\n"
        } else { separator = "\n\n" }
        let ref = "[^\(number)]"
        return Edit(
            range: NSRange(location: location, length: ns.length - location),
            text: ref + tail + separator + "[^\(number)]: " + selected,
            selection: NSRange(location: location + (ref as NSString).length, length: 0)
        )
    }

    // MARK: - Task checkbox

    /// Flips a task item's `[ ]` / `[x]` marker on the line holding `location`.
    ///
    /// The caller hit-tests the painted checkbox; this only rewrites the one
    /// flag character, so every offset survives and the incoming selection is
    /// kept verbatim.
    static func toggleTask(at location: Int, selection: NSRange, in text: String) -> Edit {
        let ns = text as NSString
        let caret = min(max(location, 0), ns.length)
        var lineStart = caret
        while lineStart > 0 && ns.character(at: lineStart - 1) != 10 { lineStart -= 1 }
        var lineEnd = caret
        while lineEnd < ns.length && ns.character(at: lineEnd) != 10 { lineEnd += 1 }
        let line = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart)) as NSString
        var flag: Int?
        var index = 0
        while index + 2 < line.length {
            if line.character(at: index) == 91 {
                let middle = line.character(at: index + 1)
                if (middle == 32 || middle == 120 || middle == 88) && line.character(at: index + 2) == 93 {
                    flag = lineStart + index + 1
                    break
                }
            }
            index += 1
        }
        guard let marker = flag else { return noOp }
        let replacement = ns.character(at: marker) == 32 ? "x" : " "
        let clamped =
            NSMaxRange(selection) <= ns.length
            ? selection : NSRange(location: min(selection.location, ns.length), length: 0)
        return Edit(range: NSRange(location: marker, length: 1), text: replacement, selection: clamped)
    }

    // MARK: - Pipe table operations
    /// A pipe table under the caret, addressed in buffer coordinates.
    private struct PipeTable {
        /// Source lines: header, delimiter, then body rows, `\r` stripped.
        var lines: [String]
        /// Whole table span in the buffer, without a trailing newline.
        var range: NSRange
        var alignments: [TableState.ColumnAlignment]
        var columnCount: Int
        /// Caret's row: 0 is the header, 1 the delimiter, 2+ the body.
        var caretRow: Int
        var caretColumn: Int
        /// Any row ended `\r\n`: rewritten rows keep the carriage return so a
        /// CRLF table is not silently converted to LF.
        var usesCarriageReturn: Bool
    }

    /// Whether `location` sits on a pipe table. The context menu uses this to
    /// decide if the table operations apply, instead of offering dead items.
    static func containsTable(at location: Int, in text: String) -> Bool {
        pipeTable(at: location, in: text) != nil
    }

    /// The pipe table holding `location`, or `nil` when the caret is not on one.
    ///
    /// Expansion mirrors the parser: contiguous non-blank lines containing `|`,
    /// validated by the same recogniser, so an operation never fires on text the
    /// renderer shows as a paragraph.
    private static func pipeTable(at location: Int, in text: String) -> PipeTable? {
        let ns = text as NSString
        let caret = min(max(location, 0), ns.length)
        var lineStart = caret
        while lineStart > 0 && ns.character(at: lineStart - 1) != 10 { lineStart -= 1 }
        var lineEnd = caret
        while lineEnd < ns.length && ns.character(at: lineEnd) != 10 { lineEnd += 1 }
        let caretLine = ns.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
        guard caretLine.contains("|") else { return nil }

        var top = lineStart
        var scan = top
        while scan > 0 {
            let previousEnd = scan - 1
            var previousStart = previousEnd
            while previousStart > 0 && ns.character(at: previousStart - 1) != 10 {
                previousStart -= 1
            }
            let previous = ns.substring(
                with: NSRange(location: previousStart, length: previousEnd - previousStart)
            )
            guard !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, previous.contains("|") else { break }
            top = previousStart
            scan = previousStart
        }
        var bottom = lineEnd
        scan = bottom
        while scan < ns.length {
            let nextStart = scan + 1
            guard nextStart <= ns.length else { break }
            var nextEnd = nextStart
            while nextEnd < ns.length && ns.character(at: nextEnd) != 10 { nextEnd += 1 }
            let next =
                nextStart < nextEnd
                ? ns.substring(with: NSRange(location: nextStart, length: nextEnd - nextStart)) : ""
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, next.contains("|") else { break }
            bottom = nextEnd
            scan = nextEnd
        }

        var lines: [String] = []
        var starts: [Int] = []
        var offset = top
        // A table starts its block: prose directly above means these rows are
        // lazy paragraph continuation (the parser has no table check in
        // `terminatesParagraph`), not a table the renderer shows.
        guard top <= 1 || ns.character(at: top - 2) == 10 else { return nil }
        while offset <= bottom {
            var stop = offset
            while stop < bottom && ns.character(at: stop) != 10 { stop += 1 }
            lines.append(ns.substring(with: NSRange(location: offset, length: stop - offset)))
            starts.append(offset)
            if stop >= bottom { break }
            offset = stop + 1
        }
        // The parser strips `\r` before matching; recognising the raw lines
        // would disagree with it on column counts (and every rewrite after).
        // Untouched rows replay verbatim, so only recognition works stripped.
        let stripped = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard stripped.count >= 2,
            let parsed = TableRecognizer.match(rows: stripped, at: 0)
        else { return nil }
        // The recogniser stops the table at a second delimiter row or a row
        // without pipes; only its rows are the table.
        let rowCount = parsed.rowTexts.count
        guard rowCount >= 2 else { return nil }
        var caretRow: Int?
        for index in 0..<rowCount where starts[index] == lineStart { caretRow = index }
        guard let row = caretRow else { return nil }
        let alignments = parsed.alignments
        let caretStripped = caretLine.hasSuffix("\r") ? String(caretLine.dropLast()) : caretLine
        let end = starts[rowCount - 1] + (lines[rowCount - 1] as NSString).length
        return PipeTable(
            lines: Array(stripped.prefix(rowCount)),
            range: NSRange(location: top, length: end - top),
            alignments: alignments,
            columnCount: alignments.count,
            caretRow: row,
            caretColumn: columnIndex(
                in: caretStripped, caretOffset: min(caret - lineStart, (caretStripped as NSString).length),
                columns: alignments.count),
            usesCarriageReturn: lines.contains { $0.hasSuffix("\r") }
        )
    }

    /// Which cell the caret sits in: unescaped pipes before it, minus the
    /// leading pipe when the row opens with one.
    private static func columnIndex(in line: String, caretOffset: Int, columns: Int) -> Int {
        guard columns > 0 else { return 0 }
        let ns = line as NSString
        let caret = min(max(caretOffset, 0), ns.length)
        var pipesBefore = 0
        var index = 0
        while index < caret {
            // A backslash escapes the next character, `\|` included.
            if ns.character(at: index) == 92 {
                index += 2
                continue
            }
            if ns.character(at: index) == 124 { pipesBefore += 1 }
            index += 1
        }
        let leading = line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
        return min(max(pipesBefore - (leading ? 1 : 0), 0), columns - 1)
    }

    /// UTF-16 offset of the `column`-th cell's content start within `line`.
    private static func cellContentOffset(in line: String, column: Int) -> Int {
        let ns = line as NSString
        let length = ns.length
        var pipes: [Int] = []
        var index = 0
        while index < length {
            if ns.character(at: index) == 92 {
                index += 2
                continue
            }
            if ns.character(at: index) == 124 { pipes.append(index) }
            index += 1
        }
        let leading = line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
        let afterPipe: Int
        if leading {
            guard column < pipes.count else { return length }
            afterPipe = pipes[column] + 1
        } else if column == 0 {
            afterPipe = 0
        } else {
            guard column - 1 < pipes.count else { return length }
            afterPipe = pipes[column - 1] + 1
        }
        var content = afterPipe
        while content < length && (ns.character(at: content) == 32 || ns.character(at: content) == 9) {
            content += 1
        }
        return min(content, length)
    }

    private static func paddedCells(_ row: String, count: Int) -> [String] {
        var cells = TableRecognizer.split(row)
        while cells.count < count { cells.append("") }
        return cells
    }

    private static func pipeRow(_ cells: [String]) -> String {
        // Cells arrive unescaped (`\|` became `|` in the split); a bare pipe
        // would split the cell again on rewrite and change what it says.
        let escaped = cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }
        return "| " + escaped.joined(separator: " | ") + " |"
    }

    private static func alignmentMarker(_ alignment: TableState.ColumnAlignment) -> String {
        switch alignment {
        case .none: return "---"
        case .left: return ":---"
        case .center: return ":---:"
        case .right: return "---:"
        }
    }

    /// Rewrites the whole table span and parks the caret at the target cell's
    /// content start. Untouched rows keep their exact source; only inserted or
    /// structurally changed rows are emitted canonically.
    private static func finishTableEdit(
        table: PipeTable, lines: [String], row: Int, column: Int, columns: Int
    ) -> Edit {
        let final = table.usesCarriageReturn ? lines.map { $0 + "\r" } : lines
        let text = final.joined(separator: "\n")
        let starts = lineStarts(of: final, from: table.range.location)
        let targetRow = min(max(row, 0), final.count - 1)
        let targetColumn = min(max(column, 0), max(columns - 1, 0))
        let caret = starts[targetRow] + cellContentOffset(in: final[targetRow], column: targetColumn)
        return Edit(range: table.range, text: text, selection: NSRange(location: caret, length: 0))
    }

    /// An empty row above or below the caret's row. On the header or the
    /// delimiter row the new row becomes the first body row, as in the original.
    private static func insertTableRow(above: Bool, in text: String, range: NSRange) -> Edit {
        guard let table = pipeTable(at: range.location, in: text) else { return noOp }
        var lines = table.lines
        let empty = pipeRow(Array(repeating: "", count: table.columnCount))
        let anchor = table.caretRow <= 1 ? 2 : (above ? table.caretRow : table.caretRow + 1)
        let index = min(anchor, lines.count)
        lines.insert(empty, at: index)
        return finishTableEdit(table: table, lines: lines, row: index, column: table.caretColumn, columns: table.columnCount)
    }

    /// Drops the caret's body row. The header and delimiter rows are not
    /// deletable this way; deleting them would unmake the table.
    private static func deleteTableRow(in text: String, range: NSRange) -> Edit {
        guard let table = pipeTable(at: range.location, in: text) else { return noOp }
        guard table.caretRow >= 2 else { return noOp }
        var lines = table.lines
        lines.remove(at: table.caretRow)
        return finishTableEdit(
            table: table, lines: lines, row: min(table.caretRow, lines.count - 1),
            column: table.caretColumn, columns: table.columnCount)
    }

    /// An empty column left or right of the caret's column, across every row.
    private static func insertTableColumn(left: Bool, in text: String, range: NSRange) -> Edit {
        guard let table = pipeTable(at: range.location, in: text) else { return noOp }
        let at = left ? table.caretColumn : table.caretColumn + 1
        var alignments = table.alignments
        alignments.insert(.none, at: min(at, alignments.count))
        var lines = table.lines
        for index in lines.indices where index != 1 {
            var cells = paddedCells(lines[index], count: table.columnCount)
            cells.insert("", at: min(at, cells.count))
            lines[index] = pipeRow(cells)
        }
        lines[1] = pipeRow(alignments.map(alignmentMarker))
        return finishTableEdit(table: table, lines: lines, row: table.caretRow, column: at, columns: table.columnCount + 1)
    }

    /// Drops the caret's column. The last column stays: a table needs at least one.
    private static func deleteTableColumn(in text: String, range: NSRange) -> Edit {
        guard let table = pipeTable(at: range.location, in: text) else { return noOp }
        guard table.columnCount > 1 else { return noOp }
        let at = min(table.caretColumn, table.columnCount - 1)
        var alignments = table.alignments
        if at < alignments.count { alignments.remove(at: at) }
        var lines = table.lines
        for index in lines.indices where index != 1 {
            var cells = paddedCells(lines[index], count: table.columnCount)
            if at < cells.count { cells.remove(at: at) }
            lines[index] = pipeRow(cells)
        }
        lines[1] = pipeRow(alignments.map(alignmentMarker))
        return finishTableEdit(
            table: table, lines: lines, row: table.caretRow,
            column: min(at, table.columnCount - 2), columns: table.columnCount - 1)
    }

    /// Rewrites the delimiter cell for the caret's column. An already-applied
    /// alignment is a no-op, so the menu stays truthful.
    private static func alignTableColumn(
        _ alignment: TableState.ColumnAlignment, in text: String, range: NSRange
    ) -> Edit {
        guard let table = pipeTable(at: range.location, in: text) else { return noOp }
        var alignments = table.alignments
        let at = min(table.caretColumn, alignments.count - 1)
        guard at >= 0, alignments[at] != alignment else { return noOp }
        alignments[at] = alignment
        var lines = table.lines
        lines[1] = pipeRow(alignments.map(alignmentMarker))
        return finishTableEdit(
            table: table, lines: lines, row: table.caretRow,
            column: table.caretColumn, columns: table.columnCount)
    }

    // MARK: - Line plumbing

    private struct LineSpan {
        /// The whole lines the selection touches, no trailing newline.
        var range: NSRange
        var lines: [String]
        var lineStarts: [Int]
    }

    /// The whole lines covering `range`, as a block the text edits can replace
    /// in one slice.
    private static func span(of range: NSRange, in ns: NSString) -> LineSpan {
        let length = ns.length
        let start = min(max(range.location, 0), length)
        let end = min(NSMaxRange(range), length)
        var lineStart = start
        while lineStart > 0 && ns.character(at: lineStart - 1) != 10 { lineStart -= 1 }
        var lineEnd = end
        while lineEnd < length && ns.character(at: lineEnd) != 10 { lineEnd += 1 }

        var lines: [String] = []
        var starts: [Int] = []
        var offset = lineStart
        while offset <= lineEnd {
            var stop = offset
            while stop < lineEnd && ns.character(at: stop) != 10 { stop += 1 }
            lines.append(ns.substring(with: NSRange(location: offset, length: stop - offset)))
            starts.append(offset)
            if stop >= lineEnd { break }
            offset = stop + 1
        }
        return LineSpan(
            range: NSRange(location: lineStart, length: lineEnd - lineStart),
            lines: lines,
            lineStarts: starts
        )
    }

    private static func lineStarts(of lines: [String], from origin: Int) -> [Int] {
        var starts: [Int] = []
        var offset = origin
        for line in lines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }
        return starts
    }

    private static func lineIndex(for location: Int, in span: LineSpan) -> Int {
        var index = 0
        for (offset, start) in span.lineStarts.enumerated() where start <= location {
            index = offset
        }
        return index
    }

    /// Rewrites the whole lines the selection touches, keeping the line count.
    ///
    /// The caret keeps its column semantics by moving with its own line's prefix
    /// delta: typing at the start of a line that just grew a `- ` stays in front of
    /// the text it typed before.
    private static func mapLines(
        in text: String, range: NSRange, _ transform: (Int, String) -> String
    ) -> Edit {
        let span = span(of: range, in: text as NSString)
        let rewritten = span.lines.indices.map { transform($0, span.lines[$0]) }
        guard rewritten != span.lines else { return noOp }
        let index = lineIndex(for: range.location, in: span)
        let delta = rewritten[index].utf16.count - span.lines[index].utf16.count
        return Edit(
            range: span.range,
            text: rewritten.joined(separator: "\n"),
            selection: NSRange(
                location: range.location + delta,
                length: range.length
            )
        )
    }

    private static func startsWith(_ ns: NSString, _ prefix: String, at location: Int) -> Bool {
        guard location >= 0, location + prefix.utf16.count <= ns.length else { return false }
        return ns.substring(
            with: NSRange(location: location, length: prefix.utf16.count)
        ) == prefix
    }
}
