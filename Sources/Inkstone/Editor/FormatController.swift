import AppKit
import Foundation

/// The commands the Format menu and its Typora key equivalents dispatch.
///
/// Raw values ride along as the menu items' `representedObject`, so one action
/// covers every entry: `AppDelegate` looks the value up and hands it to the
/// focused window, which runs it against the editor.
enum FormatAction: String {
    case bold, italic, underline, inlineCode, strikethrough, highlight, inlineMath
    case link, image, clearFormat
    case heading1, heading2, heading3, heading4, heading5, heading6
    case paragraph, increaseHeading, decreaseHeading
    case quote, bulletList, orderedList, taskList
    case codeBlock, mathBlock, table, horizontalRule, tableOfContents, frontMatter
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
        // Indentation needs the caret's column inside its line, which is a
        // property of the view rather than the text; the editor routes these.
        case .indent, .outdent: return noOp
        }
    }

    // MARK: - Inline

    enum InlineKind {
        case bold, italic, underline, code, strikethrough, highlight, inlineMath

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
            let starts = lineStarts(of: body, from: span.range.location)
            let newIndex = max(0, min(index - 1, body.count - 1))
            let end = NSMaxRange(span.range)
            return Edit(
                range: span.range,
                text: body.joined(separator: "\n"),
                selection: NSRange(
                    location: min(starts[newIndex] + offsetInLine, end),
                    length: range.length
                )
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
            .inlineMath,
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
        let location = min(max(range.location, 0), (text as NSString).length)
        let block = "---\ntitle: Untitled\n---\n\n"
        let caret = "---\ntitle: ".utf16.count
        return Edit(
            // Front matter is a document header: the edit always sits at the top.
            range: NSRange(location: 0, length: 0),
            text: block,
            selection: NSRange(location: caret, length: 0)
        )
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
