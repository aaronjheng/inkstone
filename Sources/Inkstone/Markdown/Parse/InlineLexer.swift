import Foundation

/// Recognises inline (span-level) Markdown syntax.
///
/// A single left-to-right pass with a fallback to literal text: any character
/// the lexer cannot attribute to a construct becomes part of a `.text` node, so
/// unrecognised input is never lost.
///
/// Delimiter matching for emphasis is deliberately simpler than CommonMark's
/// left/right-flanking algorithm but covers what real documents use: `*`/`_` for
/// emphasis and strong, `***` for strong+emphasis, with intraword `_` excluded so
/// `snake_case_names` stay intact. Unbalanced delimiters degrade to literal text
/// rather than swallowing the rest of the paragraph.
public struct InlineLexer {
    let options: Options

    public struct Options: Sendable {
        public var enableInlineMath = true
        public var enableSubscript = false
        public var enableSuperscript = false
        public var enableHighlight = false
        public var enableAutoLink = true
        public var enableEmoji = true
        public var enableStrike = true
        public var enableUnderline = false
        /// Pandoc-style `$...$` rules (the original's default) vs the older permissive
        /// rule behind `legacyInlineMathParse`.
        public var legacyInlineMath = false

        public static let `default` = Options()
    }

    private let scalars: [Character]
    private var index = 0
    /// How many nested lexers deep this one is.
    ///
    /// Nested lexing builds a *fresh* lexer for the inner text, so without this the
    /// recursion depth restarts at every level and a pathological run of emphasis
    /// markers (`*****…`) recursed until the stack overflowed - a crash, not a hang.
    private let depth: Int

    /// Deeper than any real document; CommonMark itself bails out well before this.
    private static let maximumDepth = 32

    private init(_ text: String, options: Options, depth: Int = 0) {
        self.scalars = Array(text)
        self.options = options
        self.depth = depth
    }

    public static func parse(_ text: String, options: Options = .default) -> [InlineNode] {
        guard !text.isEmpty else { return [] }
        var lexer = InlineLexer(text, options: options)
        return lexer.run()
    }

    // MARK: - Scanner

    private var isAtEnd: Bool { index >= scalars.count }
    private func peek(_ offset: Int = 0) -> Character? {
        let target = index + offset
        guard target < scalars.count else { return nil }
        return scalars[target]
    }
    private func matches(_ character: Character) -> Bool { peek() == character }
    private func matches(_ string: String) -> Bool {
        let characters = Array(string)
        guard index + characters.count <= scalars.count else { return false }
        for (offset, expected) in characters.enumerated()
        where scalars[index + offset] != expected {
            return false
        }
        return true
    }
    private mutating func advance(_ count: Int = 1) { index += count }

    private func substring(from start: Int, to end: Int) -> String {
        String(scalars[start..<end])
    }

    private var pendingText = ""
    private var nodes: [InlineNode] = []

    private mutating func flushText() {
        guard !pendingText.isEmpty else { return }
        nodes.append(.text(pendingText))
        pendingText = ""
    }

    private mutating func emit(_ node: InlineNode) {
        flushText()
        nodes.append(node)
    }

    private mutating func run() -> [InlineNode] {
        while !isAtEnd {
            guard let character = peek() else { break }
            if let node = matchInline(at: index, character: character) {
                emit(node)
            } else {
                pendingText.append(character)
                advance()
            }
        }
        flushText()
        return nodes
    }

    // MARK: - Construct dispatch

    /// Attempts to match an inline construct starting at `start`. Returns `nil`
    /// when nothing matches, in which case the caller consumes one character as
    /// literal text.
    private mutating func matchInline(at start: Int, character: Character) -> InlineNode? {
        switch character {
        case "\\":
            return matchEscape(at: start)
        case "`":
            return matchCode(at: start)
        case "$" where options.enableInlineMath:
            return matchInlineMath(at: start)
        case ":" where options.enableEmoji:
            return matchEmoji(at: start)
        case "&":
            return matchEntity(at: start)
        case "<":
            return matchAutolinkOrHTML(at: start)
        case "!":
            return peek(1) == "[" ? matchImage(at: start) : nil
        case "[":
            return matchLinkOrFootnote(at: start)
        case "*", "_":
            return matchEmphasis(at: start, delimiter: character)
        case "~" where options.enableStrike:
            return matchStrike(at: start)
        case "~" where options.enableSubscript:
            return matchSubSuper(at: start, kind: .sub)
        case "^" where options.enableSuperscript:
            return matchSubSuper(at: start, kind: .sup)
        case "=" where options.enableHighlight:
            return matchPaired(at: start, token: "==", kind: .highlight)
        case "h", "w", "f", "m":
            // Bare URL autolinking.
            return options.enableAutoLink ? matchBareURL(at: start) : nil
        case "\n":
            return matchLineBreak(at: start)
        default:
            return nil
        }
    }

    // MARK: - Leaf constructs

    /// `\X` - the escaped character is payload; the backslash is kept verbatim so
    /// the source round-trips.
    private mutating func matchEscape(at start: Int) -> InlineNode? {
        guard let next = peek(1), next != "\n" else { return nil }
        var cursor = start + 1
        var body = ""
        // HTML entities and multi-code-unit escapes pass through whole.
        if next == "&" {
            if let semicolon = scalarIndex(";", from: cursor + 1, limit: cursor + 12) {
                body = substring(from: cursor, to: semicolon + 1)
                cursor = semicolon
            }
        }
        if body.isEmpty {
            body = String(next)
        }
        index = start + 1 + body.count
        return InlineNode(.escape, prefix: "\\", payload: body)
    }

    private mutating func scalarIndex(_ needle: Character, from: Int, limit: Int) -> Int? {
        var cursor = from
        while cursor < min(limit, scalars.count) {
            if scalars[cursor] == needle { return cursor }
            cursor += 1
        }
        return nil
    }

    /// Code spans: the closing run must be the same length as the opening run and
    /// must not be followed by another backtick.
    private mutating func matchCode(at start: Int) -> InlineNode? {
        let openLength = runLength(of: "`", from: start)
        var cursor = start + openLength
        while cursor < scalars.count {
            guard scalars[cursor] == "`" else {
                cursor += 1
                continue
            }
            let closeLength = runLength(of: "`", from: cursor)
            if closeLength == openLength,
                cursor + closeLength >= scalars.count || scalars[cursor + closeLength] != "`"
            {
                let raw = substring(from: start + openLength, to: cursor)
                index = cursor + closeLength
                return InlineNode(
                    .code,
                    prefix: String(repeating: "`", count: openLength),
                    suffix: String(repeating: "`", count: closeLength),
                    payload: normaliseCodeBody(raw),
                    rawBody: raw
                )
            }
            cursor += closeLength
        }
        return nil
    }

    /// CommonMark strips one leading and trailing space when the body is both
    /// space-padded and not all spaces.
    private func normaliseCodeBody(_ body: String) -> String {
        let characters = Array(body)
        guard characters.count >= 2,
            characters.first == " ",
            characters.last == " ",
            characters.contains(where: { $0 != " " })
        else { return body }
        return String(characters.dropFirst().dropLast())
    }

    private func runLength(of character: Character, from start: Int) -> Int {
        var cursor = start
        while cursor < scalars.count, scalars[cursor] == character { cursor += 1 }
        return cursor - start
    }

    /// `$...$` inline math.
    private mutating func matchInlineMath(at start: Int) -> InlineNode? {
        guard peek(1) != "$" else { return nil }
        let bodyStart = start + 1
        guard bodyStart < scalars.count, !isSpace(scalars[bodyStart]) else { return nil }
        var cursor = bodyStart
        while cursor < scalars.count {
            let character = scalars[cursor]
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == "$" {
                let previous = cursor > bodyStart ? scalars[cursor - 1] : nil
                guard cursor > bodyStart, let previous, !isSpace(previous), previous != "\\" else {
                    cursor += 1
                    continue
                }
                if !options.legacyInlineMath,
                    let after = cursor + 1 < scalars.count ? scalars[cursor + 1] : nil,
                    after.isNumber
                {
                    // `$2 and $3` is currency, not math.
                    cursor += 1
                    continue
                }
                index = cursor + 1
                return InlineNode(
                    .inlineMath, prefix: "$", suffix: "$",
                    payload: substring(from: bodyStart, to: cursor)
                )
            }
            cursor += 1
        }
        return nil
    }

    private func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n"
    }

    /// `:name:` emoji shortcodes.
    private mutating func matchEmoji(at start: Int) -> InlineNode? {
        guard let close = scalarIndex(":", from: start + 1, limit: start + 40) else { return nil }
        let name = substring(from: start + 1, to: close)
        guard !name.isEmpty,
            name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" })
        else { return nil }
        index = close + 1
        return InlineNode(.emoji, prefix: ":", suffix: ":", payload: name)
    }

    /// `&amp;` and friends.
    private mutating func matchEntity(at start: Int) -> InlineNode? {
        guard let semicolon = scalarIndex(";", from: start + 1, limit: start + 12) else {
            return nil
        }
        let body = substring(from: start + 1, to: semicolon)
        guard
            body.hasPrefix("#") || body.hasPrefix("amp") || body.hasPrefix("lt")
                || body.hasPrefix("gt") || body.hasPrefix("quot") || body.hasPrefix("nbsp")
        else { return nil }
        index = semicolon + 1
        return InlineNode(.entity, prefix: "&", suffix: ";", payload: body)
    }

    /// `<https://…>` autolinks and raw inline HTML.
    private mutating func matchAutolinkOrHTML(at start: Int) -> InlineNode? {
        guard let close = scalarIndex(">", from: start + 1, limit: start + 2048) else { return nil }
        let body = substring(from: start + 1, to: close)
        guard !body.isEmpty, !body.contains("<") else { return nil }
        if isAbsoluteURL(body) {
            index = close + 1
            return InlineNode(
                .autolink, prefix: "<", suffix: ">", payload: body,
                attributes: .init(destination: body)
            )
        }
        // Inline HTML tag or comment.
        if body.hasPrefix("/") || body.hasPrefix("!") || body.first?.isLetter == true {
            index = close + 1
            return InlineNode(.html, prefix: "<", suffix: ">", payload: body)
        }
        return nil
    }

    private func isAbsoluteURL(_ text: String) -> Bool {
        for scheme in ["http://", "https://", "ftp://", "mailto:", "file://"]
        where
            text.lowercased().hasPrefix(scheme)
        {
            return true
        }
        return false
    }

    // MARK: - Link constructs

    /// `[text](dest "title")`, `[text][ref]`, `[ref]`, `[^footnote]`.
    private mutating func matchLinkOrFootnote(at start: Int) -> InlineNode? {
        guard let labelEnd = balancedIndex(of: "[", from: start) else { return nil }
        let label = substring(from: start + 1, to: labelEnd)
        if label.hasPrefix("^") {
            let reference = String(label.dropFirst())
            guard !reference.isEmpty else { return nil }
            index = labelEnd + 1
            // The `^` belongs to the prefix and the label to the payload, so the node's
            // `verbatim` is `[^label]` again. Dropping the label produced `[]` on screen
            // and broke the byte-for-byte round trip for every footnote reference.
            return InlineNode(
                .footnoteRef, prefix: "[^", suffix: "]", payload: reference,
                attributes: .init(reference: reference)
            )
        }

        let next = labelEnd + 1
        if next < scalars.count, scalars[next] == "(" {
            guard let destEnd = balancedIndex(of: "(", from: next) else { return nil }
            let target = substring(from: next + 1, to: destEnd)
            index = destEnd + 1
            let content = parse(label)
            return InlineNode(
                .link,
                prefix: "[",
                suffix: "](\(target))",
                children: content,
                attributes: .init(
                    destination: parseLinkTarget(target).destination,
                    title: parseLinkTarget(target).title)
            )
        }
        if next < scalars.count, scalars[next] == "[" {
            guard let refEnd = balancedIndex(of: "[", from: next) else { return nil }
            let reference = substring(from: next + 1, to: refEnd)
            index = refEnd + 1
            let content = parse(label)
            return InlineNode(
                .refLink,
                prefix: "[",
                suffix: "][\(reference)]",
                children: content,
                attributes: .init(reference: reference.isEmpty ? label : reference)
            )
        }
        // Shortcut reference: `[label]` with no destination.
        guard !label.isEmpty else { return nil }
        index = labelEnd + 1
        return InlineNode(
            .refLink, prefix: "[", suffix: "]", children: parse(label),
            attributes: .init(reference: label)
        )
    }

    private mutating func matchImage(at start: Int) -> InlineNode? {
        guard let labelEnd = balancedIndex(of: "[", from: start + 1) else { return nil }
        let alt = substring(from: start + 2, to: labelEnd)
        let next = labelEnd + 1
        if next < scalars.count, scalars[next] == "(" {
            guard let destEnd = balancedIndex(of: "(", from: next) else { return nil }
            let target = substring(from: next + 1, to: destEnd)
            index = destEnd + 1
            let parsed = parseLinkTarget(target)
            return InlineNode(
                .image, prefix: "![", suffix: "](\(target))", payload: alt,
                attributes: .init(destination: parsed.destination, title: parsed.title, name: alt)
            )
        }
        if next < scalars.count, scalars[next] == "[" {
            guard let refEnd = balancedIndex(of: "[", from: next) else { return nil }
            let reference = substring(from: next + 1, to: refEnd)
            index = refEnd + 1
            return InlineNode(
                .refImage, prefix: "![", suffix: "][\(reference)]", payload: alt,
                attributes: .init(name: alt, reference: reference.isEmpty ? alt : reference)
            )
        }
        guard !alt.isEmpty else { return nil }
        index = labelEnd + 1
        return InlineNode(
            .image, prefix: "![", suffix: "]", payload: alt,
            attributes: .init(name: alt, reference: alt)
        )
    }

    /// Splits `dest "title"` into its parts without disturbing the verbatim
    /// suffix, which is what gets written back.
    func parseLinkTarget(_ target: String) -> (destination: String, title: String?) {
        let characters = Array(target)
        var depth = 0
        var quote: Character?
        var split = characters.count
        var cursor = 0
        while cursor < characters.count {
            let character = characters[cursor]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
            } else if character.isWhitespace && depth == 0 {
                split = cursor
                break
            }
            cursor += 1
        }
        let destination = String(characters[0..<split]).trimmingInlineWhitespace()
        var title: String?
        if split < characters.count {
            let rest = String(characters[split...]).trimmingInlineWhitespace()
            if rest.count >= 2, rest.first == "\"", rest.last == "\"" {
                title = String(rest.dropFirst().dropLast())
            } else if rest.count >= 2, rest.first == "'", rest.last == "'" {
                title = String(rest.dropFirst().dropLast())
            }
        }
        return (String(destination), title)
    }

    /// Index of the bracket that closes the one at `start`, honouring nesting and
    /// backslash escapes.
    private func balancedIndex(of open: Character, from start: Int) -> Int? {
        guard start < scalars.count, scalars[start] == open else { return nil }
        var depth = 0
        var cursor = start
        while cursor < scalars.count {
            let character = scalars[cursor]
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == "`" {
                cursor += runLength(of: "`", from: cursor)
                continue
            }
            if character == open {
                depth += 1
            } else if character == closingBracket(for: open) {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor += 1
        }
        return nil
    }

    private func closingBracket(for open: Character) -> Character {
        switch open {
        case "[": return "]"
        case "(": return ")"
        default: return open
        }
    }

    // MARK: - Emphasis

    /// `***`, `**`, `*` and the `_` variants.
    private mutating func matchEmphasis(at start: Int, delimiter: Character) -> InlineNode? {
        let runLength = self.runLength(of: delimiter, from: start)
        guard runLength >= 1 else { return nil }
        // A delimiter run of 4+ is ambiguous; treat the extra as literal text.
        guard runLength <= 3 else { return nil }

        // `_` must not open intraword: `snake_case` stays literal.
        if delimiter == "_", start > 0, scalars[start - 1].isLetter || scalars[start - 1].isNumber {
            return nil
        }
        let bodyStart = start + runLength
        guard bodyStart < scalars.count else { return nil }

        var cursor = bodyStart
        while cursor < scalars.count {
            let character = scalars[cursor]
            if character == "\\" {
                cursor += 2
                continue
            }
            if character == "`" {
                cursor += self.runLength(of: "`", from: cursor)
                continue
            }
            guard character == delimiter else {
                cursor += 1
                continue
            }
            let closingLength = self.runLength(of: delimiter, from: cursor)
            guard closingLength >= runLength else {
                cursor += closingLength
                continue
            }
            // `_` must not close intraword either.
            if delimiter == "_", cursor + closingLength < scalars.count,
                scalars[cursor + closingLength].isLetter || scalars[cursor + closingLength].isNumber
            {
                cursor += closingLength
                continue
            }
            let body = substring(from: bodyStart, to: cursor)
            guard !body.trimmingInlineWhitespace().isEmpty else {
                cursor += closingLength
                continue
            }
            let token = String(repeating: delimiter, count: runLength)
            index = cursor + runLength
            switch runLength {
            case 3:
                // strong + emphasis
                let inner = parse(body)
                return InlineNode(
                    .strong, prefix: token, suffix: token,
                    children: [InlineNode(.em, prefix: "", suffix: "", children: inner)]
                )
            case 2:
                return InlineNode(.strong, prefix: token, suffix: token, children: parse(body))
            default:
                return InlineNode(.em, prefix: token, suffix: token, children: parse(body))
            }
        }
        return nil
    }

    private mutating func matchStrike(at start: Int) -> InlineNode? {
        matchPaired(at: start, token: "~~", kind: .strike)
    }

    private mutating func matchSubSuper(at start: Int, kind: InlineKind) -> InlineNode? {
        matchPaired(at: start, token: String(kind == .sub ? "~" : "^"), kind: kind)
    }

    private mutating func matchPaired(at start: Int, token: String, kind: InlineKind) -> InlineNode? {
        let characters = Array(token)
        guard matches(token) else { return nil }
        let bodyStart = start + characters.count
        // Find the next occurrence of the token.
        var cursor = bodyStart
        while cursor + characters.count <= scalars.count {
            if scalars[cursor] == "\\" {
                cursor += 2
                continue
            }
            var matched = true
            for (offset, expected) in characters.enumerated() where scalars[cursor + offset] != expected {
                matched = false
                break
            }
            if matched {
                let body = substring(from: bodyStart, to: cursor)
                guard !body.isEmpty else {
                    cursor += characters.count
                    continue
                }
                index = cursor + characters.count
                return InlineNode(kind, prefix: token, suffix: token, children: parse(body))
            }
            cursor += 1
        }
        return nil
    }

    // MARK: - Bare URLs

    /// Recognises `https://…` and stops at whitespace or a character that cannot
    /// belong to a URL, trimming trailing punctuation.
    private mutating func matchBareURL(at start: Int) -> InlineNode? {
        // Only at a word boundary.
        if start > 0, scalars[start - 1].isLetter || scalars[start - 1].isNumber { return nil }
        let text = substring(from: start, to: scalars.count)
        guard
            let prefix = ["http://", "https://", "ftp://", "file://", "mailto:"].first(where: {
                text.lowercased().hasPrefix($0)
            })
        else { return nil }

        var cursor = start + prefix.count
        while cursor < scalars.count {
            let character = scalars[cursor]
            if character.isWhitespace || character == "<" || character == ">" || character == "`" {
                break
            }
            cursor += 1
        }
        // Trim trailing sentence punctuation and unbalanced closers.
        var end = cursor
        while end > start + prefix.count {
            let character = scalars[end - 1]
            if ".,;:!?'\"".contains(character) {
                end -= 1
                continue
            }
            if character == ")" {
                let opened = substring(from: start, to: end).filter { $0 == "(" }.count
                let closed = substring(from: start, to: end).filter { $0 == ")" }.count
                if closed > opened {
                    end -= 1
                    continue
                }
            }
            break
        }
        guard end > start + prefix.count else { return nil }
        let url = substring(from: start, to: end)
        index = end
        return InlineNode(.link, prefix: "", suffix: "", payload: url, attributes: .init(destination: url))
    }

    // MARK: - Line breaks

    /// Two trailing spaces or a trailing backslash make a hard break; a bare
    /// newline is a soft break. `ignoreLineBreak` is a parse option applied by
    /// the caller, which collapses soft breaks to a space before lexing.
    private mutating func matchLineBreak(at start: Int) -> InlineNode? {
        // Trailing spaces before the newline belong to the hard-break marker.
        var breakStart = start
        while breakStart > 0, scalars[breakStart - 1] == " " { breakStart -= 1 }
        let spaces = start - breakStart
        let isHard = spaces >= 2 || (spaces == 1 && breakStart > 0 && scalars[breakStart - 1] == "\\")
        let marker = substring(from: breakStart, to: start + 1)
        if spaces > 0 {
            // The trailing spaces are already buffered as literal text, and the marker
            // carries them too - so they would be emitted twice. Take them back
            // whenever there is a marker to carry them, hard or not: a single trailing
            // space before a newline is not a hard break, but it *is* still part of
            // this marker rather than of the paragraph text.
            if pendingText.count >= spaces {
                pendingText.removeLast(spaces)
            }
        }
        index = start + 1
        return isHard
            ? InlineNode(.hardBreak, payload: marker)
            : InlineNode(.softBreak, payload: marker)
    }

    private mutating func parse(_ text: String) -> [InlineNode] {
        guard !text.isEmpty else { return [] }
        guard depth < Self.maximumDepth else {
            // Past the limit the markers are literal text. That is what every real
            // renderer does with input this pathological, and it stops the recursion.
            return [InlineNode(.text, payload: text)]
        }
        var nested = InlineLexer(text, options: options, depth: depth + 1)
        return nested.run()
    }
}

extension StringProtocol {
    /// Strips spaces, tabs and a trailing newline. Works on `String` and on any
    /// slice, which the block matchers rely on.
    func trimmingInlineWhitespace() -> String {
        var slice = self[startIndex..<endIndex]
        while let first = slice.first,
            first == " " || first == "\t" || first == "\n" || first == "\r"
        {
            slice = slice.dropFirst()
        }
        while let last = slice.last,
            last == " " || last == "\t" || last == "\n" || last == "\r"
        {
            slice = slice.dropLast()
        }
        return String(slice)
    }
}
