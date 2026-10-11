import AppKit
import Foundation

/// Compiles a `MarkdownDocument` into an attributed string the editor can display.
///
/// ## The contract that makes this cheap
///
/// The produced text is the document's markdown **verbatim**, with attributes
/// layered on top. Nothing is inserted, removed or normalised, so:
///
///   * saving is a straight write of the text storage;
///   * the caret never has to be remapped across a layout change;
///   * undo needs no special handling for the render pass.
///
/// The only structural information added is the `md.*` attributes and the
/// decoration plan, both of which are attribute-only edits that never enter the
/// undo stack.
///
/// Block markers (`#`, `- `, `|`, fences) and inline markers (`**`, `[`, `` ` ``)
/// are emitted with `md.hidden = true`; `MarkerHider` turns that into zero
/// advance, which reproduces the original's clean reading surface.
struct AttributedBuilder {
    private let theme: EditorTheme
    private let context: LayoutContext

    init(theme: EditorTheme, context: LayoutContext) {
        self.theme = theme
        self.context = context
    }

    func build(_ document: MarkdownDocument) -> LayoutOutput {
        let state = BuildState(theme: theme, context: context)
        let result = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            if index > 0 {
                // Separator newline for the blank lines between blocks.
                result.append(NSAttributedString(string: "\n"))
            }
            for line in state.leadingText(for: block) {
                result.append(NSAttributedString(string: line))
            }
            state.append(block: block, into: result, depth: 0)
        }
        // The newline that terminates the last block is not part of that block's
        // source slice, so the loop above never emits it and the file would lose its
        // final newline on save. Whatever is missing has to be trailing newlines,
        // because every other character is accounted for by a block.
        // UTF-16 counts on both sides: `result.length` is in UTF-16 units, and
        // `String.count` is in Characters, so a document with an emoji would compare
        // two different units and skip the fix entirely.
        // Everything after the last block. `document.source` is the authority: it holds
        // the trailing blank lines *and* the file's final newline, and appending the
        // difference verbatim is what keeps a file that ends in a tab from losing it.
        // An empty document emits nothing and must stay empty.
        let source = document.source as NSString
        if source.length > result.length {
            result.append(
                NSAttributedString(string: source.substring(from: result.length))
            )
        }
        var output = LayoutOutput(attributed: result)
        output.blocks = state.blocks
        output.inlineNodes = state.inlineNodes
        output.markers = state.markers
        output.decorations = state.decorations
        return output
    }

    /// Mutable state threaded through the recursion.
    private final class BuildState {
        let theme: EditorTheme
        let context: LayoutContext
        var blocks: [BlockRange] = []
        var inlineNodes: [InlineRange] = []
        var markers: [MarkerOccurrence] = []
        var decorations: [Int: [DecorationPlan]] = [:]

        init(theme: EditorTheme, context: LayoutContext) {
            self.theme = theme
            self.context = context
        }

        /// Height an inline image needs on its line, or zero when it cannot be loaded.
        ///
        /// `Editor/InlineImagePainter` does the loading; this only mirrors its size cap
        /// so the layout pass and the painter agree without `Layout/` importing AppKit's
        /// image stack or knowing about the view.
        func imageHeight(of path: String, theme: EditorTheme) -> CGFloat {
            guard !path.isEmpty, !path.hasPrefix("http") else { return 0 }
            var url = URL(fileURLWithPath: path)
            if !path.hasPrefix("/") {
                guard let base = context.imageBaseDirectory else { return 0 }
                url = URL(fileURLWithPath: path, relativeTo: base)
            }
            guard let size = NSImage(contentsOf: url)?.size,
                size.width > 0, size.height > 0
            else { return 0 }
            let maximum: CGFloat = 480
            let scale = size.width > maximum ? maximum / size.width : 1
            return min(size.height * scale, maximum)
        }

        func register(_ plans: [DecorationPlan], for blockID: Int) {
            decorations[blockID, default: []].append(contentsOf: plans)
        }

        /// Reference-image destinations, keyed by block, resolved once by the caller.
        var referenceDestination: [Int: String] = [:]

        /// The blank-line text that precedes a block, appended verbatim.
        ///
        /// The caller already emitted the separator newline between two blocks, and
        /// `BlockNode.leadingText` holds exactly the remaining blank lines, so it is
        /// passed through untouched. Dropping its first newline here - which this
        /// used to do - removed one line from every block that followed a blank line,
        /// so `# A\n\nB` rendered as `# A\nB`.
        func leadingText(for block: BlockNode) -> [String] {
            let leading = block.leadingText
            return leading.isEmpty ? [] : [leading]
        }

        // MARK: Blocks

        func append(block: BlockNode, into result: NSMutableAttributedString, depth: Int) {
            let start = result.length
            // Markers emitted anywhere inside this block - block markers and inline
            // delimiters alike - inherit the paragraph style of the block's own text.
            let inherited = markerParagraphStyle(for: block)
            blockMarkerStyle = inherited
            isFirstLineOfBlock = true
            defer { blockMarkerStyle = nil }
            switch block.kind {
            case .paragraph:
                emit(
                    inlines: block.inlines, into: result,
                    style: BlockStyle.paragraph(theme: theme), block: block, depth: depth
                )
            case .heading:
                let style = BlockStyle.heading(theme: theme, level: block.attributes.level)
                register(style.decoration, for: block.id)
                // Markers first. Appending them after the text produced the string
                // "Credits#" for `# Credits`, which is a different document.
                emitHeadingMarkers(block, into: result, depth: depth)
                emit(inlines: block.inlines, into: result, style: style, block: block, depth: depth)
                emitHeadingTrailingSpace(block, into: result, depth: depth)
                emitSetextUnderline(block, into: result, depth: depth)
            case .blockquote:
                register(
                    [
                        DecorationPlan.quoteBar(
                            color: theme.quoteBar.nsColor,
                            width: theme.quoteBarWidth,
                            inset: theme.quoteIndent
                        )
                    ],
                    for: block.id
                )
                if let alert = block.attributes.alert {
                    register(
                        [
                            .alertBox(
                                title: alert.rawValue.capitalized,
                                background: theme.alertBackground.nsColor,
                                border: theme.alertBorder.nsColor
                            )
                        ],
                        for: block.id
                    )
                }
                let quoteStyle = BlockStyle.paragraph(theme: theme)
                let collapsed = BlockStyle.collapsed(from: quoteStyle, theme: theme)
                let lines = block.source.split(
                    separator: "\n", omittingEmptySubsequences: false
                )
                for (index, line) in lines.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: "\n")) }
                    var markerLength = 0
                    for character in line {
                        if character == ">" { markerLength += 1 } else { break }
                    }
                    if markerLength > 0, markerLength < line.count,
                        line[line.index(line.startIndex, offsetBy: markerLength)] == " "
                    {
                        markerLength += 1
                    }
                    if markerLength > 0 {
                        appendHiddenRun(
                            String(line.prefix(markerLength)), role: .quoteMark, into: result,
                            style: collapsed, block: block, depth: depth
                        )
                    }
                    // Rendered from the source line rather than from the child nodes:
                    // the children cover the same text but do not promise where their
                    // line breaks fall, and the buffer has to be byte-exact.
                    emitPlain(
                        String(line.dropFirst(markerLength)), into: result,
                        style: quoteStyle, block: block, depth: depth
                    )
                }
            case .list:
                appendList(block, into: result, depth: depth)
            case .listItem, .taskItem:
                appendListItem(block, into: result, depth: depth)
            case .fences:
                appendFences(block, into: result, depth: depth)
            case .indentedCode:
                emitPlain(
                    block.source, into: result, style: BlockStyle.codeFence(theme: theme),
                    block: block, depth: depth
                )
            case .mathBlock:
                appendMathBlock(block, into: result, depth: depth)
            case .htmlBlock:
                register(
                    [
                        .codeBlock(
                            background: theme.rawBlockEditingBackground.nsColor,
                            radius: EditorMetrics.radiusSmall
                        )
                    ],
                    for: block.id
                )
                emitPlain(
                    block.source, into: result, style: BlockStyle.htmlBlock(theme: theme),
                    block: block, depth: depth
                )
            case .table:
                appendTable(block, into: result, depth: depth)
            case .hr:
                register([.horizontalRule(color: theme.rule.nsColor, height: 2)], for: block.id)
                emitHidden(
                    block.source, into: result, style: BlockStyle.horizontalRule(theme: theme),
                    block: block, depth: depth
                )
            case .toc:
                register([.tocPlaceholder(color: theme.quoteText.nsColor)], for: block.id)
                emitHidden(
                    block.source, into: result, style: BlockStyle.definition(theme: theme),
                    block: block, depth: depth
                )
            case .frontMatter:
                emitHidden(
                    block.source, into: result, style: BlockStyle.frontMatter(theme: theme),
                    block: block, depth: depth
                )
            case .linkDefinition, .footnoteDefinition:
                // Definitions render weakly, with only the `[` and `]` markers
                // marked as syntax so the editor can reveal them on focus.
                let style = BlockStyle.definition(theme: theme)
                let isFootnote = block.kind == .footnoteDefinition
                let openRole: MarkerRole = isFootnote ? .footnoteOpen : .linkOpen
                let closeRole: MarkerRole = isFootnote ? .footnoteClose : .linkClose
                let source = block.source
                let label = block.attributes.definitionLabel
                let openLength = isFootnote ? min(2 + label.count, source.count) : 1
                appendHiddenRun(
                    String(source.prefix(openLength)), role: openRole, into: result,
                    style: style, block: block, depth: depth
                )
                let labelText = String(
                    (source as NSString).substring(
                        with: NSRange(location: openLength, length: max(label.utf16.count, 0))
                    )
                )
                if !labelText.isEmpty {
                    emitPlain(labelText, into: result, style: style, block: block, depth: depth)
                }
                let remaining = String(
                    (source as NSString).substring(from: openLength + label.utf16.count)
                )
                if remaining.hasSuffix("]") {
                    let body = String(remaining.dropLast())
                    emitPlain(body, into: result, style: style, block: block, depth: depth)
                    appendHiddenRun(
                        "]", role: closeRole, into: result,
                        style: style, block: block, depth: depth
                    )
                } else {
                    emitPlain(remaining, into: result, style: style, block: block, depth: depth)
                }
            case .emptyLine:
                emitHidden(
                    block.source, into: result,
                    style: BlockStyle.collapsed(from: BlockStyle.paragraph(theme: theme), theme: theme),
                    block: block, depth: depth
                )
            }
            blocks.append(
                BlockRange(
                    id: block.id, kind: block.kind,
                    range: NSRange(location: start, length: result.length - start),
                    sourceOffset: block.sourceOffset
                )
            )
        }

        private func appendList(_ block: BlockNode, into result: NSMutableAttributedString, depth: Int) {
            // The separator between two items is whatever the source had there - one
            // newline normally, two when a blank line separated them. The parser keeps
            // such a pair in one list block, so emitting a fixed single newline lost the
            // blank line. Each item's own text still comes from its child nodes, so
            // inline styling inside items is preserved.
            var cursor = block.source.startIndex
            for (index, item) in block.children.enumerated() {
                if index > 0 {
                    let separator = itemSeparator(in: block.source, from: cursor)
                    if !separator.isEmpty {
                        result.append(NSAttributedString(string: separator))
                    }
                }
                if let found = block.source.range(of: item.source, range: cursor..<block.source.endIndex) {
                    cursor = found.upperBound
                }
                appendListItem(
                    item, into: result, depth: depth,
                    parentIsOrdered: block.attributes.isOrdered, position: index + 1
                )
            }
            if block.children.isEmpty {
                emitPlain(
                    block.source, into: result, style: BlockStyle.paragraph(theme: theme),
                    block: block, depth: depth
                )
            }
        }

        /// The text between two list items: line breaks, and the whole of any *blank*
        /// line between them.
        ///
        /// It must stop at the indentation of the next content line, because that
        /// indentation is part of the next item's own source. Taking the whole
        /// whitespace run duplicated it, so ` * one` / ` * two` came back as
        /// ` * one` / `  * two` - one byte of drift per item, which is the kind of bug
        /// that only shows up as a corrupted save.
        private func itemSeparator(in source: String, from cursor: String.Index) -> String {
            var out = ""
            var index = cursor
            while index < source.endIndex {
                let character = source[index]
                if character == "\n" {
                    out.append(character)
                    index = source.index(after: index)
                    continue
                }
                if character == " " || character == "\t" {
                    // Consume the run, then keep it only if the line it sits on is blank.
                    var scan = index
                    while scan < source.endIndex, source[scan] == " " || source[scan] == "\t" {
                        scan = source.index(after: scan)
                    }
                    if scan < source.endIndex, source[scan] == "\n" {
                        out += source[index..<scan]
                        out.append("\n")
                        index = source.index(after: scan)
                        continue
                    }
                    break
                }
                break
            }
            return out
        }

        private func appendListItem(
            _ block: BlockNode, into result: NSMutableAttributedString, depth: Int,
            parentIsOrdered: Bool? = nil, position: Int = 1
        ) {
            guard let first = block.children.first else {
                emitPlain(
                    block.source, into: result, style: BlockStyle.paragraph(theme: theme),
                    block: block, depth: depth
                )
                return
            }
            let ordered = parentIsOrdered ?? block.attributes.isOrdered
            let marker: String
            if let checked = block.attributes.checked {
                marker = checked ? "x" : " "
            } else if ordered {
                marker = "\(block.attributes.listStart > 0 ? block.attributes.listStart : 1). "
            } else {
                marker = String(block.attributes.bulletChar) + " "
            }
            let style: BlockStyle
            if block.attributes.checked != nil {
                style = BlockStyle.taskItem(
                    theme: theme, depth: depth + 1, checked: block.attributes.checked == true
                )
            } else {
                style = BlockStyle.listItem(
                    theme: theme, ordered: ordered, depth: depth + 1, marker: marker
                )
            }
            register(style.decoration, for: block.id)
            // The list marker is the block's own source prefix; hide it and let the
            // decoration layer draw the bullet or number.
            //
            // For an ordered item the parser records only the digits as the bullet and
            // leaves the `. ` in the content, so the hidden run is taken from the
            // source rather than from `marker` - otherwise the `. ` was counted twice
            // and the buffer no longer matched. The content below is then taken from
            // the same source prefix so the two agree.
            let sourceMarkerLength = markerPrefixLength(of: block.source, ordered: ordered)
            let markerText = String(block.source.prefix(sourceMarkerLength))
            if ordered && block.attributes.checked == nil {
                // Ordered numbers are synthesised, so they must not be hidden and
                // must not occupy the marker column twice: hide the source digits.
                appendHiddenRun(
                    markerText, role: .orderedNumber, into: result,
                    style: BlockStyle.collapsed(from: style, theme: theme), block: block, depth: depth
                )
            } else {
                appendHiddenRun(
                    markerText, role: .bullet, into: result,
                    style: BlockStyle.collapsed(from: style, theme: theme), block: block, depth: depth
                )
            }
            // The rest of the first line is the item's inline content, and it comes
            // from the child node so it keeps its inline styling.
            let remainder = String(block.source.dropFirst(markerText.utf16.count))
            let (firstLine, followingLines) = splitFirstLine(remainder)
            // The child node's inlines are used only when they are *exactly* the item's
            // first line. Two cases where they are not, and where using them anyway
            // duplicated text:
            //
            //   * an ordered or task marker runs past the bullet, so the node's text
            //     still holds `. ` / `[x] ` - which came back as a shortcut link;
            //   * the node spans several lines (a nested list, an attribute block after
            //     `* Outline`), and the continuation below re-emits those lines.
            //
            // Falling back to the source loses inline styling in those two cases, which
            // is the trade this design makes everywhere else in the layout pass.
            let markerRunsPastBullet = ordered || block.attributes.checked != nil
            if !markerRunsPastBullet, first.inlines.verbatim == firstLine {
                emit(inlines: first.inlines, into: result, style: style, block: block, depth: depth)
            } else {
                emitPlain(
                    firstLine, into: result, style: style, block: block, depth: depth
                )
            }

            // Continuation lines - a wrapped item, or a nested list - are emitted from
            // the item's own source and the nested children are *not* visited. A
            // child's source does not carry the indentation (`- a` where the parent
            // line is `  - a`), so emitting both produced every nested item twice.
            //
            // The cost is that a nested item renders as its literal source line, with
            // no drawn bullet and no inline styling inside it.
            if !followingLines.isEmpty {
                let continuationStyle = BlockStyle.paragraph(theme: theme)
                result.append(NSAttributedString(string: "\n"))
                let lines = followingLines.split(separator: "\n", omittingEmptySubsequences: false)
                for (index, line) in lines.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: "\n")) }
                    emitPlain(
                        String(line), into: result, style: continuationStyle,
                        block: block, depth: depth
                    )
                }
            }
        }

        private func appendFences(_ block: BlockNode, into result: NSMutableAttributedString, depth: Int) {
            let source = block.source
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            let body = BlockStyle.codeFence(theme: theme)
            let collapsed = BlockStyle.collapsed(from: body, theme: theme)
            register(body.decoration, for: block.id)
            for (index, line) in lines.enumerated() {
                if index > 0 { result.append(NSMutableAttributedString(string: "\n")) }
                let isFence = index == 0 || index == lines.count - 1
                let isFenceLine =
                    isFence
                    && (Fence.opening(in: String(line), baseIndent: 0) != nil
                        || Fence.closing(String(line), for: block.opening) != nil)
                if isFenceLine {
                    appendHiddenRun(
                        String(line), role: .fenceDelimiter, into: result,
                        style: collapsed, block: block, depth: depth
                    )
                } else if isFence, !line.isEmpty {
                    appendHiddenRun(
                        String(line), role: .fenceDelimiter, into: result,
                        style: collapsed, block: block, depth: depth
                    )
                } else {
                    let start = result.length
                    emitPlain(String(line), into: result, style: body, block: block, depth: depth)
                    if block.attributes.language.isEmpty {
                        result.addAttribute(
                            .foregroundColor, value: theme.syntax.plain.nsColor,
                            range: NSRange(location: start, length: result.length - start)
                        )
                    } else {
                        CodeHighlighter.shared.apply(
                            to: result, text: String(line), language: block.attributes.language,
                            palette: theme.syntax, offset: start
                        )
                    }
                }
            }
        }

        private func appendMathBlock(
            _ block: BlockNode, into result: NSMutableAttributedString, depth: Int
        ) {
            let lines = block.source.split(separator: "\n", omittingEmptySubsequences: false)
            let body = BlockStyle.mathBlock(theme: theme)
            let collapsed = BlockStyle.collapsed(from: body, theme: theme)
            for (index, line) in lines.enumerated() {
                if index > 0 { result.append(NSMutableAttributedString(string: "\n")) }
                let trimmed = line.trimmingInlineWhitespace()
                if index == 0, trimmed.hasPrefix(block.attributes.mathOpen) {
                    appendHiddenRun(
                        String(line), role: .mathDelimiter, into: result,
                        style: collapsed, block: block, depth: depth
                    )
                } else if index == lines.count - 1, trimmed.hasPrefix(block.attributes.mathClose) {
                    appendHiddenRun(
                        String(line), role: .mathDelimiter, into: result,
                        style: collapsed, block: block, depth: depth
                    )
                } else {
                    emitPlain(String(line), into: result, style: body, block: block, depth: depth)
                }
            }
        }

        private func appendTable(_ block: BlockNode, into result: NSMutableAttributedString, depth: Int) {
            var style = BlockStyle.table(theme: theme)
            var rows = block.source.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            // The block's own trailing newline shows up as a final empty component.
            if rows.last?.isEmpty == true { rows.removeLast() }

            // Row 1 is the delimiter row when the table is well formed; it carries the
            // column alignments and is never painted. It still has to be emitted: the
            // buffer is the source, so dropping it would lose a line of Markdown.
            let delimiterIndex: Int? =
                rows.count > 1 && TableRecognizer.isDelimiterRow(rows[1]) ? 1 : nil
            let alignments =
                delimiterIndex.map { TableGrid.alignments(fromDelimiterRow: rows[$0]) } ?? []
            let paintedRows = rows.enumerated().compactMap { index, row in
                index == delimiterIndex ? nil : TableGrid.cells(in: row)
            }

            let grid = TableGrid(
                rows: paintedRows, alignments: alignments,
                theme: theme, containerWidth: context.containerWidth,
                delimiterIndex: delimiterIndex
            )
            style.decoration.append(.tableGrid(grid))
            register(style.decoration, for: block.id)

            // Every character of the table is zero-width: the columns are painted, so
            // leaving the pipes as advancing text would draw the source a second time.
            //
            // Each row's paragraph style carries that row's own height: a cell that
            // wraps needs several line boxes of room, and a zero-width line never
            // wraps on its own. Only the first row keeps the block margin - the
            // rest inherit it from the style change rather than adding their own.
            //
            // The separator newline gets the row it *precedes*, not the one it
            // follows: TextKit sizes a line from the paragraph style at the line's
            // first character, and that character is the previous line's terminator,
            // so the other attribution shifted every row's height onto the row above.
            // It stays out of the painted run - a newline may never carry
            // `md.hidden`, or its glyph is dropped and the line never breaks.
            for (index, row) in rows.enumerated() {
                let paragraph = grid.paragraphStyle(
                    forSourceRow: index, revealed: false,
                    spacing: index == 0 ? theme.blockMargin : 0
                )
                if index > 0 {
                    result.append(
                        NSAttributedString(
                            string: "\n",
                            attributes: [
                                .paragraphStyle: paragraph
                            ]))
                }
                var rowStyle = style
                rowStyle.base[.paragraphStyle] = paragraph
                appendPainted(row, into: result, style: rowStyle, block: block, depth: depth)
            }
            if block.source.hasSuffix("\n") {
                appendPainted("", into: result, style: style, block: block, depth: depth)
            }
        }

        /// Emits text that carries no glyphs because a decoration draws it instead.
        ///
        /// `md.painted` is what lets focus bring the source back: `MarkerVisibility`
        /// reads it and unhides the block the caret is in.
        private func appendPainted(
            _ text: String, into result: NSMutableAttributedString,
            style: BlockStyle, block: BlockNode, depth: Int
        ) {
            guard !text.isEmpty else { return }
            let start = result.length
            // No `blockMarkerStyle` here: painted text *is* the block's own text, and
            // the table hands each row the style it was sized with. Swapping in the
            // block's base style would flatten every row back to one height.
            var attributes = style.base
            attributes[.font] = style.font
            attributes[.foregroundColor] = style.textColor
            attributes[MarkdownAttribute.painted] = true
            attributes[MarkdownAttribute.hidden] = !context.showsAllMarkers
            // The block metadata is what lets the decorator find its drawing plans for
            // this line; without it the row is invisible *and* unpainted.
            result.append(
                NSAttributedString(
                    string: text,
                    attributes: attributes.merged(blockAttributes(block, depth: depth))
                )
            )
            _ = start
        }

        // MARK: Inline

        /// The single point every emitted run goes through.
        ///
        /// Funnelling the appends through one place is what lets the blockquote
        /// render from its own source lines while everything else renders from the
        /// node tree, without either path having to know about the other.
        private func append(
            _ text: String, _ attributes: [NSAttributedString.Key: Any],
            to result: NSMutableAttributedString
        ) {
            // TextKit takes paragraph properties from a paragraph's *first* run, so a
            // run that spans a newline would give every one of its lines the block
            // margin. Split on newlines and hand the continuation lines the margin-free
            // style, which is what makes wrapped lines sit tight under the first line.
            guard text.contains("\n") else {
                result.append(NSAttributedString(string: text, attributes: attributes))
                return
            }
            let segments = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, segment) in segments.enumerated() {
                let isLast = index == segments.count - 1
                let piece = String(segment) + (isLast ? "" : "\n")
                var pieceAttributes = attributes
                if index > 0, let paragraph = pieceAttributes[.paragraphStyle] as? NSParagraphStyle {
                    pieceAttributes[.paragraphStyle] = withoutSpacingBefore(paragraph)
                }
                result.append(NSAttributedString(string: piece, attributes: pieceAttributes))
            }
            isFirstLineOfBlock = false
        }

        /// The paragraph style a block's markers must carry.
        ///
        /// It has to be the style of the block's *visible* text: a marker is the first
        /// run on its line, and TextKit takes the line's height from it.
        private func markerParagraphStyle(for block: BlockNode) -> NSParagraphStyle? {
            let style: BlockStyle
            switch block.kind {
            case .paragraph, .blockquote:
                style = BlockStyle.paragraph(theme: theme)
            case .heading:
                style = BlockStyle.heading(theme: theme, level: block.attributes.level)
            case .list, .listItem, .taskItem:
                // Only the paragraph style matters here; the list's own emitter
                // supplies the real indentation.
                style = BlockStyle.listItem(
                    theme: theme, ordered: block.attributes.isOrdered, depth: 0, marker: ""
                )
            case .table:
                style = BlockStyle.table(theme: theme)
            case .fences, .indentedCode:
                style = BlockStyle.codeFence(theme: theme)
            case .mathBlock:
                style = BlockStyle.mathBlock(theme: theme)
            case .htmlBlock:
                style = BlockStyle.htmlBlock(theme: theme)
            case .linkDefinition, .footnoteDefinition:
                style = BlockStyle.definition(theme: theme)
            case .hr, .toc, .frontMatter, .emptyLine:
                // These lines carry no visible text of their own; their own collapsed
                // style is already correct and is applied by `emitHidden`.
                return nil
            }
            return style.base[.paragraphStyle] as? NSParagraphStyle
        }

        /// The paragraph style hidden markers must inherit, set for the duration of a
        /// block's emission.
        private var blockMarkerStyle: NSParagraphStyle?
        /// Whether the next emitted line is the *first* line of a block.
        ///
        /// TextKit makes every newline in the buffer a paragraph, so a soft line break
        /// inside a paragraph is indistinguishable from a new block. Carrying the block
        /// margin on every line therefore opened up wrapped lines as well; only the
        /// first line of a block may carry it.
        private var isFirstLineOfBlock = true

        /// Attributes for one visible run: the style's base, then the font and
        /// colour it resolved to, then the block metadata the editor reads back.
        private func runAttributes(
            _ style: BlockStyle, block: BlockNode, depth: Int, color: NSColor? = nil
        ) -> [NSAttributedString.Key: Any] {
            var attributes = style.base
            attributes[.font] = style.font
            attributes[.foregroundColor] = color ?? style.textColor
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
                attributes[.paragraphStyle] =
                    isFirstLineOfBlock
                    ? paragraph
                    : withoutSpacingBefore(paragraph)
            }
            return attributes.merged(blockAttributes(block, depth: depth))
        }

        /// The same paragraph style with the gap above removed.
        ///
        /// On a **mutable copy**: every run of a block shares the single
        /// `NSParagraphStyle` in `BlockStyle.base`, so clearing the spacing in place
        /// also cleared it for the first line - which is why no block showed a gap.
        /// `copy()` is not enough, it hands back an immutable instance.
        private func withoutSpacingBefore(_ style: NSParagraphStyle) -> NSParagraphStyle {
            guard let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return style }
            copy.paragraphSpacingBefore = 0
            return copy
        }

        private func emit(
            inlines: [InlineNode], into result: NSMutableAttributedString,
            style: BlockStyle, block: BlockNode, depth: Int
        ) {
            for node in inlines {
                emit(inline: node, into: result, style: style, block: block, depth: depth)
            }
        }

        private func emit(
            inline node: InlineNode, into result: NSMutableAttributedString,
            style: BlockStyle, block: BlockNode, depth: Int
        ) {
            switch node.kind {
            case .text, .softBreak, .hardBreak:
                append(
                    node.verbatim, runAttributes(style, block: block, depth: depth), to: result
                )
            case .strong:
                appendDelimited(
                    node, into: result, style: style, block: block, depth: depth,
                    open: .strongOpen, close: .strongClose,
                    override: InlineStyle.strong(theme: theme, base: style))
            case .em:
                appendDelimited(
                    node, into: result, style: style, block: block, depth: depth,
                    open: .emphasisOpen, close: .emphasisClose,
                    override: InlineStyle.em(theme: theme, base: style))
            case .underline:
                appendDelimited(
                    node, into: result, style: style, block: block, depth: depth,
                    open: .emphasisOpen, close: .emphasisClose,
                    override: InlineStyle.underline(theme: theme, base: style))
            case .strike:
                appendDelimited(
                    node, into: result, style: style, block: block, depth: depth,
                    open: .strikethrough, close: .strikethrough,
                    override: InlineStyle.strike(theme: theme, base: style))
            case .highlight:
                appendDelimited(
                    node, into: result, style: style, block: block, depth: depth,
                    open: .highlight, close: .highlight,
                    override: InlineStyle.highlight(theme: theme, base: style))
            case .sub:
                appendDelimited(
                    node, into: result, style: style, block: block, depth: depth,
                    open: .`subscript`, close: .`subscript`,
                    override: InlineStyle.subscript(theme: theme, base: style))
            case .sup:
                appendDelimited(
                    node, into: result, style: style, block: block, depth: depth,
                    open: .superscript, close: .superscript,
                    override: InlineStyle.superscript(theme: theme, base: style))
            case .code:
                let start = result.length
                append(
                    node.verbatim,
                    runAttributes(
                        InlineStyle.code(theme: theme, base: style).applied(to: style),
                        block: block, depth: depth
                    ),
                    to: result
                )
                register(
                    [
                        .inlineCode(
                            background: theme.inlineCodeBackground.nsColor,
                            radius: EditorMetrics.radiusSmall
                        )
                    ],
                    for: block.id
                )
                inlineNodes.append(
                    InlineRange(
                        index: inlineNodes.count, kind: node.kind,
                        range: NSRange(location: start, length: result.length - start),
                        blockID: block.id
                    )
                )
            case .link, .refLink:
                appendLink(node, into: result, style: style, block: block, depth: depth)
            case .image, .refImage:
                appendHiddenRun(
                    node.prefix, role: .imageOpen, into: result,
                    style: style, block: block, depth: depth,
                    inlineIndex: inlineNodes.count
                )
                // Record the path so the decoration layer can draw it. A reference
                // image resolves through the document's link definitions, which the
                // parser already populated on the block.
                let reference = node.attributes.reference
                let path =
                    node.attributes.destination
                    ?? (reference == nil ? nil : referenceDestination[block.id])
                    ?? ""
                let alt = node.payload.isEmpty ? (node.attributes.name ?? "") : node.payload
                // The line has to be as tall as the picture or the painter draws into
                // a rect the text container already clipped. Height is resolved here,
                // at layout time, because the painter only exists in `Editor/`.
                let height = imageHeight(of: path, theme: theme)
                register([.inlineImage(path: path, alt: alt, height: height)], for: block.id)
                let start = result.length
                // The alt text is the placeholder the picture is drawn over, so it is
                // zero width too. It is not a marker, though: revealing it would put the
                // `![…]` syntax back without the path, so the hidden flag is set here
                // rather than through `appendHiddenRun`.
                let imageAttributes = runAttributes(
                    InlineStyle.image(theme: theme, base: style).applied(to: style),
                    block: block, depth: depth
                )
                append(alt, imageAttributes, to: result)
                if height > 0, let paragraph = imageAttributes[.paragraphStyle] as? NSParagraphStyle {
                    result.addAttribute(
                        .paragraphStyle,
                        value: NSParagraphStyle.withMinimumLineHeight(paragraph, minimum: height),
                        range: NSRange(location: start, length: result.length - start)
                    )
                }
                result.addAttribute(
                    MarkdownAttribute.hidden, value: true && !context.showsAllMarkers,
                    range: NSRange(location: start, length: result.length - start)
                )
                appendHiddenRun(
                    node.suffix, role: .imageClose, into: result,
                    style: style, block: block, depth: depth,
                    inlineIndex: inlineNodes.count
                )
                inlineNodes.append(
                    InlineRange(
                        index: inlineNodes.count, kind: node.kind,
                        range: NSRange(location: start, length: result.length - start),
                        blockID: block.id
                    )
                )
            case .autolink:
                // `<https://…>` carries its delimiters in prefix/suffix; emitting only
                // the payload dropped both angle brackets and shortened the buffer by
                // two characters per autolink.
                appendLink(node, into: result, style: style, block: block, depth: depth)
            case .footnoteRef:
                appendDelimited(
                    node, into: result, style: style, block: block, depth: depth,
                    open: .footnoteOpen, close: .footnoteClose,
                    override: InlineStyle.footnoteRef(theme: theme, base: style))
            case .inlineMath:
                // The `$` delimiters are syntax, not content, so they are hidden runs
                // that come back when the caret enters the element - the same treatment
                // every other inline delimiter gets.
                let start = result.length
                appendDelimited(
                    node, into: result, style: style, block: block, depth: depth,
                    open: .mathDelimiter, close: .mathDelimiter,
                    override: InlineStyle.inlineMath(theme: theme, base: style))
                inlineNodes.append(
                    InlineRange(
                        index: inlineNodes.count, kind: node.kind,
                        range: NSRange(location: start, length: result.length - start),
                        blockID: block.id
                    )
                )

            case .escape, .entity:
                append(
                    node.verbatim,
                    runAttributes(
                        style, block: block, depth: depth, color: theme.marker.nsColor
                    ),
                    to: result
                )
            case .emoji, .html, .ruby:
                append(
                    node.verbatim, runAttributes(style, block: block, depth: depth), to: result
                )
            }
        }

        private func appendLink(
            _ node: InlineNode, into result: NSMutableAttributedString,
            style: BlockStyle, block: BlockNode, depth: Int
        ) {
            let inlineIndex = inlineNodes.count
            let linkStyle =
                node.kind == .autolink
                ? InlineStyle.autolink(theme: theme, base: style)
                : InlineStyle.link(theme: theme, base: style)
            let hiddenStyle = BlockStyle.collapsed(from: style, theme: theme)
            appendHiddenRun(
                node.prefix, role: .linkOpen, into: result, style: hiddenStyle,
                block: block, depth: depth, inlineIndex: inlineIndex
            )
            // The children are emitted with the *derived* style. Emitting them with
            // the block's style is what silently dropped the link colour and
            // underline: the override was computed, then handed to nobody.
            let childStyle = linkStyle.applied(to: style)
            let start = result.length
            for child in node.children {
                emit(inline: child, into: result, style: childStyle, block: block, depth: depth)
            }
            if result.length == start {
                // A reference link falls back to its destination; an autolink has no
                // children and its payload *is* the text.
                append(
                    node.attributes.destination ?? node.payload,
                    runAttributes(childStyle, block: block, depth: depth),
                    to: result
                )
            }
            appendHiddenRun(
                node.suffix, role: .linkClose, into: result, style: hiddenStyle,
                block: block, depth: depth, inlineIndex: inlineIndex
            )
            inlineNodes.append(
                InlineRange(
                    index: inlineIndex, kind: node.kind,
                    range: NSRange(location: start, length: max(result.length - start, 1)),
                    blockID: block.id
                )
            )
        }

        /// Emits `prefix + children + suffix`, hiding both delimiters and tagging
        /// them so the editor can reveal them when the caret enters the element.
        private func appendDelimited(
            _ node: InlineNode, into result: NSMutableAttributedString,
            style: BlockStyle, block: BlockNode, depth: Int,
            open: MarkerRole, close: MarkerRole, override overrideStyle: InlineStyle.Overrides
        ) {
            let inlineIndex = inlineNodes.count
            let hiddenStyle = BlockStyle.collapsed(from: style, theme: theme)
            appendHiddenRun(
                node.prefix, role: open, into: result, style: hiddenStyle,
                block: block, depth: depth, inlineIndex: inlineIndex
            )
            // Passing the unmodified `style` here is what made every delimited
            // element a no-op: `***bold italic***` and `**bold *italic***` rendered
            // as plain body text. The override has to reach the children as a style.
            let childStyle = overrideStyle.applied(to: style)
            let start = result.length
            for child in node.children {
                emit(inline: child, into: result, style: childStyle, block: block, depth: depth)
            }
            if result.length == start {
                // A leaf delimited node carries its content in `payload`, not in
                // children: a footnote reference has none, so emitting an empty string
                // rendered `[^note]` as `[]`.
                append(
                    node.payload,
                    runAttributes(childStyle, block: block, depth: depth),
                    to: result
                )
            }
            appendHiddenRun(
                node.suffix, role: close, into: result, style: hiddenStyle,
                block: block, depth: depth, inlineIndex: inlineIndex
            )
            inlineNodes.append(
                InlineRange(
                    index: inlineIndex, kind: node.kind,
                    range: NSRange(location: start, length: max(result.length - start, 1)),
                    blockID: block.id
                )
            )
        }

        /// Emits a run that carries no visible width.
        private func appendHiddenRun(
            _ text: String, role: MarkerRole, into result: NSMutableAttributedString,
            style: BlockStyle, block: BlockNode, depth: Int, inlineIndex: Int? = nil
        ) {
            guard !text.isEmpty else { return }
            let index = markers.count
            let range = NSRange(location: result.length, length: (text as NSString).length)
            var attributes = style.base
            // A marker shares its line with the block's text, so it must carry the
            // block's paragraph style. See `BlockStyle.collapsed(from:theme:)`.
            if let paragraph = blockMarkerStyle { attributes[.paragraphStyle] = paragraph }
            attributes[.font] = style.font
            attributes[.foregroundColor] = style.textColor
            attributes[MarkdownAttribute.marker] = index
            attributes[MarkdownAttribute.hidden] = role.isHiddenWhenIdle && !context.showsAllMarkers
            append(text, attributes.merged(blockAttributes(block, depth: depth)), to: result)
            markers.append(
                MarkerOccurrence(
                    index: index, text: text, range: range, blockID: block.id,
                    inlineIndex: inlineIndex
                )
            )
        }

        private func emitPlain(
            _ text: String, into result: NSMutableAttributedString,
            style: BlockStyle, block: BlockNode, depth: Int
        ) {
            guard !text.isEmpty else { return }
            var attributes = style.base
            attributes[.font] = style.font
            attributes[.foregroundColor] = style.textColor
            append(text, attributes.merged(blockAttributes(block, depth: depth)), to: result)
        }

        private func emitHidden(
            _ text: String, into result: NSMutableAttributedString,
            style: BlockStyle, block: BlockNode, depth: Int
        ) {
            guard !text.isEmpty else { return }
            var attributes = style.base
            attributes[.font] = style.font
            attributes[.foregroundColor] = style.textColor
            attributes[MarkdownAttribute.hidden] = !context.showsAllMarkers
            append(text, attributes.merged(blockAttributes(block, depth: depth)), to: result)
        }

        private func blockAttributes(_ block: BlockNode, depth: Int) -> [NSAttributedString.Key: Any] {
            [
                MarkdownAttribute.block: block.id,
                MarkdownAttribute.blockKind: block.kind.rawValue,
                MarkdownAttribute.blockDepth: depth,
                MarkdownAttribute.rawBlock: block.kind.isAttachmentRendered,
            ]
        }

        private func emitHeadingMarkers(
            _ block: BlockNode, into result: NSMutableAttributedString, depth: Int
        ) {
            let source = block.source
            guard !block.attributes.isSetext else { return }
            let heading = BlockStyle.heading(theme: theme, level: block.attributes.level)
            // Up to three leading spaces are a legal ATX heading, and they are the
            // block's own first characters - skipping them made `#### Can inkstone` with
            // one space of indentation render as plain body text.
            let indentation = source.prefix { $0 == " " || $0 == "\t" }
            let afterIndentation = source.dropFirst(indentation.count)
            let hashes = afterIndentation.prefix { $0 == "#" }
            guard !hashes.isEmpty else { return }
            // The parser takes `# ` as the whole marker prefix, hashes *and* the space
            // after them, so the hidden run has to cover both. Emitting only the hashes
            // dropped the space and turned `# Credits` into `#Credits`.
            let afterHashes = afterIndentation.dropFirst(hashes.count)
            let spacing = afterHashes.prefix { $0 == " " || $0 == "\t" }
            appendHiddenRun(
                String(indentation) + String(hashes) + String(spacing), role: .headingHash,
                into: result, style: BlockStyle.collapsed(from: heading, theme: theme),
                block: block, depth: depth
            )
        }

        /// Trailing whitespace of a heading, which the parser trims out of the inline
        /// content but which is still part of the document.
        private func emitHeadingTrailingSpace(
            _ block: BlockNode, into result: NSMutableAttributedString, depth: Int
        ) {
            guard !block.attributes.isSetext else { return }
            let heading = BlockStyle.heading(theme: theme, level: block.attributes.level)
            let style = BlockStyle.collapsed(from: heading, theme: theme)
            var emitted = String(block.inlines.verbatim)
            for line in block.source.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    appendHiddenRun(text, role: .headingHash, into: result, style: style, block: block, depth: depth)
                    return
                }
                // The source line is `<indent>#<space>text<trailing>`; walk it with the
                // same three parts the marker run consumed, then anything left is the
                // trailing whitespace.
                var rest = Substring(text)
                rest = rest.dropFirst(rest.prefix { $0 == " " || $0 == "\t" }.count)
                rest = rest.dropFirst(rest.prefix { $0 == "#" }.count)
                rest = rest.dropFirst(rest.prefix { $0 == " " || $0 == "\t" }.count)
                let trailing = rest.dropFirst(min(emitted.count, rest.count))
                if !trailing.isEmpty {
                    appendHiddenRun(
                        String(trailing), role: .headingHash, into: result, style: style,
                        block: block, depth: depth
                    )
                }
                emitted = ""
                return
            }
        }

        private func emitSetextUnderline(
            _ block: BlockNode, into result: NSMutableAttributedString, depth: Int
        ) {
            // A setext heading has no `#`: the `===` / `---` underline is its marker,
            // and it sits *after* the text. It still has to reach the buffer - the rule
            // itself is drawn by the decoration layer, but the characters are part of
            // the document.
            guard block.attributes.isSetext else { return }
            let source = block.source
            guard let newline = source.firstIndex(of: "\n") else { return }
            let underline = String(source[source.index(after: newline)...])
            guard !underline.isEmpty else { return }
            // The newline between the text and its underline belongs to this block,
            // and `build` only emits newlines *between* blocks.
            result.append(NSAttributedString(string: "\n"))
            let heading = BlockStyle.heading(theme: theme, level: block.attributes.level)
            appendHiddenRun(
                underline, role: .headingHash, into: result,
                style: BlockStyle.collapsed(from: heading, theme: theme),
                block: block, depth: depth
            )
        }

        /// The length of a list item's marker prefix in its source: the bullet or the
        /// digits, the `)` or `.` that may follow an ordered marker, and the spaces
        /// after it.
        private func markerPrefixLength(of source: String, ordered: Bool) -> Int {
            var index = source.startIndex
            if ordered {
                while index < source.endIndex, source[index].isNumber { index = source.index(after: index) }
                if index < source.endIndex, source[index] == "." || source[index] == ")" {
                    index = source.index(after: index)
                }
            } else {
                while index < source.endIndex, index < source.index(index, offsetBy: 1),
                    !source[index].isWhitespace
                {
                    index = source.index(after: index)
                }
            }
            var spaces = 0
            while index < source.endIndex, source[index] == " " || source[index] == "\t" {
                index = source.index(after: index)
                spaces += 1
            }
            // A task item's `[ ]` / `[x]` is part of the marker too: the decoration
            // layer draws the checkbox, so the source characters must be hidden.
            if index < source.endIndex, source[index] == "[" {
                // Exactly one character between the brackets: `[ ]`, `[x]`, `[X]`.
                // Counting the steps to the `]` instead required three advances for a
                // two-character marker, so the test never passed and the `[x]` stayed
                // visible next to the checkbox the decoration layer had already drawn.
                let markerCharacter = source.index(after: index)
                let closing = source.index(after: markerCharacter)
                if closing < source.endIndex, source[closing] == "]" {
                    let flag = source[markerCharacter]
                    if flag == " " || flag == "x" || flag == "X" {
                        // Past the `]`, not onto it: stopping on the bracket made the
                        // prefix one character short, so `- [x] ` hid only `- [x` and
                        // the trailing bracket was re-emitted as a shortcut link.
                        index = source.index(after: closing)
                        while index < source.endIndex, source[index] == " " {
                            index = source.index(after: index)
                        }
                    }
                }
            }
            return source.distance(from: source.startIndex, to: index)
        }

        private func splitFirstLine(_ text: String) -> (String, String) {
            guard let newline = text.firstIndex(of: "\n") else { return (text, "") }
            return (String(text[..<newline]), String(text[text.index(after: newline)...]))
        }
    }
}

extension BlockNode {
    /// Reconstructs the opening fence so the delimiter rows can be recognised.
    fileprivate var opening: Fence.Opening {
        Fence.Opening(
            character: attributes.fenceChar,
            length: attributes.fenceLength,
            info: attributes.infoString,
            language: attributes.language,
            indent: 0
        )
    }
}

extension String {
    fileprivate func trimmingTrailingSpaces() -> String {
        var value = self
        while let last = value.last, last == " " || last == "\t" { value.removeLast() }
        return value
    }
}
