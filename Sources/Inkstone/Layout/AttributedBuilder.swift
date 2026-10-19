import AppKit
import Foundation
import SwiftTreeSitter

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
@MainActor
struct AttributedBuilder {
    private let theme: EditorTheme
    private let context: LayoutContext

    init(theme: EditorTheme, context: LayoutContext) {
        self.theme = theme
        self.context = context
    }

    func build(_ document: MarkdownDocument) -> LayoutOutput {
        let state = BuildState(theme: theme, context: context)
        // The `[TOC]` block renders every heading, wherever it sits, so the
        // list is resolved once up front rather than per block.
        state.headings = document.headings
        let result = NSMutableAttributedString()
        // CSS margin collapsing: the gap before a block is the larger of the
        // previous block's bottom margin and its own top margin (`0.8em` for
        // p/quote/list/table, `1rem` for headings and rules).
        var previousKind: BlockKind?
        var previousAppliedAfter: CGFloat = 0
        // The spacing a block has already applied AFTER its last line (its CSS
        // bottom margin — headings carry one, plain blocks don't). Rules apply
        // none either: `markdownRuleLine` sets `paragraphSpacing = 0` and the
        // block after a rule brings the full collapsed margin itself, so the
        // collapsed spacing below must not subtract the rule margin twice
        // (consecutive rules rendered with zero gap before this was fixed).
        func appliedSpacingAfter(_ kind: BlockKind) -> CGFloat {
            switch kind {
            case .heading: return theme.headingMargin
            default: return 0
            }
        }
        func cssMargin(_ kind: BlockKind) -> CGFloat {
            switch kind {
            case .heading: return theme.headingMargin
            case .hr: return theme.ruleMargin
            case .fences: return theme.fencesMargin
            default: return theme.blockMargin
            }
        }
        for (index, block) in document.blocks.enumerated() {
            var collapsedSpacing: CGFloat?
            if let previousKind {
                // CSS margin collapsing: max(previous bottom, own top), minus
                // what the previous block has already applied after its last
                // line (TextKit 1 sums the two; the reference collapses them).
                collapsedSpacing =
                    max(
                        cssMargin(previousKind), cssMargin(block.kind)
                    ) - previousAppliedAfter
            } else {
                // The first block: the reference drops a first child's
                // margin-top (`#write > :first-child` behaviour — measured:
                // the h1 box top sits at the content edge, no 16pt inset), so
                // no leading spacing here either.
                collapsedSpacing = 0
            }
            let boundaryStart = result.length
            var separatorLength = 0
            if index > 0 {
                // Separator for the blank lines between blocks: the terminator the
                // previous block ended with, `\r\n` included, so the buffer stays
                // byte-exact for CRLF documents.
                separatorLength = document.blocks[index - 1].endsWithCarriageReturn ? 2 : 1
                result.append(
                    NSAttributedString(
                        string: document.blocks[index - 1].endsWithCarriageReturn
                            ? "\r\n" : "\n"
                    )
                )
            }
            var leadingLength = 0
            for line in state.leadingText(for: block) {
                leadingLength += (line as NSString).length
                result.append(NSAttributedString(string: line))
            }
            // A fenced block's first row is its hidden opening delimiter: the
            // fence's padding-top rides on the boundary spacing, above it.
            var spacingOverride = collapsedSpacing ?? cssMargin(block.kind)
            if block.kind == .fences {
                spacingOverride += theme.codePaddingTop
            }
            state.append(
                block: block, into: result, depth: 0,
                spacingBefore: spacingOverride
            )
            previousAppliedAfter = appliedSpacingAfter(block.kind)
            previousKind = block.kind
            // Backfill the boundary runs (separator + leading blank lines) with a
            // collapsed line carrying the block's collapsed margin.
            //
            // A block whose source opens with hidden markers - `## `, `- `, the
            // fence - lays its first glyphs out with zero width, and TextKit glues
            // those glyphs backwards into the fragment that precedes them: the
            // block's first *line fragment* therefore begins at the separator, and
            // TextKit reads the line's geometry (height and `spacingBefore`) from
            // the fragment's first character — the boundary, NOT the block's own
            // style, whose spacing never applies there. Left unattributed, that
            // character yields the 14pt default with no spacing. Blocks that
            // start with visible text still need the hairline - an unstyled blank
            // line renders at full body height - but must stay flat: their own
            // paragraph applies the spacing inside the fragment, and a spacing on
            // the hairline as well doubled every paragraph gap (verified both on
            // screen and headlessly).
            let contentStart = boundaryStart + separatorLength + leadingLength
            guard contentStart > boundaryStart, contentStart < result.length,
                let leadingStyle = result.attribute(
                    .paragraphStyle, at: contentStart, effectiveRange: nil
                ) as? NSParagraphStyle
            else { continue }
            let boundary = NSMutableParagraphStyle()
            boundary.setParagraphStyle(leadingStyle)
            // The boundary hairline carries the block's spacing ONLY for glued
            // blocks (hidden first glyphs): TextKit reads the spacing of the
            // whole glued fragment from its FIRST character's paragraph style —
            // the boundary — so the block's own `spacingBefore` never applies
            // there, and the hairline is the only place it can come from.
            // Blocks whose first character is visible start their paragraph
            // normally and apply their own spacing inside the fragment; a
            // spacing on the hairline as well doubled every paragraph gap to
            // 2× the reference (verified both on screen and headlessly).
            boundary.paragraphSpacingBefore =
                MarkdownAttribute.isHidden(result, at: contentStart)
                ? (collapsedSpacing ?? 0)
                : 0
            // The hairline's AFTER-spacing must stay zero: it copies the block's
            // own style (a heading carries 16), and for blocks whose first row
            // absorbed the boundary newline (a setext heading's glued underline)
            // that after-margin stacked a second 16pt onto the gap. The block
            // after the hairline brings its own spacing.
            boundary.paragraphSpacing = 0
            boundary.minimumLineHeight = 0.01
            boundary.maximumLineHeight = 0.01
            boundary.lineHeightMultiple = 1
            result.addAttribute(
                .paragraphStyle, value: boundary,
                range: NSRange(location: boundaryStart, length: contentStart - boundaryStart)
            )
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
    ///
    /// Isolated like the builder itself: it calls into the tree-sitter
    /// highlighter, which caches parsers and is therefore main-actor only.
    @MainActor
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
            // Through the editor's decode cache: `rebuildLayout` runs on every
            // resize tick, and re-opening every image off the disk on the main
            // thread each time stalled window resizing badly.
            let size = context.imageSize?(url.path) ?? .zero
            guard size.width > 0, size.height > 0 else { return 0 }
            let maximum = context.imageMaxWidth
            let scale = size.width > maximum ? maximum / size.width : 1
            return min(size.height * scale, maximum)
        }

        func register(_ plans: [DecorationPlan], for blockID: Int) {
            decorations[blockID, default: []].append(contentsOf: plans)
        }

        /// Reference-image destinations, keyed by block, resolved once by the caller.
        var referenceDestination: [Int: String] = [:]
        /// Every heading in the document, for the `[TOC]` block to paint.
        var headings: [MarkdownDocument.Heading] = []

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

        /// Emits a blank line as a collapsed hairline row.
        ///
        /// Blank lines inside containers - between list items, between an item's
        /// paragraphs, inside a quote - are real bytes in the buffer but must
        /// render no row: the reference collapses them into the neighbouring
        /// blocks' margins. An unstyled blank row lays out at the font's natural
        /// height (~23.4pt for the CJK context), which showed up as extra space
        /// above loose list items and inside multi-paragraph items.
        ///
        /// The blank row's only character is the newline that terminates it, so
        /// collapse THAT newline - either directly when the blank's bytes are a
        /// run of newlines (a leading run), or by flagging the next separator
        /// (see `collapseNextSeparator` at the call sites). `spacingBefore`
        /// carries the margin the collapsed row stands in for where nothing
        /// else provides it: quote rows have no item spacing, so their blank
        /// line carries the `.5rem` paragraph margin; list rows get theirs from
        /// the marker hider's per-row item spacing, so their blanks stay flat.
        func emitBlankLine(
            _ rawLine: String, into result: NSMutableAttributedString,
            spacingBefore: CGFloat = 0
        ) {
            let length = (rawLine as NSString).length
            guard length > 0 else { return }
            let range = NSRange(location: result.length, length: length)
            result.append(NSAttributedString(string: rawLine))
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.minimumLineHeight = 0.01
            style.maximumLineHeight = 0.01
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }

        /// The newline after a blank line is that blank row's only character;
        /// the emitters flag it so the separator collapses (see emitBlankLine).
        func appendCollapsedNewline(
            into result: NSMutableAttributedString, spacingBefore: CGFloat = 0
        ) {
            let range = NSRange(location: result.length, length: 1)
            result.append(NSAttributedString(string: "\n"))
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.minimumLineHeight = 0.01
            style.maximumLineHeight = 0.01
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }

        // MARK: Blocks

        /// The task item's text column includes the checkbox cell (a 12pt box plus
        /// 4pt gaps on each side, as the reference's inline checkbox lays out).
        func taskTextColumn(_ indent: CGFloat) -> CGFloat { indent + 20 }

        /// `spacingBefore` carries the CSS-collapsed margin for top-level blocks
        /// (see the caller); nested calls keep their own style's spacing.
        func append(
            block: BlockNode, into result: NSMutableAttributedString, depth: Int,
            spacingBefore: CGFloat
        ) {
            let start = result.length
            // Plain-text offsets restart per block: a find hit's offset counts from
            // the block's own content.
            plainCursor = 0
            // Markers emitted anywhere inside this block - block markers and inline
            // delimiters alike - inherit the paragraph style of the block's own text.
            let inherited = markerParagraphStyle(for: block, spacingBefore: spacingBefore)
            blockMarkerStyle = inherited
            isFirstLineOfBlock = true
            defer { blockMarkerStyle = nil }
            /// The collapsed margin for top-level blocks; nested blocks (depth
            /// > 0) apply their own style's spacing.
            func collapsedStyle(_ style: BlockStyle) -> BlockStyle {
                guard depth == 0,
                    let paragraphStyle = style.base[.paragraphStyle]
                        as? NSParagraphStyle,
                    let mutable = paragraphStyle.mutableCopy()
                        as? NSMutableParagraphStyle
                else { return style }
                mutable.paragraphSpacingBefore = spacingBefore
                var styled = style
                styled.base[.paragraphStyle] = mutable
                return styled
            }
            switch block.kind {
            case .paragraph:
                emit(
                    inlines: block.inlines, into: result,
                    style: collapsedStyle(BlockStyle.paragraph(theme: theme)),
                    block: block, depth: depth
                )
            case .heading:
                let style = collapsedStyle(
                    BlockStyle.heading(theme: theme, level: block.attributes.level)
                )
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
                            inset: 0
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
                // The quote is emitted per child by `appendQuote`: nested quote
                // levels hide every `>` and compound the indent, like the
                // browser's `blockquote blockquote { padding-left }` cascade.
                appendQuote(
                    block, into: result, depth: depth, level: 1,
                    raw: nil, owner: nil, firstLinePreceded: true
                )
            case .list:
                // build() already emitted the block separator, so the list's first
                // line is preceded.
                appendList(block, into: result, depth: depth, firstLinePreceded: true)
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
                            radius: EditorMetrics.radiusSmall,
                            border: nil, topInset: 0, bottomInset: 0
                        )
                    ],
                    for: block.id
                )
                let start = result.length
                emitPlain(
                    block.source, into: result, style: BlockStyle.htmlBlock(theme: theme),
                    block: block, depth: depth
                )
                // The whole raw block is body: the decorator unions its lines for
                // the editing background (no insets, no border for this one).
                result.addAttribute(
                    MarkdownAttribute.codeBody, value: true,
                    range: NSRange(location: start, length: result.length - start)
                )
            case .table:
                appendTable(block, into: result, depth: depth)
            case .hr:
                register([.horizontalRule(color: theme.rule.nsColor, height: 2)], for: block.id)
                emitHidden(
                    block.source, into: result,
                    style: collapsedStyle(BlockStyle.horizontalRule(theme: theme)),
                    block: block, depth: depth
                )
            case .toc:
                appendTOC(block, into: result, depth: depth)
            case .frontMatter:
                appendFrontMatter(block, into: result, depth: depth)
            case .linkDefinition, .footnoteDefinition:
                // Definitions render weakly, with only the `[` and `]` markers
                // marked as syntax so the editor can reveal them on focus.
                let style = BlockStyle.definition(theme: theme)
                let isFootnote = block.kind == .footnoteDefinition
                let openRole: MarkerRole = isFootnote ? .footnoteOpen : .linkOpen
                let closeRole: MarkerRole = isFootnote ? .footnoteClose : .linkClose
                let source = block.source as NSString
                let label = block.attributes.definitionLabel
                // All offsets in UTF-16 units: `openLength` used to mix Character
                // counts into NSString ranges, which misaligned every definition
                // whose label held an astral character.
                let openLength =
                    isFootnote ? min(2 + label.utf16.count, source.length) : 1
                appendHiddenRun(
                    source.substring(with: NSRange(location: 0, length: openLength)),
                    role: openRole, into: result,
                    style: style, block: block, depth: depth
                )
                let labelText = source.substring(
                    with: NSRange(
                        location: openLength,
                        length: min(label.utf16.count, max(source.length - openLength, 0))
                    )
                )
                if !labelText.isEmpty {
                    emitPlain(labelText, into: result, style: style, block: block, depth: depth)
                }
                let remaining = source.substring(
                    from: min(openLength + label.utf16.count, source.length)
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

        private func appendList(
            _ block: BlockNode, into result: NSMutableAttributedString, depth: Int,
            raw: [String]? = nil, owner: BlockNode? = nil, firstLinePreceded: Bool = false,
            indentOffset: CGFloat = 0, leadingStrut: NSMutableParagraphStyle? = nil
        ) {
            var leadingStrut = leadingStrut
            // The parser strips each item's container indentation before parsing it,
            // so children know their own lines but not the whitespace that preceded
            // them in the file. `raw` hands those lines back: one per line of the
            // list's own source, byte-identical to the file. At the top level the
            // list's source lines *are* the raw lines.
            let sourceLines = block.source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let rawLines = raw ?? sourceLines
            guard !block.children.isEmpty else {
                if !firstLinePreceded { result.append(NSAttributedString(string: "\n")) }
                emitPlain(
                    rawLines.joined(separator: "\n"), into: result,
                    style: BlockStyle.paragraph(theme: theme),
                    block: owner ?? block, depth: depth
                )
                return
            }
            // The list owns the breaks before its lines: `beginLine` emits one before
            // every line except the very first when `firstLinePreceded` says that line
            // continues the caller's (a nested list that opens on its item's marker
            // line); the top-level call is preceded by build()'s block separator.
            var pendingFirstLine = true
            // Set after a blank line: the next separator newline is that blank
            // row's only character and must collapse (see emitBlankLine).
            var collapseNextSeparator = false
            func beginLine() {
                if !(pendingFirstLine && firstLinePreceded) {
                    if collapseNextSeparator {
                        appendCollapsedNewline(into: result)
                        collapseNextSeparator = false
                    } else if let strut = leadingStrut {
                        // The container's trailing blank row ends here: its
                        // terminator carries the row's strut (see appendQuote).
                        let range = NSRange(location: result.length, length: 1)
                        result.append(NSAttributedString(string: "\n"))
                        result.addAttribute(.paragraphStyle, value: strut, range: range)
                        leadingStrut = nil
                    } else {
                        result.append(NSAttributedString(string: "\n"))
                    }
                }
                pendingFirstLine = false
            }
            var lineCursor = 0
            // The list's own leading blank lines - its leading text when it sits as a
            // child inside an item - come out first; handing them to the first item's
            // slice would desynchronise the item's pairing and drop bytes.
            while lineCursor < rawLines.count, isBlankLine(rawLines[lineCursor]) {
                beginLine()
                emitBlankLine(rawLines[lineCursor], into: result)
                lineCursor += 1
            }
            for (index, item) in block.children.enumerated() {
                // The blank lines between two items reach the buffer verbatim. This
                // used to be `itemSeparator`, reading the same lines out of the
                // list's source; walking the raw lines instead also covers the tail
                // after the last item, which the old loop dropped - a blank line
                // between two lists of different flavours lands *inside* the first
                // list's source slice, and dropping it merged the lists on save.
                if index > 0 {
                    while lineCursor < rawLines.count, isBlankLine(rawLines[lineCursor]) {
                        beginLine()
                        collapseNextSeparator = true
                        lineCursor += 1
                    }
                }
                let itemLines = (item.leadingText + item.source)
                    .split(separator: "\n", omittingEmptySubsequences: false).count
                let sliceEnd = min(lineCursor + itemLines, rawLines.count)
                guard sliceEnd > lineCursor else { break }
                beginLine()
                appendListItem(
                    item, into: result, depth: depth,
                    parentIsOrdered: block.attributes.isOrdered,
                    raw: Array(rawLines[lineCursor..<sliceEnd]), owner: owner,
                    // The break before the item's first line is beginLine's; the item
                    // starts straight into its marker.
                    firstLinePreceded: true,
                    indentOffset: indentOffset
                )
                lineCursor = sliceEnd
            }
            // Whatever the items did not consume still belongs to the buffer.
            for line in rawLines[lineCursor...] {
                beginLine()
                if isBlankLine(line) {
                    collapseNextSeparator = true
                } else {
                    result.append(NSAttributedString(string: line))
                }
            }
        }

        /// Emits a blockquote from its raw lines, one nesting level per call.
        ///
        /// The browser indents every quote level by the quote's own padding
        /// (`blockquote { padding: 0 15px; border-left: 4px }` compounds per
        /// nesting) and hides the source's `>` markers at every level. The old
        /// top-level emitter flattened the levels: inner `>` markers surfaced
        /// as visible text at the outer indent, and the level's bar was lost.
        /// Each recursion strips exactly one marker level, compounds the
        /// indent and registers the level's own bar.
        ///
        /// Rows carry `md.block` of the visual owner (the outer quote) - the
        /// reference's block model claims the whole quote for the editor - and
        /// `md.subBlock` of the inner quote they belong to, so decorations
        /// scope per level exactly like the list item's children do.
        private func appendQuote(
            _ block: BlockNode, into result: NSMutableAttributedString, depth: Int,
            level: Int, raw: [String]? = nil, owner: BlockNode?,
            firstLinePreceded: Bool
        ) {
            let sourceLines = block.source.split(
                separator: "\n", omittingEmptySubsequences: false
            ).map(String.init)
            // The raw lines carry EVERY ancestor marker: the caller hands its
            // own slice down verbatim, and this level hides the full prefix
            // (one `> ` group per ancestor, this level's own included). Stripping
            // per level here would drop the ancestors' bytes - the buffer may
            // never lose a byte.
            let rawLines = raw ?? sourceLines
            let visualBlock = owner ?? block
            let selfSubBlock: Int? = visualBlock.id == block.id ? nil : block.id
            let savedBlockOverride = renderedBlockOverride
            let savedSubBlock = renderedSubBlock
            let savedSubKind = renderedSubKind
            renderedBlockOverride = visualBlock
            renderedSubBlock = selfSubBlock
            renderedSubKind = selfSubBlock == nil ? nil : block.kind.rawValue
            defer {
                renderedBlockOverride = savedBlockOverride
                renderedSubBlock = savedSubBlock
                renderedSubKind = savedSubKind
            }
            let insetPerLevel = theme.quoteIndent + theme.quoteBarWidth
            register(
                [
                    DecorationPlan.quoteBar(
                        color: theme.quoteBar.nsColor,
                        width: theme.quoteBarWidth,
                        inset: CGFloat(level - 1) * insetPerLevel
                    )
                ],
                for: block.id
            )
            let inset = CGFloat(level) * insetPerLevel
            var quoteStyle = BlockStyle.paragraph(theme: theme)
            quoteStyle.textColor = theme.quoteText.nsColor
            if let paragraphStyle = quoteStyle.base[.paragraphStyle]
                as? NSParagraphStyle,
                let mutable = paragraphStyle.mutableCopy()
                    as? NSMutableParagraphStyle
            {
                mutable.headIndent = inset
                mutable.firstLineHeadIndent = inset
                quoteStyle.base[.paragraphStyle] = mutable
            }
            let collapsed = BlockStyle.collapsed(from: quoteStyle, theme: theme)

            /// The length of the line's full marker prefix: one `>` group per
            /// level, each followed by one optional space. A lazy continuation
            /// line carries fewer groups; the prefix stops where the line does.
            func markerPrefixLength(_ line: String) -> Int {
                var index = line.startIndex
                var groups = 0
                while groups < level, index < line.endIndex, line[index] == ">" {
                    index = line.index(after: index)
                    if index < line.endIndex, line[index] == " " {
                        index = line.index(after: index)
                    }
                    groups += 1
                }
                return line.utf16.distance(from: line.startIndex, to: index)
            }
            func isBlankAtLevel(_ line: String) -> Bool {
                let prefix = markerPrefixLength(line)
                guard prefix > 0 else { return isBlankLine(line) }
                return String(line.dropFirst(prefix))
                    .trimmingCharacters(in: .whitespaces).isEmpty
            }

            // An empty `>` line separates the quote's paragraphs: the reference
            // renders it as the paragraph margin (12.8 at the top level), not a
            // full line. The strut carries that margin - TextKit drops
            // `paragraphSpacingBefore` on these glued empty rows.
            var blankLineStyle: NSMutableParagraphStyle?
            if let paragraphStyle = quoteStyle.base[.paragraphStyle]
                as? NSParagraphStyle,
                let mutable = paragraphStyle.mutableCopy()
                    as? NSMutableParagraphStyle
            {
                mutable.minimumLineHeight = theme.blockMargin
                mutable.maximumLineHeight = theme.blockMargin
                blankLineStyle = mutable
            }

            /// Hides the line's full marker prefix and renders the rest at this
            /// level's indent. `blankRow` styles the row as a paragraph margin.
            func emitLevelLine(_ rawLine: String, blankRow: Bool) {
                let markerLength = markerPrefixLength(rawLine)
                let lineContent = String(rawLine.dropFirst(markerLength))
                let isEmptyLine = lineContent.trimmingCharacters(in: .whitespaces).isEmpty
                let rowStyle =
                    (blankRow || isEmptyLine)
                    ? blankLineStyle
                    : (quoteStyle.base[.paragraphStyle] as? NSParagraphStyle)
                if markerLength > 0 {
                    appendHiddenRun(
                        String(rawLine.prefix(markerLength)), role: .quoteMark, into: result,
                        style: collapsed, block: visualBlock, depth: depth,
                        paragraphStyle: rowStyle
                    )
                }
                if !isEmptyLine {
                    emitPlain(
                        lineContent, into: result,
                        style: quoteStyle, block: visualBlock, depth: depth
                    )
                }
            }
            var pendingFirstLine = true
            // Set after a blank line: the next separator newline is that blank
            // row's only character, and the row's paragraph margin rides on its
            // strut (TextKit drops paragraphSpacingBefore on these glued empty
            // rows - see blankLineStyle above).
            var strutNextSeparator = false
            func beginLine() {
                if !(pendingFirstLine && firstLinePreceded) {
                    let range = NSRange(location: result.length, length: 1)
                    result.append(NSAttributedString(string: "\n"))
                    if strutNextSeparator, let style = blankLineStyle {
                        result.addAttribute(.paragraphStyle, value: style, range: range)
                    }
                    strutNextSeparator = false
                }
                pendingFirstLine = false
            }

            /// Emits one paragraph child from its inline nodes instead of raw
            /// text, so quoted paragraphs keep their inline styling. The rows'
            /// hidden `> ` markers interleave with the content bytes: each row
            /// break - a top-level soft or hard break in the node stream - turns
            /// the row over by appending the newline and the next row's marker
            /// prefix, exactly where the raw walk would have put them.
            ///
            /// Returns false when the nodes cannot rebuild the slice
            /// byte-for-byte: a break nested inside a container (its newline
            /// would swallow the next row's marker bytes), a blank row, or any
            /// drift between the parsed text and the raw lines. The caller then
            /// takes the raw walk, which is always byte-exact.
            func emitQuoteParagraphInlines(
                _ child: BlockNode, _ slice: [String], depth: Int
            ) -> Bool {
                guard !slice.isEmpty else { return false }
                var rows: [(prefix: String, content: String)] = []
                for line in slice {
                    if isBlankAtLevel(line) { return false }
                    let markerLength = markerPrefixLength(line)
                    rows.append(
                        (String(line.prefix(markerLength)), String(line.dropFirst(markerLength)))
                    )
                }
                // Every row boundary must be a top-level break the walk can
                // intercept, and every break must end in the newline it stands
                // for - otherwise the next row's marker bytes would be lost.
                func containsBreak(_ nodes: [InlineNode]) -> Bool {
                    nodes.contains { node in
                        node.kind == .softBreak || node.kind == .hardBreak
                            || containsBreak(node.children)
                    }
                }
                func hasNestedBreak(_ nodes: [InlineNode]) -> Bool {
                    nodes.contains { node in
                        node.kind != .softBreak && node.kind != .hardBreak
                            && containsBreak(node.children)
                    }
                }
                let breaks = child.inlines.filter { $0.kind == .softBreak || $0.kind == .hardBreak }
                guard breaks.count == rows.count - 1, !hasNestedBreak(child.inlines),
                    breaks.allSatisfy({ $0.verbatim.hasSuffix("\n") })
                else { return false }
                // The nodes were parsed from the rows' content; any drift means
                // emission would lose bytes.
                guard child.inlines.verbatim == rows.map(\.content).joined(separator: "\n")
                else { return false }
                beginLine()
                if !rows[0].prefix.isEmpty {
                    appendHiddenRun(
                        rows[0].prefix, role: .quoteMark, into: result,
                        style: collapsed, block: visualBlock, depth: depth,
                        paragraphStyle: quoteStyle.base[.paragraphStyle] as? NSParagraphStyle
                    )
                }
                plainCursor = 0
                var rowIndex = 0
                for node in child.inlines {
                    if node.kind == .softBreak || node.kind == .hardBreak {
                        // The break's bytes minus its newline - a hard break's
                        // trailing spaces - are still the previous row's content;
                        // the newline separates the rows and the next row's
                        // hidden marker prefix follows it.
                        rowIndex += 1
                        let head = String(node.verbatim.dropLast())
                        if !head.isEmpty {
                            append(
                                head, runAttributes(quoteStyle, block: visualBlock, depth: depth),
                                to: result
                            )
                        }
                        result.append(NSAttributedString(string: "\n"))
                        let row = rows[rowIndex]
                        if !row.prefix.isEmpty {
                            appendHiddenRun(
                                row.prefix, role: .quoteMark, into: result,
                                style: collapsed, block: visualBlock, depth: depth,
                                paragraphStyle: quoteStyle.base[.paragraphStyle]
                                    as? NSParagraphStyle
                            )
                        }
                        plainCursor += node.plainText.utf16.count
                    } else {
                        emit(
                            inline: node, into: result, style: quoteStyle,
                            block: visualBlock, depth: depth
                        )
                    }
                }
                return true
            }
            var lineCursor = 0
            // The quote's own leading blank lines (its leading text when it
            // sits nested inside a container) come out first.
            while lineCursor < rawLines.count, isBlankAtLevel(rawLines[lineCursor]) {
                beginLine()
                emitLevelLine(rawLines[lineCursor], blankRow: true)
                strutNextSeparator = true
                lineCursor += 1
            }
            for child in block.children {
                // The blank lines before a child stand for the paragraph margin
                // between the quote's paragraphs. Their bytes are emitted here
                // (the hidden marker run + the strut terminator); the layout
                // dump filters the resulting zero-width rows out.
                while lineCursor < rawLines.count, isBlankAtLevel(rawLines[lineCursor]) {
                    beginLine()
                    emitLevelLine(rawLines[lineCursor], blankRow: true)
                    strutNextSeparator = true
                    lineCursor += 1
                }
                // The child's slice covers its own source lines only: the
                // leadingText lines were the blanks consumed above.
                let sourceLineCount = child.source.split(
                    separator: "\n", omittingEmptySubsequences: false
                ).count
                let end = min(lineCursor + sourceLineCount, rawLines.count)
                guard end > lineCursor else { continue }
                // Verbatim: the child's lines carry every ancestor marker, and
                // the recursion hides one more level.
                let slice = Array(rawLines[lineCursor..<end])
                switch child.kind {
                case .blockquote:
                    appendQuote(
                        child, into: result, depth: depth, level: level + 1,
                        raw: slice, owner: visualBlock, firstLinePreceded: false
                    )
                case .heading:
                    // The reference renders the heading inside the quote at its
                    // own size; the quote's block model claims the rows (the
                    // blockquote beats the heading), so they stay on the quote's
                    // block - no sub-scope split.
                    var headingStyle = BlockStyle.heading(
                        theme: theme, level: child.attributes.level
                    )
                    if let paragraphStyle = headingStyle.base[.paragraphStyle]
                        as? NSParagraphStyle,
                        let mutable = paragraphStyle.mutableCopy()
                            as? NSMutableParagraphStyle
                    {
                        mutable.headIndent = inset
                        mutable.firstLineHeadIndent = inset
                        headingStyle.base[.paragraphStyle] = mutable
                    }
                    for line in slice {
                        beginLine()
                        let quoteMarkerLength = markerPrefixLength(line)
                        if quoteMarkerLength > 0 {
                            appendHiddenRun(
                                String(line.prefix(quoteMarkerLength)), role: .quoteMark,
                                into: result, style: collapsed, block: visualBlock, depth: depth,
                                paragraphStyle: headingStyle.base[.paragraphStyle] as? NSParagraphStyle
                            )
                        }
                        let rest = String(line.dropFirst(quoteMarkerLength))
                        let hashes = rest.prefix { $0 == "#" }
                        let spacing = rest.dropFirst(hashes.count).prefix { $0 == " " || $0 == "\t" }
                        let headingMarkerLength = hashes.count + spacing.count
                        if headingMarkerLength > 0 {
                            appendHiddenRun(
                                String(rest.prefix(headingMarkerLength)), role: .headingHash,
                                into: result, style: collapsed, block: visualBlock, depth: depth
                            )
                        }
                        plainCursor = 0
                        emit(
                            inlines: child.inlines, into: result, style: headingStyle,
                            block: visualBlock, depth: depth
                        )
                    }
                case .paragraph:
                    // The paragraph renders from its inline nodes - emphasis,
                    // code chips and links stay styled inside the quote, like in
                    // every paragraph outside one. The rows still come from the
                    // raw lines: the nodes must rebuild them byte-for-byte and
                    // each row's hidden `> ` prefix is re-emitted at the break
                    // that ends the row before it, so the buffer keeps every
                    // byte. Anything the nodes cannot reconstruct falls back to
                    // the raw walk.
                    if !emitQuoteParagraphInlines(child, slice, depth: depth) {
                        for line in slice {
                            beginLine()
                            if isBlankAtLevel(line) {
                                emitLevelLine(line, blankRow: true)
                                strutNextSeparator = true
                            } else {
                                emitLevelLine(line, blankRow: false)
                            }
                        }
                    }
                case .list:
                    // The list claims its own rows in the reference's model (the
                    // li beats the blockquote); its items indent from the quote's
                    // inset, not from zero. A pending blank-row strut rides on
                    // the list's first separator newline.
                    appendList(
                        child, into: result, depth: depth, raw: slice,
                        owner: visualBlock, firstLinePreceded: false,
                        indentOffset: inset,
                        leadingStrut: strutNextSeparator ? blankLineStyle : nil
                    )
                    strutNextSeparator = false
                default:
                    // Fences and tables are painted children; they go through
                    // the child emitter with the quote's indent as their column.
                    emitChildContent(
                        child, slice, into: result, depth: depth,
                        owner: visualBlock, textColumn: inset,
                        continuationStyle: quoteStyle,
                        firstLinePreceded: false
                    )
                }
                lineCursor = end
            }
            // Lines no child claimed are still bytes in the file.
            while lineCursor < rawLines.count {
                beginLine()
                if isBlankAtLevel(rawLines[lineCursor]) {
                    emitLevelLine(rawLines[lineCursor], blankRow: true)
                    strutNextSeparator = true
                } else {
                    emitLevelLine(rawLines[lineCursor], blankRow: false)
                }
                lineCursor += 1
            }
        }

        private func appendListItem(
            _ block: BlockNode, into result: NSMutableAttributedString, depth: Int,
            parentIsOrdered: Bool? = nil,
            raw: [String]? = nil, owner: BlockNode? = nil, firstLinePreceded: Bool = false,
            indentOffset: CGFloat = 0, leadingStrut: NSMutableParagraphStyle? = nil
        ) {
            let sourceLines = block.source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let rawLines = raw ?? sourceLines
            // The item's lines keep `md.block` pointing at the enclosing item the
            // editor already tracks - focus, reparse and painted-block reveal see one
            // block, exactly as before. Nested children only add `md.subBlock`.
            let visualBlock = owner ?? block
            let selfSubBlock: Int? = visualBlock.id == block.id ? nil : block.id
            let savedBlockOverride = renderedBlockOverride
            let savedSubBlock = renderedSubBlock
            let savedSubKind = renderedSubKind
            renderedBlockOverride = visualBlock
            renderedSubBlock = selfSubBlock
            renderedSubKind = selfSubBlock == nil ? nil : block.kind.rawValue
            defer {
                renderedBlockOverride = savedBlockOverride
                renderedSubBlock = savedSubBlock
                renderedSubKind = savedSubKind
            }

            guard let first = block.children.first, !sourceLines.isEmpty else {
                // An item with no children - `- ` alone - has no structure to render.
                if !firstLinePreceded { result.append(NSAttributedString(string: "\n")) }
                emitPlain(
                    rawLines.joined(separator: "\n"), into: result,
                    style: BlockStyle.paragraph(theme: theme), block: visualBlock, depth: depth
                )
                return
            }
            let ordered = parentIsOrdered ?? block.attributes.isOrdered
            let marker: String
            if let checked = block.attributes.checked {
                // Drawn text only - the buffer keeps the source's `- [x] ` bytes, and
                // the decoration right-aligns the glyph against the text column, so
                // no trailing space here: it would widen the marker-to-text gap.
                marker = checked ? "x" : ""
            } else if ordered {
                marker = "\(block.attributes.listStart > 0 ? block.attributes.listStart : 1)."
            } else {
                // The theme's ladder, not the source's `-`/`*`: Typora's `#write`
                // base leaves `list-style-type` to the browser, which renders
                // disc, circle, square down the nesting levels.
                marker = String(theme.listBullet(depth: depth + 1))
            }
            var style: BlockStyle
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
            // The item's text column: where the first line's content starts, and
            // where continuation content below aligns. `indentOffset` carries the
            // container's own inset (a quote's 19pt per level), which the
            // depth-based list indent knows nothing about.
            let textColumn = indentOffset + theme.listIndent * CGFloat(max(depth + 1, 1))
            if indentOffset > 0,
                let paragraphStyle = style.base[.paragraphStyle]
                    as? NSParagraphStyle,
                let mutable = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle
            {
                mutable.headIndent += indentOffset
                mutable.firstLineHeadIndent += indentOffset
                style.base[.paragraphStyle] = mutable
            }
            // The item's paragraph style without the marker decoration, for lines
            // that render inside the item but carry no marker of their own.
            let continuationStyle = BlockStyle(
                font: style.font,
                textColor: style.textColor,
                base: [
                    .paragraphStyle: style.base[.paragraphStyle]
                        ?? NSParagraphStyle.markdownBody(
                            lineHeight: theme.bodyLineHeight * theme.bodyFontSize
                        )
                ],
                decoration: []
            )

            // The list marker is the block's own source prefix; hide it and let the
            // decoration layer draw the bullet or number.
            //
            // For an ordered item the parser records only the digits as the bullet and
            // leaves the `. ` in the content, so the hidden run is taken from the
            // source rather than from `marker` - otherwise the `. ` was counted twice
            // and the buffer no longer matched. The number itself is drawn by the
            // decoration layer, right-aligned against the text column, so wide
            // numbers (`10.`) grow leftwards into the indent instead of shoving the
            // item's text off the shared column.
            //
            // An item parsed at the list level keeps its own indentation in `source`
            // (`  - [x] done`); the marker length is measured on that line, and the
            // container's own prefix is whatever the raw line adds ahead of it.
            let sourceFirstLine = sourceLines[0]
            let rawFirstLine = rawLines[0]
            // The raw line must end with the source line; the parser only ever strips
            // a prefix, but the buffer may never lose bytes, so an unexpected shape
            // falls back to verbatim text.
            let paired = rawFirstLine.hasSuffix(sourceFirstLine)
            if !paired {
                if !firstLinePreceded { result.append(NSAttributedString(string: "\n")) }
                emitPlain(
                    rawLines.joined(separator: "\n"), into: result,
                    style: style, block: visualBlock, depth: depth + 1
                )
                return
            }
            let containerPrefix = String(
                rawFirstLine.dropLast(sourceFirstLine.utf16.count)
            )
            let sourceMarkerLength = markerPrefixLength(of: sourceFirstLine, ordered: ordered)
            let markerText = String(sourceFirstLine.prefix(sourceMarkerLength))
            if !firstLinePreceded { result.append(NSAttributedString(string: "\n")) }
            // The container indentation is hidden so the paragraph style alone places
            // the text; the marker run then carries the line, and TextKit reads the
            // line's paragraph geometry from it (the marker's own style, not the
            // generic `blockMarkerStyle`, which only knows depth one).
            if !containerPrefix.isEmpty {
                emitHidden(
                    containerPrefix, into: result, style: style, block: visualBlock, depth: depth + 1
                )
            }
            let markerStyle = BlockStyle.collapsed(from: style, theme: theme)
            // The marker occurrence is recorded under the item itself, so the
            // decoration layer can find the one line that carries it: the item's
            // marker draws exactly there, never on nested or wrapped lines. The run
            // attributes still come from the visual block through the override.
            if ordered && block.attributes.checked == nil {
                // The source digits hide (zero-width) and the decoration layer
                // draws the synthesised number; see `.listMarker`.
                appendHiddenRun(
                    markerText, role: .orderedNumber, into: result,
                    style: markerStyle, block: block, depth: depth,
                    paragraphStyle: style.base[.paragraphStyle] as? NSParagraphStyle
                )
            } else {
                appendHiddenRun(
                    markerText, role: .bullet, into: result,
                    style: markerStyle, block: block, depth: depth,
                    paragraphStyle: style.base[.paragraphStyle] as? NSParagraphStyle
                )
            }
            // The rest of the first line is the item's inline content.
            let line0Rest = String(sourceFirstLine.dropFirst(sourceMarkerLength))
            // The child node's inlines render the first line when they are *exactly*
            // the item's first line. Ordered and task markers run past the bullet
            // (`. `, `[x] `) and the parser leaves those in the child's text, so
            // `trimmedFirstInlines` strips them before the comparison - that is what
            // lets ordered and task items keep their inline styling.
            let trimmed = trimmedFirstInlines(first.inlines, block: block)
            var line0Handled = false
            if first.kind == .paragraph, !line0Rest.isEmpty,
                let trimmed, trimmed.verbatim == line0Rest
            {
                // Inline nodes stay attributed to the item, as everywhere else in
                // the item's own line range; the paragraph style comes from the
                // item, whose indentation the marker run already carries.
                plainCursor = 0
                emit(
                    inlines: trimmed, into: result, style: style,
                    block: visualBlock, depth: depth + 1
                )
                line0Handled = true
            } else if first.kind == .paragraph {
                emitPlain(
                    line0Rest, into: result, style: style, block: visualBlock, depth: depth + 1
                )
                line0Handled = true
            }

            // Everything after the first line is the item's remaining children. Each
            // child's lines are a contiguous run of the item's own lines - the parser
            // hands every blank line between children to the next child's leading
            // text - so the walk slices the raw lines by the children's line counts.
            // The first child usually also owns line 0; when the paragraph path above
            // already emitted it, the walk starts one line in.
            var lineCursor = 1
            for (index, child) in block.children.enumerated() {
                let childLines = (child.leadingText + child.source)
                    .split(separator: "\n", omittingEmptySubsequences: false).count
                let ownsLine0 = index == 0 && !line0Handled
                // When the marker path above already emitted line 0, the first
                // child's own line 0 went out with it: only its remaining lines are
                // left to emit.
                let alreadyEmitted = index == 0 && line0Handled
                let start = ownsLine0 ? 0 : lineCursor
                let end = min(start + childLines - (alreadyEmitted ? 1 : 0), rawLines.count)
                guard end > start else { continue }
                var slice = Array(rawLines[start..<end])
                if ownsLine0 {
                    // The marker half of line 0 is already in the buffer.
                    slice[0] = line0Rest
                }
                emitChildContent(
                    child, slice, into: result, depth: depth + 1,
                    owner: visualBlock, textColumn: textColumn,
                    continuationStyle: continuationStyle,
                    firstLinePreceded: ownsLine0
                )
                lineCursor = end
            }
            // Lines no child claimed are still bytes in the file.
            var collapseNextSeparator = false
            while lineCursor < rawLines.count {
                if collapseNextSeparator {
                    appendCollapsedNewline(into: result)
                    collapseNextSeparator = false
                } else {
                    result.append(NSAttributedString(string: "\n"))
                }
                if isBlankLine(rawLines[lineCursor]) {
                    collapseNextSeparator = true
                    lineCursor += 1
                    continue
                }
                let (indent, rest) = splitIndent(rawLines[lineCursor])
                emitHidden(
                    indent, into: result, style: continuationStyle,
                    block: visualBlock, depth: depth + 1
                )
                emitPlain(
                    rest, into: result, style: continuationStyle,
                    block: visualBlock, depth: depth + 1
                )
                lineCursor += 1
            }
        }

        /// Emits one nested child of a list item from its raw lines.
        ///
        /// `raw` holds one line per line of the child's own source, with the
        /// container indentation the parser stripped put back. The child's runs carry
        /// the owning item's `md.block` plus the child's `md.subBlock`, so the
        /// decoration layer scopes its chrome (bullets, quote bars, code background)
        /// to exactly these lines.
        private func emitChildContent(
            _ child: BlockNode, _ raw: [String], into result: NSMutableAttributedString,
            depth: Int, owner: BlockNode, textColumn: CGFloat,
            continuationStyle: BlockStyle, firstLinePreceded: Bool
        ) {
            let savedBlockOverride = renderedBlockOverride
            let savedSubBlock = renderedSubBlock
            let savedSubKind = renderedSubKind
            renderedBlockOverride = owner
            renderedSubBlock = child.id
            renderedSubKind = child.kind.rawValue
            defer {
                renderedBlockOverride = savedBlockOverride
                renderedSubBlock = savedSubBlock
                renderedSubKind = savedSubKind
            }

            // Containers emit their whole slice themselves.
            switch child.kind {
            case .list:
                appendList(
                    child, into: result, depth: depth, raw: raw, owner: owner,
                    firstLinePreceded: firstLinePreceded
                )
                return
            case .listItem, .taskItem:
                appendListItem(
                    child, into: result, depth: depth, raw: raw, owner: owner,
                    firstLinePreceded: firstLinePreceded
                )
                return
            default:
                break
            }

            switch child.kind {
            case .paragraph:
                emitParagraphLines(
                    child, raw, into: result, depth: depth, style: continuationStyle,
                    firstLinePreceded: firstLinePreceded
                )
            case .blockquote:
                let quoteStyle = BlockStyle(
                    font: continuationStyle.font,
                    // `blockquote { color: #777777 }`, as at the top level.
                    textColor: theme.quoteText.nsColor,
                    base: [
                        .paragraphStyle: NSParagraphStyle.markdownQuote(
                            indent: textColumn + theme.quoteIndent + theme.quoteBarWidth,
                            lineHeight: theme.bodyLineHeight * theme.bodyFontSize
                        )
                    ],
                    decoration: []
                )
                var plans = [
                    DecorationPlan.quoteBar(
                        color: theme.quoteBar.nsColor,
                        width: theme.quoteBarWidth,
                        inset: textColumn
                    )
                ]
                if let alert = child.attributes.alert {
                    plans.append(
                        .alertBox(
                            title: alert.rawValue.capitalized,
                            background: theme.alertBackground.nsColor,
                            border: theme.alertBorder.nsColor
                        )
                    )
                }
                register(plans, for: child.id)
                emitQuoteLines(
                    raw, into: result, depth: depth, block: child,
                    style: quoteStyle, firstLinePreceded: firstLinePreceded
                )
            case .fences:
                let base = BlockStyle.codeFence(theme: theme)
                let codeStyle = BlockStyle(
                    font: base.font,
                    textColor: base.textColor,
                    base: [
                        .paragraphStyle: NSParagraphStyle.withHeadIndents(
                            base.base[.paragraphStyle] as? NSParagraphStyle,
                            indent: textColumn + (theme.codePaddingLeft ?? theme.codePadding),
                            spacingBefore: theme.codePaddingTop
                        )
                    ],
                    decoration: []
                )
                register(
                    [
                        .codeBlock(
                            background: theme.codeBlockBackground.nsColor,
                            radius: EditorMetrics.radiusSmall,
                            border: theme.codeBorder?.nsColor,
                            topInset: theme.codePaddingTop,
                            bottomInset: theme.codePaddingBottom
                        )
                    ],
                    for: child.id
                )
                emitFenceLines(
                    child, raw, into: result, depth: depth, block: owner,
                    style: codeStyle, firstLinePreceded: firstLinePreceded
                )
            case .heading where child.attributes.isSetext:
                emitPlainLines(
                    raw, into: result, depth: depth, style: continuationStyle,
                    block: owner, firstLinePreceded: firstLinePreceded
                )
            case .heading:
                let heading = BlockStyle.heading(theme: theme, level: child.attributes.level)
                let headingStyle = BlockStyle(
                    font: heading.font,
                    textColor: heading.textColor,
                    base: [
                        .paragraphStyle: NSParagraphStyle.withHeadIndents(
                            heading.base[.paragraphStyle] as? NSParagraphStyle,
                            indent: textColumn
                        )
                    ],
                    decoration: heading.decoration
                )
                register(heading.decoration, for: child.id)
                emitHeadingLines(
                    child, raw, into: result, depth: depth, style: headingStyle,
                    firstLinePreceded: firstLinePreceded
                )
            case .indentedCode:
                let base = BlockStyle.codeFence(theme: theme)
                let codeStyle = BlockStyle(
                    font: base.font,
                    textColor: base.textColor,
                    base: [
                        .paragraphStyle: NSParagraphStyle.withHeadIndents(
                            base.base[.paragraphStyle] as? NSParagraphStyle,
                            indent: textColumn + (theme.codePaddingLeft ?? theme.codePadding)
                        )
                    ],
                    decoration: []
                )
                emitPlainLines(
                    raw, into: result, depth: depth, style: codeStyle, block: owner,
                    firstLinePreceded: firstLinePreceded
                )
            case .hr:
                register(
                    [.horizontalRule(color: theme.rule.nsColor, height: 2)], for: child.id
                )
                emitHiddenLines(
                    raw, into: result, depth: depth, block: owner,
                    style: BlockStyle.horizontalRule(theme: theme),
                    firstLinePreceded: firstLinePreceded
                )
            case .htmlBlock:
                register(
                    [
                        .codeBlock(
                            background: theme.rawBlockEditingBackground.nsColor,
                            radius: EditorMetrics.radiusSmall,
                            border: nil, topInset: 0, bottomInset: 0
                        )
                    ],
                    for: child.id
                )
                emitPlainLines(
                    raw, into: result, depth: depth, style: BlockStyle.htmlBlock(theme: theme),
                    block: owner, firstLinePreceded: firstLinePreceded
                )
            case .mathBlock:
                emitMathLines(
                    child, raw, into: result, depth: depth,
                    style: BlockStyle.mathBlock(theme: theme),
                    firstLinePreceded: firstLinePreceded
                )
            default:
                // Tables, definitions and the like inside a list item are rare; they
                // read as their own source lines, byte-exact but unpainted.
                emitPlainLines(
                    raw, into: result, depth: depth, style: continuationStyle, block: owner,
                    firstLinePreceded: firstLinePreceded
                )
            }
        }

        // MARK: Raw-line emission, shared by the list item's children

        /// One raw line: hidden container indentation, then the line's own content.
        private func emitRawLine(
            _ rawLine: String, into result: NSMutableAttributedString, depth: Int,
            style: BlockStyle, block: BlockNode,
            content: (String) -> Void
        ) {
            let (indent, rest) = splitIndent(rawLine)
            if !indent.isEmpty {
                emitHidden(indent, into: result, style: style, block: block, depth: depth)
            }
            content(rest)
        }

        /// Body lines: hidden indent, then the line as plain text. A single-line
        /// child renders from its inline nodes instead, which keeps inline styling
        /// and links find/replace's plain-text mapping for the paragraph.
        private func emitParagraphLines(
            _ child: BlockNode, _ raw: [String], into result: NSMutableAttributedString,
            depth: Int, style: BlockStyle, firstLinePreceded: Bool
        ) {
            if raw.count == 1, !isBlankLine(raw[0]),
                child.inlines.verbatim == splitIndent(raw[0]).rest
            {
                for (index, rawLine) in raw.enumerated() {
                    if index > 0 || !firstLinePreceded {
                        result.append(NSAttributedString(string: "\n"))
                    }
                    emitRawLine(rawLine, into: result, depth: depth, style: style, block: child) { _ in
                        plainCursor = 0
                        emit(
                            inlines: child.inlines, into: result, style: style,
                            block: child, depth: depth
                        )
                    }
                }
                return
            }
            emitPlainLines(
                raw, into: result, depth: depth, style: style, block: child,
                firstLinePreceded: firstLinePreceded
            )
        }

        /// Body lines: hidden indent, then the line as plain text.
        private func emitPlainLines(
            _ raw: [String], into result: NSMutableAttributedString, depth: Int,
            style: BlockStyle, block: BlockNode, firstLinePreceded: Bool
        ) {
            var collapseNextSeparator = false
            for (index, rawLine) in raw.enumerated() {
                if index > 0 || !firstLinePreceded {
                    if collapseNextSeparator {
                        appendCollapsedNewline(into: result)
                        collapseNextSeparator = false
                    } else {
                        result.append(NSAttributedString(string: "\n"))
                    }
                }
                if isBlankLine(rawLine) {
                    collapseNextSeparator = true
                    continue
                }
                emitRawLine(rawLine, into: result, depth: depth, style: style, block: block) { rest in
                    emitPlain(rest, into: result, style: style, block: block, depth: depth)
                }
            }
        }

        /// Quote lines: hidden indent and `> ` markers, then the quoted text.
        private func emitQuoteLines(
            _ raw: [String], into result: NSMutableAttributedString, depth: Int,
            block: BlockNode, style: BlockStyle, firstLinePreceded: Bool
        ) {
            var collapseNextSeparator = false
            for (index, rawLine) in raw.enumerated() {
                if index > 0 || !firstLinePreceded {
                    if collapseNextSeparator {
                        // The blank quote line stands for the paragraph margin
                        // between the quote's paragraphs - nothing else provides
                        // it (quote rows carry no item spacing).
                        appendCollapsedNewline(
                            into: result, spacingBefore: theme.blankLineMargin
                        )
                        collapseNextSeparator = false
                    } else {
                        result.append(NSAttributedString(string: "\n"))
                    }
                }
                if isBlankLine(rawLine) {
                    collapseNextSeparator = true
                    continue
                }
                emitRawLine(rawLine, into: result, depth: depth, style: style, block: block) { rest in
                    var markerLength = 0
                    for character in rest {
                        if character == ">" { markerLength += 1 } else { break }
                    }
                    if markerLength > 0, markerLength < rest.count,
                        rest[rest.index(rest.startIndex, offsetBy: markerLength)] == " "
                    {
                        markerLength += 1
                    }
                    let content = String(rest.dropFirst(markerLength))
                    if markerLength > 0, content.trimmingCharacters(in: .whitespaces).isEmpty {
                        // A bare `>` line: the quote continues over a blank row.
                        // The reference renders no row (the paragraphs' margins
                        // collapse), so the row collapses onto its hidden mark-
                        // ers and carries the paragraph margin nothing else
                        // provides (quote rows have no item spacing).
                        let collapsedStyle = NSMutableParagraphStyle()
                        collapsedStyle.paragraphSpacingBefore = theme.blankLineMargin
                        collapsedStyle.minimumLineHeight = 0.01
                        collapsedStyle.maximumLineHeight = 0.01
                        if markerLength > 0 {
                            appendHiddenRun(
                                String(rest.prefix(markerLength)), role: .quoteMark, into: result,
                                style: BlockStyle.collapsed(from: style, theme: theme),
                                block: block, depth: depth,
                                paragraphStyle: collapsedStyle
                            )
                        }
                        return
                    }
                    if markerLength > 0 {
                        appendHiddenRun(
                            String(rest.prefix(markerLength)), role: .quoteMark, into: result,
                            style: BlockStyle.collapsed(from: style, theme: theme),
                            block: block, depth: depth,
                            paragraphStyle: style.base[.paragraphStyle]
                                as? NSParagraphStyle
                        )
                    }
                    emitPlain(
                        content, into: result,
                        style: style, block: block, depth: depth
                    )
                }
            }
        }

        /// Fence lines: delimiters and body hidden/plain like the top-level emitter,
        /// with the container indentation hidden ahead of each line.
        private func emitFenceLines(
            _ child: BlockNode, _ raw: [String], into result: NSMutableAttributedString,
            depth: Int, block: BlockNode, style: BlockStyle, firstLinePreceded: Bool
        ) {
            let collapsed = BlockStyle.collapsed(from: style, theme: theme)
            let lines = child.source.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            func isFenceLine(_ line: String) -> Bool {
                let (_, rest) = splitIndent(line)
                return Fence.opening(in: rest, baseIndent: 0) != nil
                    || Fence.closing(rest, for: child.opening) != nil
            }
            // The body the highlighter runs over is the child's own (stripped) text
            // minus the fence rows, exactly like the top-level emitter's.
            let bodyText = zip(lines, raw)
                .filter { !isFenceLine($0.1) }
                .map { $0.0 }
                .joined(separator: "\n")
            let highlights = CodeHighlighter.shared.highlights(
                in: bodyText, language: child.attributes.language
            )
            var highlightCursor = 0
            var bodyOffset = 0
            // Blank lines BEFORE the opening delimiter are the container's own
            // (the item's blank line ahead of an in-item fence) — their row
            // collapses; blanks inside the body are code content and stay real
            // rows.
            var opened = false
            var collapseNextSeparator = false
            for (index, rawLine) in raw.enumerated() {
                if index > 0 || !firstLinePreceded {
                    if collapseNextSeparator {
                        appendCollapsedNewline(into: result)
                        collapseNextSeparator = false
                    } else {
                        result.append(NSAttributedString(string: "\n"))
                    }
                }
                let (indent, rest) = splitIndent(rawLine)
                if !opened {
                    if isFenceLine(rawLine) {
                        opened = true
                    } else if isBlankLine(rawLine) {
                        collapseNextSeparator = true
                        continue
                    }
                }
                if !indent.isEmpty {
                    emitHidden(
                        indent, into: result, style: style, block: block, depth: depth
                    )
                }
                if isFenceLine(rawLine) {
                    appendHiddenRun(
                        rest, role: .fenceDelimiter, into: result,
                        style: collapsed, block: block, depth: depth
                    )
                    continue
                }
                let start = result.length
                emitPlain(
                    rest, into: result, style: style, block: block, depth: depth
                )
                let lineRange = NSRange(location: start, length: result.length - start)
                result.addAttribute(
                    .foregroundColor, value: theme.syntax.plain.nsColor, range: lineRange
                )
                result.addAttribute(MarkdownAttribute.codeBody, value: true, range: lineRange)
                applyHighlights(
                    highlights, from: &highlightCursor,
                    line: NSRange(location: bodyOffset, length: rest.utf16.count),
                    shift: start - bodyOffset, into: result
                )
                bodyOffset += rest.utf16.count + 1
            }
        }

        /// ATX headings inside items: hidden indent and hashes, inline content.
        private func emitHeadingLines(
            _ child: BlockNode, _ raw: [String], into result: NSMutableAttributedString,
            depth: Int, style: BlockStyle, firstLinePreceded: Bool
        ) {
            for (index, rawLine) in raw.enumerated() {
                if index > 0 || !firstLinePreceded {
                    result.append(NSAttributedString(string: "\n"))
                }
                emitRawLine(rawLine, into: result, depth: depth, style: style, block: child) { rest in
                    let hashes = rest.prefix { $0 == "#" }
                    let afterHashes = rest.dropFirst(hashes.count)
                    let spacing = afterHashes.prefix { $0 == " " || $0 == "\t" }
                    let markerLength = hashes.count + spacing.count
                    if markerLength > 0 {
                        appendHiddenRun(
                            String(rest.prefix(markerLength)), role: .headingHash, into: result,
                            style: BlockStyle.collapsed(from: style, theme: theme),
                            block: child, depth: depth
                        )
                    }
                    let text = String(rest.dropFirst(markerLength))
                    if child.inlines.verbatim == text {
                        emit(
                            inlines: child.inlines, into: result, style: style,
                            block: child, depth: depth
                        )
                    } else {
                        emitPlain(text, into: result, style: style, block: child, depth: depth)
                    }
                }
            }
        }

        /// Math blocks inside items: delimiters hidden, body plain.
        private func emitMathLines(
            _ child: BlockNode, _ raw: [String], into result: NSMutableAttributedString,
            depth: Int, style: BlockStyle, firstLinePreceded: Bool
        ) {
            let collapsed = BlockStyle.collapsed(from: style, theme: theme)
            for (index, rawLine) in raw.enumerated() {
                if index > 0 || !firstLinePreceded {
                    result.append(NSAttributedString(string: "\n"))
                }
                if isBlankLine(rawLine) {
                    result.append(NSAttributedString(string: rawLine))
                    continue
                }
                let trimmed = rawLine.trimmingInlineWhitespace()
                let isDelimiter =
                    (index == 0 && trimmed.hasPrefix(child.attributes.mathOpen))
                    || (index == raw.count - 1 && trimmed.hasPrefix(child.attributes.mathClose))
                emitRawLine(rawLine, into: result, depth: depth, style: style, block: child) { rest in
                    if isDelimiter {
                        appendHiddenRun(
                            rest, role: .mathDelimiter, into: result,
                            style: collapsed, block: child, depth: depth
                        )
                    } else {
                        emitPlain(rest, into: result, style: style, block: child, depth: depth)
                    }
                }
            }
        }

        /// Fully hidden lines (a horizontal rule inside an item).
        private func emitHiddenLines(
            _ raw: [String], into result: NSMutableAttributedString, depth: Int,
            block: BlockNode, style: BlockStyle, firstLinePreceded: Bool
        ) {
            for (index, rawLine) in raw.enumerated() {
                if index > 0 || !firstLinePreceded {
                    result.append(NSAttributedString(string: "\n"))
                }
                emitHidden(
                    rawLine, into: result, style: style, block: block, depth: depth
                )
            }
        }

        private func appendFences(_ block: BlockNode, into result: NSMutableAttributedString, depth: Int) {
            let source = block.source
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            let body = BlockStyle.codeFence(theme: theme)
            let collapsed = BlockStyle.collapsed(from: body, theme: theme)
            register(body.decoration, for: block.id)

            func isFenceLine(_ line: Substring) -> Bool {
                let text = String(line)
                return Fence.opening(in: text, baseIndent: 0) != nil
                    || Fence.closing(text, for: block.opening) != nil
            }

            // The body is parsed once, so a construct that spans lines colours
            // across all of them; the ranges come back relative to `bodyText`
            // and are clipped to each line as it is emitted.
            let bodyText = lines.filter { !isFenceLine($0) }.joined(separator: "\n")
            let highlights = CodeHighlighter.shared.highlights(
                in: bodyText, language: block.attributes.language
            )
            var highlightCursor = 0
            var bodyOffset = 0
            for (index, line) in lines.enumerated() {
                if index > 0 { result.append(NSMutableAttributedString(string: "\n")) }
                if isFenceLine(line) {
                    appendHiddenRun(
                        String(line), role: .fenceDelimiter, into: result,
                        style: collapsed, block: block, depth: depth
                    )
                } else {
                    let start = result.length
                    emitPlain(String(line), into: result, style: body, block: block, depth: depth)
                    let lineRange = NSRange(location: start, length: result.length - start)
                    // The plain colour goes down first; token colours override it.
                    result.addAttribute(
                        .foregroundColor, value: theme.syntax.plain.nsColor, range: lineRange
                    )
                    // Body-line marker: the decorator unions these lines for the
                    // block's background and border, leaving the invisible fence
                    // rows out.
                    result.addAttribute(MarkdownAttribute.codeBody, value: true, range: lineRange)
                    applyHighlights(
                        highlights, from: &highlightCursor,
                        line: NSRange(location: bodyOffset, length: line.utf16.count),
                        shift: start - bodyOffset, into: result
                    )
                    bodyOffset += line.utf16.count + 1
                }
            }
        }

        /// Applies every highlight range that overlaps `line`.
        ///
        /// `ranges` are body-relative and sorted by location; `cursor` only
        /// moves forward because lines are emitted in order. A range that spills
        /// into the next line stays at the cursor for it.
        private func applyHighlights(
            _ ranges: [NamedRange], from cursor: inout Int, line: NSRange,
            shift: Int, into result: NSMutableAttributedString
        ) {
            var index = cursor
            while index < ranges.count, ranges[index].range.location < NSMaxRange(line) {
                let range = ranges[index].range
                if NSMaxRange(range) > line.location {
                    let clipped = NSIntersectionRange(range, line)
                    if clipped.length > 0,
                        let color = CodeHighlighter.shared.color(
                            for: ranges[index].name, palette: theme.syntax
                        )
                    {
                        result.addAttribute(
                            .foregroundColor, value: color.nsColor,
                            range: NSRange(
                                location: clipped.location + shift, length: clipped.length
                            )
                        )
                    }
                }
                index += 1
            }
            while cursor < index, NSMaxRange(ranges[cursor].range) <= NSMaxRange(line) {
                cursor += 1
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

        /// A live table of contents: the `[TOC]` source stays in the buffer but
        /// takes no space, and the decoration layer paints one row per heading.
        ///
        /// The painted route mirrors pipe tables - `md.painted` included, so
        /// focusing the block brings the source back for editing. The single
        /// source line reserves the whole list's height through its paragraph
        /// style: TextKit sizes the line box from it, and the rows are drawn
        /// into that box top to bottom.
        private func appendTOC(_ block: BlockNode, into result: NSMutableAttributedString, depth: Int) {
            guard !headings.isEmpty else {
                register([.tocPlaceholder(color: theme.quoteText.nsColor)], for: block.id)
                emitHidden(
                    block.source, into: result, style: BlockStyle.definition(theme: theme),
                    block: block, depth: depth
                )
                return
            }
            register([.tocEntries(headings)], for: block.id)
            let rowHeight = theme.bodyLineHeight * theme.bodyFontSize
            let paragraph = NSParagraphStyle.markdownBody(
                lineHeight: rowHeight * CGFloat(headings.count),
                spacing: theme.blockMargin
            )
            var style = BlockStyle.definition(theme: theme)
            style.base[.paragraphStyle] = paragraph
            appendPainted(block.source, into: result, style: style, block: block, depth: depth)
        }

        /// A front matter block as a metadata table: every source line is
        /// emitted painted and hidden, fences collapsed, so the decoration
        /// layer can draw key/value rows over them. Focusing the block flips
        /// the attributes back through the same machinery pipe tables use.
        private func appendFrontMatter(
            _ block: BlockNode, into result: NSMutableAttributedString, depth: Int
        ) {
            var rows = block.source.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if rows.last?.isEmpty == true { rows.removeLast() }
            let front = FrontMatterLayout.parse(
                source: block.source,
                rowHeight: theme.bodyLineHeight * theme.bodyFontSize
            )
            register([.frontMatterTable(front)], for: block.id)
            // The separator newline gets the row it *precedes*, as with tables:
            // TextKit sizes a line from the paragraph style at the line's first
            // character, and that character is the previous line's terminator.
            for (index, row) in rows.enumerated() {
                let paragraph = front.paragraphStyle(
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
                var rowStyle = BlockStyle.frontMatter(theme: theme)
                rowStyle.base[.paragraphStyle] = paragraph
                appendPainted(row, into: result, style: rowStyle, block: block, depth: depth)
            }
            if block.source.hasSuffix("\n") {
                appendPainted(
                    "", into: result,
                    style: BlockStyle.frontMatter(theme: theme), block: block, depth: depth
                )
            }
        }

        /// Emits text that carries no glyphs because a decoration draws it instead.        ///
        /// `md.painted` is what lets focus bring the source back: `MarkerVisibility`
        /// reads it and unhides the block the caret is in.
        private func appendPainted(
            _ text: String, into result: NSMutableAttributedString,
            style: BlockStyle, block: BlockNode, depth: Int
        ) {
            guard !text.isEmpty else { return }
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
        private func markerParagraphStyle(
            for block: BlockNode, spacingBefore: CGFloat
        ) -> NSParagraphStyle? {
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
            guard let paragraphStyle = style.base[.paragraphStyle] as? NSParagraphStyle,
                let mutable = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle
            else { return nil }
            mutable.paragraphSpacingBefore = spacingBefore
            return mutable
        }

        /// The paragraph style hidden markers must inherit, set for the duration of a
        /// block's emission.
        private var blockMarkerStyle: NSParagraphStyle?
        /// While a list item's nested children are being emitted, their runs still
        /// carry the ITEM's `md.block` - focus, reparse and painted-block reveal see
        /// one block, exactly as before - and the child's `md.subBlock` scopes the
        /// decoration layer's chrome. `blockAttributes` folds both in; set for the
        /// duration of a child's (or nested item's) emission.
        private var renderedBlockOverride: BlockNode?
        private var renderedSubBlock: Int?
        /// The kind of the `renderedSubBlock` node, dumped as the row's kind.
        private var renderedSubKind: String?
        /// Whether the next emitted line is the *first* line of a block.
        ///
        /// TextKit makes every newline in the buffer a paragraph, so a soft line break
        /// inside a paragraph is indistinguishable from a new block. Carrying the block
        /// margin on every line therefore opened up wrapped lines as well; only the
        /// first line of a block may carry it.
        private var isFirstLineOfBlock = true
        /// Plain-text offset within the block being emitted, in UTF-16 units.
        ///
        /// Find hits arrive as offsets into a block's *plain* text; this cursor is
        /// what lets the layout record where each plain span sits in the buffer, so
        /// the find bar can translate without measuring syntax widths.
        private var plainCursor = 0

        /// Links a plain-text span to its buffer location for find-hit mapping.
        private func recordPlain(
            _ node: InlineNode, contentStart: Int, contentEnd: Int,
            plainStart: Int, block: BlockNode
        ) {
            let plainLength = node.plainText.utf16.count
            plainCursor = plainStart + plainLength
            guard plainLength > 0, contentEnd > contentStart else { return }
            inlineNodes.append(
                InlineRange(
                    index: inlineNodes.count, kind: node.kind,
                    range: NSRange(
                        location: contentStart, length: max(contentEnd - contentStart, 1)
                    ),
                    blockID: block.id,
                    plainRange: NSRange(location: plainStart, length: plainLength),
                    contentRange: NSRange(location: contentStart, length: contentEnd - contentStart)
                )
            )
        }

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
                let start = result.length
                append(
                    node.verbatim, runAttributes(style, block: block, depth: depth), to: result
                )
                // Only real text maps to plain offsets; a break's own bytes are a
                // hole in the plain text, but the cursor still moves past them.
                if node.kind == .text {
                    recordPlain(
                        node, contentStart: start, contentEnd: result.length,
                        plainStart: plainCursor, block: block
                    )
                } else {
                    plainCursor += node.plainText.utf16.count
                }
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
                // Typora hides the backticks and chips the code text, so the
                // delimiters go out as hidden marker runs and the payload carries
                // the code style - the same treatment as every other delimited
                // inline. Emitting `node.verbatim` instead left the backticks
                // visible and the chrome (padding, border) without a clean run to
                // attach to.
                appendDelimited(
                    node, into: result, style: style, block: block, depth: depth,
                    open: .codeOpen, close: .codeClose,
                    override: InlineStyle.code(theme: theme, base: style)
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
                let plainStart = plainCursor
                // The alt text is the placeholder the picture is drawn over, so it is
                // zero width too. It is not a marker, though: revealing it would put the
                // `![…]` syntax back without the path, so the hidden flag is set here
                // rather than through `appendHiddenRun`.
                let imageAttributes = runAttributes(
                    InlineStyle.image(theme: theme, base: style).applied(to: style),
                    block: block, depth: depth
                )
                append(alt, imageAttributes, to: result)
                plainCursor = plainStart + alt.utf16.count
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
                        blockID: block.id,
                        plainRange: NSRange(location: plainStart, length: alt.utf16.count),
                        contentRange: NSRange(location: start, length: alt.utf16.count)
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
                let start = result.length
                append(
                    node.verbatim,
                    runAttributes(
                        style, block: block, depth: depth, color: theme.marker.nsColor
                    ),
                    to: result
                )
                // The escape's backslash is syntax; an entity's decoded form has a
                // different length than its verbatim. Both map through their own
                // plain length, so a hit inside or after them stays aligned.
                let contentStart = node.kind == .escape ? start + node.prefix.utf16.count : start
                recordPlain(
                    node, contentStart: contentStart, contentEnd: result.length,
                    plainStart: plainCursor, block: block
                )
            case .emoji:
                let glyph = EmojiCatalog.glyph(for: node.payload)
                if glyph.isEmpty {
                    // Outside the curated table: the shortcode stays verbatim,
                    // as before.
                    let start = result.length
                    append(
                        node.verbatim, runAttributes(style, block: block, depth: depth),
                        to: result
                    )
                    recordPlain(
                        node,
                        contentStart: start + node.prefix.utf16.count,
                        contentEnd: result.length - node.suffix.utf16.count,
                        plainStart: plainCursor, block: block
                    )
                } else {
                    // The buffer keeps the `:name:` source byte for byte; the
                    // glyph is painted over it by the decoration layer. Colons
                    // and name are markers of one inline element, so focusing
                    // it reveals the source exactly like any other delimiter.
                    let inlineIndex = inlineNodes.count
                    let hiddenStyle = BlockStyle.collapsed(from: style, theme: theme)
                    appendHiddenRun(
                        node.prefix, role: .emoji, into: result, style: hiddenStyle,
                        block: block, depth: depth, inlineIndex: inlineIndex
                    )
                    let start = result.length
                    let plainStart = plainCursor
                    appendHiddenRun(
                        node.payload, role: .emoji, into: result, style: hiddenStyle,
                        block: block, depth: depth, inlineIndex: inlineIndex
                    )
                    let contentEnd = result.length
                    plainCursor = plainStart + node.payload.utf16.count
                    // The range covers the whole element, markers included:
                    // a caret beside a zero-width colon still counts as
                    // inside, so focus reveals the source generously.
                    let elementEnd = result.length + node.suffix.utf16.count
                    inlineNodes.append(
                        InlineRange(
                            index: inlineIndex, kind: node.kind,
                            range: NSRange(location: start, length: elementEnd - start),
                            blockID: block.id,
                            plainRange: NSRange(
                                location: plainStart, length: node.payload.utf16.count
                            ),
                            contentRange: NSRange(
                                location: start, length: contentEnd - start
                            )
                        )
                    )
                    appendHiddenRun(
                        node.suffix, role: .emoji, into: result, style: hiddenStyle,
                        block: block, depth: depth, inlineIndex: inlineIndex
                    )
                    register([.emojiGlyph], for: block.id)
                }
            case .html, .ruby:
                let start = result.length
                append(
                    node.verbatim, runAttributes(style, block: block, depth: depth), to: result
                )
                plainCursor += node.plainText.utf16.count
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
            let plainStart = plainCursor
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
                plainCursor = plainStart + node.plainText.utf16.count
            }
            let contentEnd = result.length
            appendHiddenRun(
                node.suffix, role: .linkClose, into: result, style: hiddenStyle,
                block: block, depth: depth, inlineIndex: inlineIndex
            )
            inlineNodes.append(
                InlineRange(
                    index: inlineIndex, kind: node.kind,
                    range: NSRange(location: start, length: max(result.length - start, 1)),
                    blockID: block.id,
                    plainRange: NSRange(location: plainStart, length: plainCursor - plainStart),
                    contentRange: NSRange(location: start, length: contentEnd - start)
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
            let plainStart = plainCursor
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
                plainCursor = plainStart + node.plainText.utf16.count
            }
            let contentEnd = result.length
            inlineNodes.append(
                InlineRange(
                    index: inlineIndex, kind: node.kind,
                    range: NSRange(location: start, length: max(result.length - start, 1)),
                    blockID: block.id,
                    plainRange: NSRange(location: plainStart, length: plainCursor - plainStart),
                    contentRange: NSRange(location: start, length: contentEnd - start)
                )
            )
            appendHiddenRun(
                node.suffix, role: close, into: result, style: hiddenStyle,
                block: block, depth: depth, inlineIndex: inlineIndex
            )
        }

        /// Emits a run that carries no visible width.
        private func appendHiddenRun(
            _ text: String, role: MarkerRole, into result: NSMutableAttributedString,
            style: BlockStyle, block: BlockNode, depth: Int, inlineIndex: Int? = nil,
            paragraphStyle: NSParagraphStyle? = nil
        ) {
            guard !text.isEmpty else { return }
            let index = markers.count
            let range = NSRange(location: result.length, length: (text as NSString).length)
            var attributes = style.base
            // A marker shares its line with the block's text, so it must carry the
            // block's paragraph style. See `BlockStyle.collapsed(from:theme:)`. An
            // explicit style wins: a nested list item's marker needs the item's own
            // indentation, which the block-level default (depth one) cannot know.
            if let paragraph = paragraphStyle ?? blockMarkerStyle {
                attributes[.paragraphStyle] = paragraph
            }
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
            // A nested child's runs keep the owning item's block identity; only the
            // decoration scope (`md.subBlock`) is the child's own.
            let visual = renderedBlockOverride ?? block
            var attributes: [NSAttributedString.Key: Any] = [
                MarkdownAttribute.block: visual.id,
                MarkdownAttribute.blockKind: visual.kind.rawValue,
                MarkdownAttribute.blockDepth: depth,
                MarkdownAttribute.rawBlock: visual.kind.isAttachmentRendered,
            ]
            if let renderedSubBlock { attributes[MarkdownAttribute.subBlock] = renderedSubBlock }
            if let renderedSubKind { attributes[MarkdownAttribute.subKind] = renderedSubKind }
            return attributes
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
            let emitted = String(block.inlines.verbatim)
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
            // The separator re-creates the terminator the *text* line had - the `\r`
            // sits just before the `\n` in the slice, and the block's own flag only
            // knows about the underline line. The newline is HIDDEN: a visible one
            // would break the underline into its own paragraph, whose heading strut
            // and margins added a full line height plus two margins after every
            // setext heading (measured 75.2pt against the reference's 16). Hidden,
            // the underline glyphs glue onto the text row exactly like the list
            // items' separators do.
            let textLineEndedCR =
                newline > source.startIndex && source[source.index(before: newline)] == "\r"
            let separator = textLineEndedCR ? "\r\n" : "\n"
            let separatorRange = NSRange(location: result.length, length: (separator as NSString).length)
            result.append(NSAttributedString(string: separator))
            result.addAttribute(MarkdownAttribute.hidden, value: true, range: separatorRange)
            let heading = BlockStyle.heading(theme: theme, level: block.attributes.level)
            // The underline paragraph must not inherit the heading's inter-block
            // spacing: its row is glued (invisible), and its `paragraphSpacing`
            // would still be counted once the next block's margin collapses
            // against it - the second 16pt of the measured 32.01 gap.
            var underlineStyle = BlockStyle.collapsed(from: heading, theme: theme)
            if let paragraphStyle = underlineStyle.base[.paragraphStyle]
                as? NSParagraphStyle,
                let mutable = paragraphStyle.mutableCopy() as? NSMutableParagraphStyle
            {
                mutable.paragraphSpacing = 0
                mutable.paragraphSpacingBefore = 0
                underlineStyle.base[.paragraphStyle] = mutable
            }
            appendHiddenRun(
                underline, role: .headingHash, into: result,
                style: underlineStyle,
                block: block, depth: depth
            )
        }

        /// The length of a list item's marker prefix in its source: the bullet or the
        /// digits, the `)` or `.` that may follow an ordered marker, and the spaces
        /// after it.
        private func markerPrefixLength(of source: String, ordered: Bool) -> Int {
            var index = source.startIndex
            // An item parsed at the list level keeps its leading indentation in
            // `source` (`  - [x] done`), so the whitespace must be skipped before the
            // marker is measured - stopping at the first space hid only the indent
            // and left the marker visible next to the drawn one.
            while index < source.endIndex, source[index] == " " || source[index] == "\t" {
                index = source.index(after: index)
            }
            if ordered {
                while index < source.endIndex, source[index].isNumber { index = source.index(after: index) }
                if index < source.endIndex, source[index] == "." || source[index] == ")" {
                    index = source.index(after: index)
                }
            } else if index < source.endIndex, !source[index].isWhitespace {
                // The bullet: exactly one character.
                index = source.index(after: index)
            }
            while index < source.endIndex, source[index] == " " || source[index] == "\t" {
                index = source.index(after: index)
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

        // MARK: Raw-line helpers

        private func isBlankLine(_ line: String) -> Bool {
            line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
        }

        /// Splits a raw line into the container indentation the parser stripped and
        /// the line's own content.
        private func splitIndent(_ line: String) -> (prefix: String, rest: String) {
            let prefix = line.prefix { $0 == " " || $0 == "\t" }
            return (String(prefix), String(line.dropFirst(prefix.count)))
        }

        /// Trims the marker remainder an ordered or task item's parser leaves in its
        /// first child's text - `. ` after the digits, `[x] ` after the flag - so the
        /// item's first line can render from the child's inline nodes and keep its
        /// styling. Returns nil when the trim cannot be made cleanly; the caller then
        /// falls back to the source text.
        private func trimmedFirstInlines(
            _ inlines: [InlineNode], block: BlockNode
        ) -> [InlineNode]? {
            let checked = block.attributes.checked
            // A plain bullet needs no trim: the parser already stripped `- `, so
            // the item's inlines are exactly the first line's content. Returning
            // them keeps inline styling (links, emphasis) alive on bullet items;
            // ordered and task items still need the marker remnants (`. `,
            // `[x] `) removed from the child's text below.
            guard checked != nil || block.attributes.isOrdered == true else { return inlines }
            if checked != nil {
                // The task flag usually arrives as a shortcut reference: the lexer
                // reads the bare `[x]` as a `[label]` with no destination, its label
                // the flag itself, so the paragraph's first node is a `.refLink` and
                // not text. The item's marker prefix already hid the flag's bytes,
                // so strip that node plus the space the marker consumed after the
                // `]`, and the content behind it keeps its inline styling.
                if let first = inlines.first, first.kind == .refLink,
                    first.prefix == "[", first.suffix == "]",
                    ["x", "X", " "].contains(first.attributes.reference ?? "")
                {
                    var rest = Array(inlines.dropFirst())
                    if var next = rest.first, next.kind == .text {
                        while next.payload.hasPrefix(" ") { next.payload.removeFirst() }
                        if next.payload.isEmpty { rest.removeFirst() } else { rest[0] = next }
                    }
                    return rest
                }
                // ...or as literal text when the lexer kept the flag unparsed.
                guard let first = inlines.first, first.kind == .text,
                    ["[x] ", "[X] ", "[ ] "].contains(String(first.payload.prefix(4)))
                else { return nil }
                var node = first
                node.payload.removeFirst(4)
                return [node] + Array(inlines.dropFirst())
            }
            guard let first = inlines.first, first.kind == .text
            else { return nil }
            var node = first
            let delimiter = block.attributes.orderedDelimiter
            guard node.payload.hasPrefix(String(delimiter)) else { return nil }
            node.payload.removeFirst()
            if node.payload.hasPrefix(" ") || node.payload.hasPrefix("\t") {
                node.payload.removeFirst()
            }
            return [node] + Array(inlines.dropFirst())
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
