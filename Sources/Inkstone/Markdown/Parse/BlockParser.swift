import Foundation

/// Recognises block-level Markdown syntax.
///
/// Line-oriented, like the original's own lexer: each construct is matched by its
/// opening line, then consumed to its natural close. Containers (blockquotes,
/// lists) recurse with the container's markers stripped, so inner text is parsed
/// by exactly the same rules.
///
/// ## Byte fidelity
///
/// Every block records the exact `source` slice it came from, so the document can
/// be written back without re-serialisation. The parser normalises nothing; what
/// it stores in `attributes` is only what the renderer and the writer of
/// attachment-rendered blocks need (fence length, list marker character, table
/// alignment, ...).
public struct BlockParser {
    private let text: String
    private var lines: [Line] = []
    private let ids = Allocator()
    private var options: Options

    public struct Options: Sendable {
        public var enableInlineMath = true
        public var enableMathBlock = true
        public var enableSubscript = false
        public var enableSuperscript = false
        public var enableHighlight = false
        public var enableAlert = true
        public var enableStrike = true
        public var enableAutoLink = true
        public var enableEmoji = true
        /// Collapse single newlines inside a paragraph to spaces (GFM rendering).
        /// The original exposes this as `ignoreLineBreak`.
        public var ignoreLineBreak = false
        public var strictMarkdown = false

        public init() {}

        public static let standard = Options()

        var inline: InlineLexer.Options {
            var value = InlineLexer.Options.default
            value.enableInlineMath = enableInlineMath
            value.enableSubscript = enableSubscript
            value.enableSuperscript = enableSuperscript
            value.enableHighlight = enableHighlight
            value.enableAutoLink = enableAutoLink
            value.enableEmoji = enableEmoji
            value.enableStrike = enableStrike
            return value
        }
    }

    /// One physical line with its position in the source.
    private struct Line {
        var text: Substring
        var offset: Int
        /// Whether the line ended `\r\n` in the original. The `\r` is stripped for
        /// matching, but every byte has to reach `source` again - see `slice`.
        var hasCR = false
        var isBlank: Bool { Self.isBlankLine(text) }

        static func isBlankLine(_ value: Substring) -> Bool {
            value.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
        }
    }

    /// A block plus the line the parser should resume from.
    private struct Step {
        var block: BlockNode
        var nextLine: Int
    }

    private final class Allocator {
        private var next = 0
        func allocate() -> Int {
            defer { next += 1 }
            return next
        }
    }

    /// Suppresses `sourceOffset` bookkeeping while re-parsing container children,
    /// whose stripped lines are not contiguous in the source.
    private var trackingOffsets = true

    public init(text: String, options: Options = .standard) {
        self.text = text
        self.options = options
    }

    public static func parse(
        _ text: String, options: Options = .standard
    ) -> MarkdownDocument {
        var parser = BlockParser(text: text, options: options)
        return parser.run()
    }

    // MARK: - Entry point

    private mutating func run() -> MarkdownDocument {
        lines = splitLines(text)
        // Front matter is recognised before the body so it is not also matched as
        // a horizontal rule plus whatever follows.
        var frontMatter: BlockNode?
        var frontMatterStep = Step(block: BlockNode(id: -1, kind: .emptyLine, source: ""), nextLine: 0)
        var bodyStart = 0
        if !lines.isEmpty, isFrontMatterOpening(String(lines[0].text)),
            hasFrontMatterCloser(from: 1)
        {
            let step = consumeFrontMatter(from: 0, until: lines.count)
            frontMatter = step.block
            frontMatterStep = step
            bodyStart = step.nextLine
        }
        var blocks = parseRegion(bodyStart, lines.count, indent: 0, topLevel: true)
        if let frontMatter {
            blocks.insert(frontMatter, at: 0)
        }

        var document = MarkdownDocument(
            blocks: blocks,
            usesCarriageReturns: text.contains("\r\n"),
            endsWithNewline: !text.isEmpty && (text.hasSuffix("\n") || text.hasSuffix("\r")),
            trailingText: trailingText(after: blocks)
        )
        document.finalNewlineIsCRLF = text.hasSuffix("\r\n")
        if let frontMatter, frontMatterStep.nextLine > 0, frontMatterStep.nextLine <= lines.count {
            var matter = frontMatter
            matter.endsWithCarriageReturn = lines[frontMatterStep.nextLine - 1].hasCR
            blocks[0] = matter
            document.blocks = blocks
        }
        document.rebuildIndexes()
        return document
    }

    /// Verbatim text of the blank lines after the final block.
    ///
    /// The end offset is counted in UTF-16 units because that is what `NSString`
    /// indexes by. It is summed from `leadingText + source` plus each block's own
    /// terminator (which `slice` leaves off and the separator re-adds, `\r\n` when
    /// that block's last line ended with one) rather than from `sourceOffset`, which
    /// is a *byte* offset - using it truncated every document that contained a
    /// non-ASCII character.
    private func trailingText(after blocks: [BlockNode]) -> String {
        var consumed = 0
        for (index, block) in blocks.enumerated() {
            if index > 0, let previous = blocks[index - 1] as BlockNode? {
                consumed += previous.endsWithCarriageReturn ? 2 : 1
            }
            consumed += block.leadingText.utf16.count
            consumed += block.source.utf16.count
        }
        let ns = text as NSString
        guard consumed >= 0, consumed < ns.length else { return "" }
        return ns.substring(from: consumed)
    }

    private mutating func splitLines(_ value: String) -> [Line] {
        var result: [Line] = []
        var offset = 0
        for segment in value.split(separator: "\n", omittingEmptySubsequences: false) {
            var clean = segment
            var hasCR = false
            if clean.hasSuffix("\r") {
                clean = clean.dropLast()
                hasCR = true
            }
            result.append(Line(text: clean, offset: offset, hasCR: hasCR))
            offset += segment.utf16.count + 1
        }
        return result
    }

    // MARK: - Region dispatcher

    private mutating func parseRegion(
        _ start: Int, _ end: Int, indent: Int, topLevel: Bool = false
    ) -> [BlockNode] {
        var blocks: [BlockNode] = []
        var cursor = start
        var pendingLeadingText = ""
        var pendingByteCost = 0

        while cursor < end {
            let line = lines[cursor]

            if line.isBlank {
                pendingLeadingText += line.text + (line.hasCR ? "\r\n" : "\n")
                pendingByteCost += line.text.utf16.count + 1
                cursor += 1
                continue
            }

            var step =
                parseBlock(at: cursor, until: end, indent: indent, topLevel: topLevel)
                ?? consumeParagraph(from: cursor, until: end)

            step.block.leadingText = pendingLeadingText
            if trackingOffsets {
                step.block.sourceOffset = line.offset - pendingByteCost
            } else {
                step.block.sourceOffset = -1
            }
            pendingByteCost = 0
            pendingLeadingText = ""
            // The block's own final terminator is re-added by the document's source
            // reassembly and the layout's separator; both need to know whether it
            // was `\r\n` or `\n`, which the stripped line no longer shows.
            if step.nextLine > 0, step.nextLine <= lines.count {
                step.block.endsWithCarriageReturn = lines[step.nextLine - 1].hasCR
            }
            blocks.append(step.block)
            cursor = step.nextLine
        }

        return blocks
    }

    private mutating func parseBlock(
        at index: Int, until end: Int, indent: Int, topLevel: Bool
    ) -> Step? {
        let content = String(lines[index].text)

        if (leadingSpaces(lines[index].text) ?? 0) >= 4, !content.isEmpty {
            return consumeIndentedCode(from: index, until: end)
        }
        if let fence = Fence.opening(in: content, baseIndent: indent) {
            return consumeFences(from: index, until: end, opening: fence)
        }
        if options.enableMathBlock, let opening = MathFence.opening(in: content) {
            return consumeMathBlock(from: index, until: end, opening: opening)
        }
        if options.enableMathBlock, MathFence.isLegacyOpening(content) {
            return consumeMathBlock(
                from: index, until: end,
                opening: MathFence.Opening(open: "\\[", close: "\\]", tag: nil, isSingleLine: false)
            )
        }
        if let rule = HorizontalRule.match(content) {
            var block = BlockNode(
                id: ids.allocate(), kind: .hr, source: slice(from: index, through: index)
            )
            block.attributes.hrChar = rule.character
            block.attributes.hrLength = rule.length
            return Step(block: block, nextLine: index + 1)
        }
        if let heading = ATXHeading.match(content) {
            var block = BlockNode(
                id: ids.allocate(), kind: .heading, source: slice(from: index, through: index)
            )
            block.attributes.level = heading.level
            block.attributes.isSetext = false
            block.inlines = InlineLexer.parse(heading.text, options: options.inline)
            return Step(block: block, nextLine: index + 1)
        }
        if let level = setextLevel(for: index, until: end, current: content) {
            var block = BlockNode(
                id: ids.allocate(), kind: .heading,
                source: slice(from: index, through: index + 1)
            )
            block.attributes.level = level
            block.attributes.isSetext = true
            block.inlines = InlineLexer.parse(content, options: options.inline)
            return Step(block: block, nextLine: index + 2)
        }
        if let token = TableOfContents.token(in: content) {
            var block = BlockNode(
                id: ids.allocate(), kind: .toc, source: slice(from: index, through: index)
            )
            block.attributes.tocToken = token
            return Step(block: block, nextLine: index + 1)
        }
        if let definition = LinkDefinition.match(content) {
            var block = BlockNode(
                id: ids.allocate(),
                kind: definition.isFootnote ? .footnoteDefinition : .linkDefinition,
                source: slice(from: index, through: index)
            )
            block.attributes.definitionLabel = definition.label
            block.attributes.definitionDestination = definition.destination
            block.attributes.definitionTitle = definition.title
            return Step(block: block, nextLine: index + 1)
        }
        if options.enableAlert, let alert = Alert.match(content) {
            var step = consumeBlockquote(from: index, until: end)
            step.block.attributes.alert = alert
            return step
        }
        if Blockquote.isQuote(content, baseIndent: indent) {
            return consumeBlockquote(from: index, until: end)
        }
        if let table = consumeTable(at: index, until: end) {
            return table
        }
        if ListItem.match(content, baseIndent: indent) != nil {
            return consumeList(from: index, until: end)
        }
        if HTMLBlock.isOpening(content) {
            return consumeHTMLBlock(from: index, until: end)
        }
        return nil
    }

    private func setextLevel(for index: Int, until end: Int, current: String) -> Int? {
        guard index + 1 < end else { return nil }
        let next = String(lines[index + 1].text)
        guard !next.isEmpty, !current.isEmpty else { return nil }
        // `level(for:)` accepts only pure `=`/`-` runs, which is exactly the
        // setext underline shape - a list item, quote or fence line cannot
        // reach here. A dash run doubles as a thematic break, but the setext
        // underline wins when a paragraph precedes it (CommonMark):
        // `Foo\n---` is an h2, only a lone `---` is a rule.
        return SetextHeading.level(for: next)
    }

    private func leadingSpaces(_ value: Substring) -> Int? {
        var count = 0
        var sawAny = false
        for character in value {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 4
            } else {
                break
            }
            sawAny = true
        }
        return sawAny ? count : nil
    }

    /// Walks `cursor` back over blank lines, never past `floor`.
    ///
    /// Used when a container reaches the end of its region without closing: the
    /// blank lines that follow are document content, not container body, and
    /// swallowing them would drop a byte on round-trip.
    private func rewindTrailingBlanks(_ cursor: inout Int, from floor: Int) {
        while cursor > floor, lines[cursor - 1].isBlank { cursor -= 1 }
    }

    /// Lines `start ... end` joined with newlines, both bounds inclusive.
    ///
    /// Each join re-uses the terminator the *previous* line had in the original:
    /// `\r\n` for a CRLF line. Stripping `\r` for matching must not cost the byte
    /// on the way back out - that was how saving quietly converted every CRLF file
    /// to LF.
    private func slice(from start: Int, through end: Int) -> String {
        guard start >= 0, end < lines.count, start <= end else { return "" }
        var result = ""
        for position in start...end {
            if position > start {
                result += lines[position - 1].hasCR ? "\r\n" : "\n"
            }
            result += lines[position].text
        }
        return result
    }

    // MARK: - Paragraph

    private mutating func consumeParagraph(from start: Int, until end: Int) -> Step {
        var cursor = start
        var parts: [Substring] = []
        var terminators: [String] = []
        while cursor < end {
            if lines[cursor].isBlank { break }
            let content = String(lines[cursor].text)
            if cursor > start, terminatesParagraph(content) { break }
            parts.append(lines[cursor].text)
            // The inline content keeps each line's own terminator so the buffer it
            // produces stays byte-exact for CRLF documents.
            terminators.append(lines[cursor].hasCR ? "\r\n" : "\n")
            cursor += 1
        }
        var block = BlockNode(
            id: ids.allocate(), kind: .paragraph, source: slice(from: start, through: cursor - 1)
        )
        block.inlines = InlineLexer.parse(
            joinForInlining(parts, terminators: terminators), options: options.inline
        )
        return Step(block: block, nextLine: cursor)
    }

    private func joinForInlining(_ parts: [Substring], terminators: [String]) -> String {
        guard parts.count > 1 else { return parts.first.map(String.init) ?? "" }
        if options.ignoreLineBreak { return parts.map(String.init).joined(separator: " ") }
        var joined = ""
        for (index, part) in parts.enumerated() {
            joined += part
            if index < parts.count - 1, index < terminators.count {
                joined += terminators[index]
            }
        }
        return joined
    }

    private func terminatesParagraph(_ content: String) -> Bool {
        ATXHeading.match(content) != nil
            || HorizontalRule.match(content) != nil
            || Blockquote.isQuote(content, baseIndent: 0)
            || Fence.opening(in: content, baseIndent: 0) != nil
            || ListItem.match(content, baseIndent: 0) != nil
            || (options.enableAlert && Alert.match(content) != nil)
    }

    // MARK: - Fenced code

    private mutating func consumeFences(
        from start: Int, until end: Int, opening: Fence.Opening
    ) -> Step {
        var cursor = start + 1
        var closed = false
        while cursor < end {
            if Fence.closing(String(lines[cursor].text), for: opening) != nil {
                cursor += 1
                closed = true
                break
            }
            cursor += 1
        }
        if !closed {
            // An unclosed fence must not swallow the blank lines at end of file;
            // they belong to the document, not the fence body.
            rewindTrailingBlanks(&cursor, from: start + 1)
        }
        var block = BlockNode(
            id: ids.allocate(), kind: .fences, source: slice(from: start, through: cursor - 1)
        )
        block.attributes.fenceChar = opening.character
        block.attributes.fenceLength = opening.length
        block.attributes.infoString = opening.info
        block.attributes.language = opening.language
        return Step(block: block, nextLine: cursor)
    }

    // MARK: - Indented code

    private mutating func consumeIndentedCode(from start: Int, until end: Int) -> Step {
        var cursor = start
        var lastContent = start
        while cursor < end {
            if lines[cursor].isBlank {
                var lookahead = cursor
                while lookahead < end, lines[lookahead].isBlank { lookahead += 1 }
                // `lookahead > cursor` or the cursor never moves: a blank line that is
                // not followed by more indented code ends the block. Without this the
                // loop assigns `cursor = cursor` and spins forever, which is what a
                // `4. ` list item followed by an indented `>` did.
                if lookahead > cursor, lookahead < end,
                    (leadingSpaces(lines[lookahead].text) ?? 0) >= 4
                {
                    cursor = lookahead
                    continue
                }
                break
            }
            guard (leadingSpaces(lines[cursor].text) ?? 0) >= 4 else { break }
            lastContent = cursor
            cursor += 1
        }
        let block = BlockNode(
            id: ids.allocate(), kind: .indentedCode,
            source: slice(from: start, through: lastContent)
        )
        return Step(block: block, nextLine: max(cursor, lastContent + 1))
    }

    // MARK: - Math block

    private mutating func consumeMathBlock(
        from start: Int, until end: Int, opening: MathFence.Opening
    ) -> Step {
        var cursor = start + 1
        var close = opening.close
        if !opening.isSingleLine {
            var closed = false
            while cursor < end {
                if let candidate = MathFence.closing(String(lines[cursor].text)) {
                    close = candidate
                    cursor += 1
                    closed = true
                    break
                }
                cursor += 1
            }
            if !closed {
                rewindTrailingBlanks(&cursor, from: start + 1)
            }
        }
        var block = BlockNode(
            id: ids.allocate(), kind: .mathBlock, source: slice(from: start, through: cursor - 1)
        )
        block.attributes.mathOpen = opening.open
        block.attributes.mathClose = close
        block.attributes.mathTag = opening.tag
        return Step(block: block, nextLine: cursor)
    }

    // MARK: - HTML block

    private mutating func consumeHTMLBlock(from start: Int, until end: Int) -> Step {
        var cursor = start
        while cursor < end, !lines[cursor].isBlank { cursor += 1 }
        let block = BlockNode(
            id: ids.allocate(), kind: .htmlBlock, source: slice(from: start, through: cursor - 1)
        )
        return Step(block: block, nextLine: cursor)
    }

    // MARK: - Blockquote

    private mutating func consumeBlockquote(from start: Int, until end: Int) -> Step {
        var cursor = start
        var stripped: [Line] = []
        while cursor < end {
            let content = String(lines[cursor].text)
            if Blockquote.isQuote(content, baseIndent: 0) {
                stripped.append(Line(text: stripQuoteMarker(lines[cursor].text), offset: -1))
                cursor += 1
                continue
            }
            // Lazy continuation of the quoted paragraph.
            if !lines[cursor].isBlank, !terminatesParagraph(content),
                let previous = stripped.last, !previous.isBlank
            {
                stripped.append(Line(text: lines[cursor].text, offset: -1))
                cursor += 1
                continue
            }
            break
        }
        var block = BlockNode(
            id: ids.allocate(), kind: .blockquote, source: slice(from: start, through: cursor - 1)
        )
        block.attributes.quoteDepth = 1
        block.children = parseStrippedRegion(stripped)
        return Step(block: block, nextLine: cursor)
    }

    /// Removes the quote markers from a line.
    ///
    /// Exactly **one** `>` comes off per pass - plus the one space or tab that
    /// follows it, which is the CommonMark rule. One level per pass is also what
    /// keeps *nesting*: the old version stripped every `>` in a single sweep, so
    /// `> > deep` collapsed to `deep` and lost a quote level - the outline and
    /// HTML export both saw the wrong tree. Each recursion now removes exactly
    /// one marker, so the remaining levels come back one pass at a time.
    ///
    /// The remaining indentation still has to survive: dropping it too turned
    /// `    > x` into `x` on one pass and then `> x` on the next, so parsing the
    /// stripped region found another quote and recursed until the stack ran out.
    private func stripQuoteMarker(_ line: Substring) -> Substring {
        var value = line[...]
        // Skip the up-to-three leading spaces `isQuote` allows, then the marker.
        // Leaving them in place means the stripped line still matches `isQuote`, and
        // parsing the stripped region finds the same quote again - which is an infinite
        // recursion, not a rendering artefact.
        var leading = 0
        while leading < 3, value.first == " " {
            value = value.dropFirst()
            leading += 1
        }
        guard value.first == ">" else { return value }
        value = value.dropFirst()
        if value.first == " " || value.first == "\t" { value = value.dropFirst() }
        return value
    }

    /// Re-parses container children whose markers have been stripped. Those lines
    /// are not contiguous in the source, so their `sourceOffset` is left at -1;
    /// the container keeps the authoritative slice.
    private mutating func parseStrippedRegion(_ stripped: [Line]) -> [BlockNode] {
        let savedLines = lines
        let savedTracking = trackingOffsets
        lines = stripped
        trackingOffsets = false
        defer {
            lines = savedLines
            trackingOffsets = savedTracking
        }
        return parseRegion(0, stripped.count, indent: 0)
    }

    // MARK: - Table

    private mutating func consumeTable(at index: Int, until end: Int) -> Step? {
        let rows = (index..<end).map { String(lines[$0].text) }
        guard let parsed = TableRecognizer.match(rows: rows, at: 0) else { return nil }
        var consumed = index + parsed.rowTexts.count
        var bodyIndex = index + 2
        while bodyIndex < end {
            let text = String(lines[bodyIndex].text)
            guard text.contains("|"), !TableRecognizer.isDelimiterRow(text) else { break }
            bodyIndex += 1
        }
        consumed = bodyIndex
        // A row with fewer or more cells than the header still belongs to the
        // table; Markdown renderers pad or extend it, and the original keeps it.
        guard consumed > index + 1 else { return nil }

        var block = BlockNode(
            id: ids.allocate(), kind: .table, source: slice(from: index, through: consumed - 1)
        )
        var state = TableState()
        state.columnAlignments = parsed.alignments
        block.attributes.table = state
        // Cell content is lexed so the grid can render inline styling and so
        // search sees cell text. Cells draw their IDs from the parser's shared
        // allocator: numbering them from zero collided with top-level block IDs,
        // and a find hit inside a cell then resolved to an unrelated block -
        // highlight in the wrong place, Replace corrupting the wrong text.
        block.children = tableCells(parsed)
        return Step(block: block, nextLine: consumed)
    }

    private mutating func tableCells(_ parsed: TableRecognizer.Parsed) -> [BlockNode] {
        var cells: [BlockNode] = []
        for row in [parsed.header] + parsed.body {
            for cell in row.cells {
                var node = BlockNode(id: ids.allocate(), kind: .paragraph, source: cell)
                node.inlines = InlineLexer.parse(cell, options: options.inline)
                cells.append(node)
            }
        }
        return cells
    }

    // MARK: - List

    private mutating func consumeList(from start: Int, until end: Int) -> Step {
        var cursor = start
        var items: [BlockNode] = []
        var ordered = false
        var listStart = 1
        var loose = false

        while cursor < end {
            let content = String(lines[cursor].text)
            if content.isEmpty {
                var lookahead = cursor
                while lookahead < end, lines[lookahead].isBlank { lookahead += 1 }
                guard lookahead < end,
                    let item = ListItem.match(String(lines[lookahead].text), baseIndent: 0),
                    item.markerColumn <= 3
                else { break }
                loose = true
                cursor = lookahead
                continue
            }
            guard let item = ListItem.match(content, baseIndent: 0) else { break }
            if items.isEmpty {
                ordered = item.isOrdered
                listStart = item.startNumber
            } else if item.isOrdered != ordered {
                break
            }
            let step = consumeListItem(from: cursor, until: end, opening: item)
            items.append(step.block)
            cursor = step.nextLine
        }

        var block = BlockNode(
            id: ids.allocate(), kind: .list, source: slice(from: start, through: cursor - 1)
        )
        block.attributes.isOrdered = ordered
        block.attributes.listStart = listStart
        block.attributes.isLoose = loose
        block.children = items
        return Step(block: block, nextLine: cursor)
    }

    private mutating func consumeListItem(
        from start: Int, until end: Int, opening: ListItem.Opening
    ) -> Step {
        var cursor = start + 1
        var stripped = [Line(text: stripListMarker(lines[start].text, opening: opening), offset: -1)]
        let contentIndent = opening.contentColumn
        var loose = false

        while cursor < end {
            let content = String(lines[cursor].text)
            if content.isEmpty {
                var lookahead = cursor
                while lookahead < end, lines[lookahead].isBlank { lookahead += 1 }
                guard lookahead < end,
                    let spaces = leadingSpaces(lines[lookahead].text), spaces >= contentIndent
                else { break }
                for position in cursor..<lookahead {
                    stripped.append(Line(text: lines[position].text, offset: -1))
                }
                loose = true
                cursor = lookahead
                continue
            }
            let spaces = leadingSpaces(lines[cursor].text) ?? 0
            if spaces >= contentIndent {
                stripped.append(
                    Line(text: lines[cursor].text.dropFirst(min(spaces, contentIndent)), offset: -1)
                )
                cursor += 1
                continue
            }
            // Lazy paragraph continuation of the same item.
            if let previous = stripped.last, !previous.isBlank,
                !terminatesParagraph(content),
                ListItem.match(content, baseIndent: 0) == nil,
                HorizontalRule.match(content) == nil
            {
                stripped.append(Line(text: lines[cursor].text, offset: -1))
                cursor += 1
                continue
            }
            break
        }

        var block = BlockNode(
            id: ids.allocate(),
            kind: opening.taskState == nil ? .listItem : .taskItem,
            source: slice(from: start, through: cursor - 1)
        )
        block.attributes.bulletChar = opening.bullet
        block.attributes.orderedDelimiter = opening.delimiter
        block.attributes.checked = opening.taskState
        block.attributes.isOrdered = opening.isOrdered
        block.attributes.listStart = opening.startNumber
        block.attributes.isLoose = loose
        block.children = parseStrippedRegion(stripped)
        return Step(block: block, nextLine: cursor)
    }

    private func stripListMarker(_ line: Substring, opening: ListItem.Opening) -> Substring {
        let characters = Array(line)
        var cursor = 0
        var dropped = 0
        while cursor < characters.count, dropped < opening.markerColumn,
            characters[cursor] == " " || characters[cursor] == "\t"
        {
            dropped += characters[cursor] == "\t" ? 4 : 1
            cursor += 1
        }
        if cursor < characters.count,
            characters[cursor] == opening.bullet || characters[cursor] == opening.delimiter
        {
            cursor += 1
        }
        if cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" {
            cursor += 1
        }
        guard cursor < characters.count else { return "" }
        return Substring(characters[cursor...])
    }

    // MARK: - Front matter

    /// A leading `---` is only front matter when the document closes it. Without
    /// this check a document that starts with a horizontal rule and later has
    /// another one would swallow everything between them.
    private func hasFrontMatterCloser(from start: Int) -> Bool {
        let opening = String(lines[0].text).trimmingInlineWhitespace()
        var cursor = start
        while cursor < lines.count {
            let trimmed = String(lines[cursor].text).trimmingInlineWhitespace()
            if trimmed == opening || (opening == "---" && trimmed == "...") { return true }
            cursor += 1
        }
        return false
    }

    private func isFrontMatterOpening(_ content: String) -> Bool {
        let trimmed = content.trimmingInlineWhitespace()
        return trimmed == "---" || trimmed == "+++"
    }

    private mutating func consumeFrontMatter(from start: Int, until end: Int) -> Step {
        let opening = String(lines[start].text).trimmingInlineWhitespace()
        var cursor = start + 1
        while cursor < end {
            let trimmed = String(lines[cursor].text).trimmingInlineWhitespace()
            if trimmed == opening || (opening == "---" && trimmed == "...") { break }
            cursor += 1
        }
        if cursor < end { cursor += 1 }
        var block = BlockNode(
            id: ids.allocate(), kind: .frontMatter, source: slice(from: start, through: cursor - 1)
        )
        block.attributes.frontMatterFence = String(opening)
        block.sourceOffset = lines[start].offset
        return Step(block: block, nextLine: cursor)
    }
}
