import Foundation

/// Converts clipboard HTML to Markdown, so pasting from a browser lands as
/// source rather than as styled text the buffer cannot hold.
///
/// Hand-rolled single-pass scanner, Foundation only: there is no WebKit in
/// this project, and the pasteboard's `public.html` flavour is plain data.
/// Unknown tags pass their content through; `script`, `style` and `head` are
/// dropped with their content. Returns `""` when nothing convertible remains.
enum HTMLToMarkdown {
    static func convert(_ html: String) -> String {
        var parser = Parser(html: html)
        parser.run()
        let text = parser.frames.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text
    }

    // MARK: - Parser

    private struct Parser {
        let scalars: [Character]
        var index: Int
        /// Block buffers; the top frame owns whatever text is being built.
        var frames: [Frame] = [Frame(kind: .root)]
        /// Open lists, innermost last: ordered flag plus the next item number.
        var lists: [(ordered: Bool, next: Int)] = []
        var quoteDepth = 0
        /// Open link destinations, innermost last. Nested links are invalid
        /// HTML; the inner one wins and the outer close is ignored.
        var links: [String] = []
        /// Tags whose content is dropped wholesale.
        var skipDepth = 0

        init(html: String) {
            scalars = Array(html)
            index = 0
        }

        enum FrameKind {
            case root
            case block
            case heading(Int)
            case item(prefix: String)
            case quote(Int)
            case pre(language: String)
            case table
            case row
            case cell

            /// A `<pre>` block, whatever its language.
            var isPre: Bool {
                if case .pre = self { return true }
                return false
            }
        }

        struct Frame {
            var kind: FrameKind
            var text = ""
            var rows: [[String]] = []
            var cells: [String] = []
        }

        mutating func run() {
            while index < scalars.count {
                if scalars[index] == "<" {
                    if let tag = readTag() {
                        handle(tag)
                    }
                } else {
                    var next = index
                    while next < scalars.count, scalars[next] != "<" { next += 1 }
                    pushText(String(scalars[index..<next]))
                    index = next
                }
            }
            // Unclosed blocks still flush: clipboard HTML is routinely truncated.
            while frames.count > 1 { closeFrame() }
        }

        // MARK: - Tokenising

        struct Tag {
            var name: String
            var closing: Bool
            var attributes: [String: String]
        }

        /// Reads `<…>` at the cursor, honouring quoted `>` inside attributes.
        /// Comments are skipped inline and produce no tag.
        mutating func readTag() -> Tag? {
            var cursor = index + 1
            var quote: Character?
            while cursor < scalars.count {
                let character = scalars[cursor]
                if let active = quote {
                    if character == active { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    break
                }
                cursor += 1
            }
            guard cursor < scalars.count else {
                index = scalars.count
                return nil
            }
            let body = String(scalars[(index + 1)..<cursor])
            index = cursor + 1
            if body.hasPrefix("!--") { return nil }
            if body.hasPrefix("!") || body.hasPrefix("?") { return nil }
            var text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let closing = text.hasPrefix("/")
            if closing { text = String(text.dropFirst()) }
            if text.hasSuffix("/") { text = String(text.dropLast()) }
            let name =
                text.prefix { $0 != " " && $0 != "\t" && $0 != "\n" }.lowercased()
            guard !name.isEmpty else { return nil }
            return Tag(
                name: String(name), closing: closing,
                attributes: attributes(in: String(text.dropFirst(name.count)))
            )
        }

        /// `key="value"`, `key='value'` and bare `key=value` pairs.
        func attributes(in text: String) -> [String: String] {
            var result: [String: String] = [:]
            let characters = Array(text)
            var cursor = 0
            while cursor < characters.count {
                while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                var keyEnd = cursor
                while keyEnd < characters.count, characters[keyEnd] != "=",
                    !characters[keyEnd].isWhitespace
                {
                    keyEnd += 1
                }
                guard keyEnd > cursor else {
                    cursor += 1
                    continue
                }
                let key = String(characters[cursor..<keyEnd]).lowercased()
                cursor = keyEnd
                while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                guard cursor < characters.count, characters[cursor] == "=" else { continue }
                cursor += 1
                while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
                guard cursor < characters.count else { break }
                if characters[cursor] == "\"" || characters[cursor] == "'" {
                    let mark = characters[cursor]
                    cursor += 1
                    let valueStart = cursor
                    while cursor < characters.count, characters[cursor] != mark { cursor += 1 }
                    result[key] = String(characters[valueStart..<cursor])
                    if cursor < characters.count { cursor += 1 }
                } else {
                    let valueStart = cursor
                    while cursor < characters.count, !characters[cursor].isWhitespace,
                        characters[cursor] != ">"
                    {
                        cursor += 1
                    }
                    result[key] = String(characters[valueStart..<cursor])
                }
            }
            return result
        }

        // MARK: - Dispatch

        mutating func handle(_ tag: Tag) {
            switch tag.name {
            case "script", "style", "head", "title", "noscript":
                skipDepth += tag.closing ? -1 : 1
                skipDepth = max(skipDepth, 0)
            case "br":
                guard !tag.closing else { return }
                append("\n")
            case "hr":
                guard !tag.closing else { return }
                blankLine()
                append("---")
                blankLine()
            case "p", "div", "section", "article", "main", "header", "footer",
                "aside", "nav", "figure", "figcaption", "dd", "dt", "dl":
                if tag.closing {
                    closeFrame()
                } else {
                    pushFrame(.block)
                }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                guard let level = Int(tag.name.dropFirst()) else { return }
                if tag.closing {
                    closeFrame()
                } else {
                    pushFrame(.heading(level))
                }
            case "blockquote":
                if tag.closing {
                    closeFrame()
                } else {
                    quoteDepth += 1
                    pushFrame(.quote(quoteDepth))
                }
            case "pre":
                if tag.closing {
                    closeFrame()
                } else {
                    pushFrame(.pre(language: language(from: tag.attributes)))
                }
            case "ul", "ol":
                if tag.closing {
                    if !lists.isEmpty { lists.removeLast() }
                    if case .root = frames.last?.kind { blankLine() }
                } else {
                    lists.append((ordered: tag.name == "ol", next: 1))
                }
            case "li":
                if tag.closing {
                    closeFrame()
                } else {
                    openItem()
                }
            case "table":
                if tag.closing {
                    closeFrame()
                } else {
                    pushFrame(.table)
                }
            case "tr":
                if tag.closing {
                    closeFrame()
                } else {
                    pushFrame(.row)
                }
            case "td", "th":
                if tag.closing {
                    closeFrame()
                } else {
                    pushFrame(.cell)
                }
            case "a":
                if tag.closing {
                    guard !links.isEmpty else { return }
                    let href = links.removeLast()
                    append(href.isEmpty ? "]" : "](\(href))")
                } else {
                    links.append(tag.attributes["href"] ?? "")
                    append("[")
                }
            case "img":
                guard !tag.closing else { return }
                let alt = tag.attributes["alt"] ?? ""
                let source = tag.attributes["src"] ?? ""
                if !source.isEmpty { append("![\(alt)](\(source))") }
            case "strong", "b":
                append("**")
            case "em", "i":
                append("*")
            case "code", "tt", "kbd", "samp":
                // Highlighters put `language-x` on the inner `<code>` rather
                // than the `<pre>`; carry it up so the fence keeps its language.
                if insidePre, !tag.closing {
                    let found = language(from: tag.attributes)
                    if !found.isEmpty, let slot = frames.lastIndex(where: { $0.kind.isPre }) {
                        frames[slot].kind = .pre(language: found)
                    }
                } else if !insidePre {
                    append("`")
                }
            case "del", "s", "strike":
                append("~~")
            case "u":
                append(tag.closing ? "</u>" : "<u>")
            case "mark":
                append("==")
            case "sub":
                append("~")
            case "sup":
                append("^")
            default:
                break
            }
        }

        // MARK: - Text

        /// Decoded body text into the current frame: raw inside `<pre>`,
        /// whitespace-collapsed everywhere else, as HTML renders it.
        ///
        /// Boundary spaces are kept exactly where the source had them: a
        /// collapsed run otherwise glues `Hello <strong>bold</strong>` into
        /// `Hello** bold**`, or splits `</a>.` into `</a> .`.
        mutating func pushText(_ raw: String) {
            guard skipDepth == 0 else { return }
            guard !raw.isEmpty else { return }
            if insidePre {
                frames[frames.count - 1].text += decode(raw)
                return
            }
            let leading = raw.first?.isWhitespace == true
            let trailing = raw.last?.isWhitespace == true
            let collapsed = raw.split(
                whereSeparator: { $0.isWhitespace }
            ).joined(separator: " ")
            guard !collapsed.isEmpty else {
                // Pure whitespace separates inline runs: one space, unless the
                // frame is empty or already spaced, where it adds nothing.
                let current = frames[frames.count - 1].text
                if !current.isEmpty, !current.hasSuffix(" "), !current.hasSuffix("\n") {
                    frames[frames.count - 1].text += " "
                }
                return
            }
            var text = decode(collapsed)
            var current = frames[frames.count - 1].text
            if leading, !current.isEmpty, !current.hasSuffix(" "), !current.hasSuffix("\n") {
                text = " " + text
            }
            current += text
            // A trailing space keeps the next marker off the word; block
            // assembly trims it again, so it never leaks onto a line end.
            if trailing, !current.hasSuffix(" "), !current.hasSuffix("\n") {
                current += " "
            }
            frames[frames.count - 1].text = current
        }

        mutating func append(_ text: String) {
            guard skipDepth == 0 else { return }
            frames[frames.count - 1].text += text
        }

        /// A paragraph break in the current frame.
        mutating func blankLine() {
            guard skipDepth == 0 else { return }
            var text = frames[frames.count - 1].text
            guard !text.isEmpty else { return }
            if text.hasSuffix("\n\n") { return }
            text += text.hasSuffix("\n") ? "\n" : "\n\n"
            frames[frames.count - 1].text = text
        }

        var insidePre: Bool {
            frames.contains { if case .pre = $0.kind { return true } else { return false } }
        }

        // MARK: - Frames

        mutating func pushFrame(_ kind: FrameKind) {
            guard skipDepth == 0 else { return }
            frames.append(Frame(kind: kind))
        }

        /// Pops the top frame, transforming its text into its parent.
        mutating func closeFrame() {
            guard frames.count > 1 else { return }
            let frame = frames.removeLast()
            switch frame.kind {
            case .root:
                break
            case .block:
                let body = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return }
                blankLine()
                append(body)
                blankLine()
            case .heading(let level):
                let body = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return }
                blankLine()
                append(String(repeating: "#", count: level) + " " + body)
                blankLine()
            case .item(let prefix):
                let body = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return }
                let lines = body.components(separatedBy: "\n")
                let gap = String(repeating: " ", count: prefix.count)
                // Continuation lines that already carry their own indentation
                // (a nested list) keep it; wrapped prose aligns under the text.
                let rest = lines.dropFirst().map { line in
                    line.first?.isWhitespace == true ? line : gap + line
                }
                let indented = ([prefix + (lines.first ?? "")] + rest).joined(separator: "\n")
                let parent = frames[frames.count - 1].text
                append((parent.isEmpty || parent.hasSuffix("\n") ? "" : "\n") + indented + "\n")
            case .quote(let depth):
                quoteDepth = max(quoteDepth - 1, 0)
                let mark = String(repeating: "> ", count: depth)
                let body =
                    frame.text.components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "" : mark + $0 }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return }
                blankLine()
                append(body)
                blankLine()
            case .pre(let language):
                let body = frame.text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                blankLine()
                append("```" + language + "\n" + body + "\n```")
                blankLine()
            case .table:
                guard !frame.rows.isEmpty else { return }
                blankLine()
                let header = frame.rows[0]
                append("| " + header.joined(separator: " | ") + " |")
                append("\n| " + header.map({ _ in "---" }).joined(separator: " | ") + " |")
                for row in frame.rows.dropFirst() {
                    // Ragged rows pad or trim to the header, as renderers do.
                    var cells = row + Array(repeating: "", count: max(0, header.count - row.count))
                    cells = Array(cells.prefix(max(header.count, 1)))
                    append("\n| " + cells.joined(separator: " | ") + " |")
                }
                blankLine()
            case .row:
                if case .table = frames.last?.kind {
                    frames[frames.count - 1].rows.append(frame.cells)
                }
            case .cell:
                if case .row = frames.last?.kind {
                    frames[frames.count - 1].cells.append(
                        frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
            }
        }

        /// Opens a list item: the marker comes from the innermost open list.
        mutating func openItem() {
            guard let list = lists.last else {
                pushFrame(.item(prefix: "- "))
                return
            }
            let indent = String(repeating: "  ", count: max(lists.count - 1, 0))
            if list.ordered {
                pushFrame(.item(prefix: "\(indent)\(list.next). "))
                lists[lists.count - 1].next += 1
            } else {
                pushFrame(.item(prefix: "\(indent)- "))
            }
        }

        /// `language-x` from a `class` attribute, for fenced code blocks.
        func language(from attributes: [String: String]) -> String {
            guard let classes = attributes["class"] else { return "" }
            for token in classes.split(separator: " ") where token.hasPrefix("language-") {
                return String(token.dropFirst("language-".count))
            }
            return ""
        }

        // MARK: - Entities

        /// The five XML entities, a working set of named ones, and numeric
        /// references. Anything unrecognised passes through verbatim.
        func decode(_ text: String) -> String {
            var out = ""
            out.reserveCapacity(text.count)
            let characters = Array(text)
            var cursor = 0
            while cursor < characters.count {
                guard characters[cursor] == "&" else {
                    out.append(characters[cursor])
                    cursor += 1
                    continue
                }
                var end = cursor + 1
                while end < characters.count, characters[end] != ";",
                    end - cursor < 12
                {
                    end += 1
                }
                guard end < characters.count, characters[end] == ";" else {
                    out.append("&")
                    cursor += 1
                    continue
                }
                let body = String(characters[(cursor + 1)..<end])
                if let decoded = decodeEntity(body) {
                    out.append(decoded)
                } else {
                    out.append("&" + body + ";")
                }
                cursor = end + 1
            }
            return out
        }

        func decodeEntity(_ body: String) -> String? {
            switch body {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos", "#39": return "'"
            case "nbsp": return " "
            case "copy": return "©"
            case "reg": return "®"
            case "hellip": return "…"
            case "mdash": return "—"
            case "ndash": return "–"
            case "lsquo": return "‘"
            case "rsquo": return "’"
            case "ldquo": return "“"
            case "rdquo": return "”"
            default:
                if body.hasPrefix("#x") || body.hasPrefix("#X"),
                    let value = UInt32(body.dropFirst(2), radix: 16),
                    let scalar = UnicodeScalar(value)
                {
                    return String(scalar)
                }
                if body.hasPrefix("#"), let value = UInt32(body.dropFirst()),
                    let scalar = UnicodeScalar(value)
                {
                    return String(scalar)
                }
                return nil
            }
        }
    }
}
