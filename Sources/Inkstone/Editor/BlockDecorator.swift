import AppKit
import Foundation

/// The parts of a rendered block that `NSParagraphStyle` cannot express.
///
/// TextKit 1 hands back exact line-fragment rectangles, so every decoration is
/// positioned from the text layout rather than from the block's nominal origin.
/// That is what makes a wrapped quote bar, a multi-line code-block background and a
/// wrapped list bullet line up correctly.
///
/// Decoration is discovered by walking the text layout, so it stays correct after
/// the caret moves, the window resizes or the theme changes - there is no cached
/// geometry to invalidate.
enum BlockDecorator {

    /// Draws everything for the visible portion of a text view.
    ///
    /// `@MainActor` because it reads `layoutManager`, `textStorage` and the view
    /// rects, all of which are main-actor state; the only caller is
    /// `MarkdownTextView.draw(_:)`, which is already on the main thread.
    @MainActor
    static func draw(
        in view: MarkdownTextView,
        theme: EditorTheme,
        layout: LayoutOutput
    ) {
        guard let manager = view.layoutManager, let container = view.textContainer else {
            return
        }
        let glyphRange = manager.glyphRange(for: container)
        let length = view.textStorage?.length ?? 0
        // Paint per line fragment, so each fragment gets the chrome of whichever
        // block owns it.
        //
        // `enumerateLineFragments` rather than a hand-rolled walk: deriving a line's
        // character range from a glyph range that runs to the end of the document
        // covers every following line too, which made the walk stop after the first
        // line - so nothing below the first line was ever decorated.
        manager.enumerateLineFragments(forGlyphRange: glyphRange) {
            lineRect, _, _, lineGlyphRange, _ in
            let focused = view.focusedBlockID
            let lineCharRange = manager.characterRange(
                forGlyphRange: lineGlyphRange, actualGlyphRange: nil
            )
            guard lineCharRange.length > 0, lineCharRange.location < length else { return }
            let blockID =
                view.textStorage?.attribute(
                    MarkdownAttribute.block, at: lineCharRange.location, effectiveRange: nil
                ) as? Int
            guard let blockID else { return }
            // A nested block's lines - a list inside an item, a quote, a code fence -
            // carry `md.subBlock`; its chrome is scoped by that id, while `md.block`
            // still names the owning item. The plans merge so a line can carry both
            // its own and its owner's chrome (an item's marker over its first line);
            // each plan keeps its origin so the first-line guard tests the right
            // scope.
            let subBlockID =
                view.textStorage?.attribute(
                    MarkdownAttribute.subBlock, at: lineCharRange.location, effectiveRange: nil
                ) as? Int
            var plans: [(plan: DecorationPlan, subScoped: Bool)] = []
            if let subBlockID, let nested = layout.decorations[subBlockID] {
                plans += nested.map { ($0, true) }
            }
            if let blockPlans = layout.decorations[blockID] {
                plans += blockPlans.map { ($0, false) }
            }
            guard !plans.isEmpty else { return }
            paint(
                plans, in: view, theme: theme, lineRect: lineRect,
                lineCharRange: lineCharRange, layout: layout, blockID: blockID,
                subBlockID: subBlockID
            )
            // Focus mode dims everything the caret is not in. A scrim rather than a
            // colour change: the glyphs are already generated and cached by TextKit,
            // and re-running the layout in a second colour is what the zero-width
            // marker mechanism makes expensive.
            let isDimmed = view.isFocusModeEnabled && blockID != focused
            if isDimmed, let context = NSGraphicsContext.current?.cgContext {
                let inset = view.textContainerInset
                let rect = lineRect.offsetBy(dx: inset.width, dy: inset.height)
                context.setFillColor(theme.background.nsColor.withAlphaComponent(0.72).cgColor)
                context.fill(rect)
            }
        }
    }

    @MainActor
    private static func paint(
        _ plans: [(plan: DecorationPlan, subScoped: Bool)], in view: MarkdownTextView,
        theme: EditorTheme,
        lineRect: NSRect, lineCharRange: NSRange, layout: LayoutOutput, blockID: Int,
        subBlockID: Int? = nil
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // `lineFragmentRect` is in text-container coordinates while the graphics
        // context is the view's, and the container sits inset inside the view.
        // Without this conversion every decoration landed `textContainerInset` away
        // from the line it belonged to.
        let inset = view.textContainerInset
        let lineRect = lineRect.offsetBy(dx: inset.width, dy: inset.height)
        for (plan, subScoped) in plans {
            // Each plan's first-line guard tests its own scope: a block-owned plan
            // (the item's marker) keys on `md.block`, a nested plan (a quote bar, a
            // code background inside an item) on `md.subBlock`.
            switch plan {
            case let .headingRule(color):
                // Under the heading, not across it: the text view is flipped, so the
                // bottom of the line fragment is `maxY`. Anchoring to `minY` drew the
                // rule at the top of the line, straight through the glyphs.
                context.setFillColor(color.cgColor)
                context.fill(
                    CGRect(
                        x: lineRect.minX, y: lineRect.maxY - EditorMetrics.hairline,
                        width: lineRect.width, height: EditorMetrics.hairline
                    )
                )
            case let .quoteBar(color, width, inset):
                context.setFillColor(color.withAlphaComponent(EditorMetrics.quoteBarAlpha).cgColor)
                context.fill(
                    CGRect(
                        x: lineRect.minX, y: lineRect.minY,
                        width: width, height: lineRect.height
                    )
                )
                _ = inset
            case let .listMarker(text, width, alignment):
                // The marker draws on the one line that contains its own marker run:
                // never on a wrapped fragment, and never on the nested lines an item
                // contains. A nested item's line 0 also merges its owner's plans; the
                // owner's marker run sits on the owner's first line, not here, so the
                // containment test filters it out.
                guard markerIsOnLine(planOrigin: subScoped ? (subBlockID ?? blockID) : blockID, lineCharRange: lineCharRange, in: layout)
                else { break }
                drawMarker(
                    text, in: lineRect, width: width, alignment: alignment,
                    theme: theme, context: context)
            case let .taskCheckbox(checked, width):
                // One box on the first line: without the guard every fragment
                // of a wrapped item drew its own, while hit-testing only knows
                // the first. The first line is the one carrying the item's own
                // marker run - see `.listMarker`.
                guard markerIsOnLine(planOrigin: subScoped ? (subBlockID ?? blockID) : blockID, lineCharRange: lineCharRange, in: layout)
                else { break }
                let side: CGFloat = 12
                // Right edge 4pt before the text column, like the drawn bullets.
                let box = CGRect(
                    x: lineRect.minX + width - side - 4,
                    y: lineRect.midY - side / 2,
                    width: side, height: side
                )
                context.setStrokeColor(theme.text.nsColor.withAlphaComponent(0.55).cgColor)
                context.setLineWidth(1)
                context.stroke(box)
                if checked {
                    context.setStrokeColor(theme.text.nsColor.cgColor)
                    context.setLineWidth(1.6)
                    context.setLineCap(.round)
                    context.setLineJoin(.round)
                    // The text view is flipped (origin at top-left, y grows down),
                    // so the elbow sits near `maxY` (bottom) and the tip near
                    // `minY` (top). The previous version had them swapped and the
                    // tick rendered upside-down as `^`.
                    context.move(to: CGPoint(x: box.minX + 2.5, y: box.midY))
                    context.addLine(to: CGPoint(x: box.minX + side / 2 - 0.5, y: box.maxY - 2.5))
                    context.addLine(to: CGPoint(x: box.maxX - 2.5, y: box.minY + 3))
                    context.strokePath()
                }
            case let .codeBlock(background, radius):
                let path = CGPath(
                    roundedRect: lineRect.insetBy(dx: 0, dy: 0),
                    cornerWidth: radius, cornerHeight: radius,
                    transform: nil
                )
                context.addPath(path)
                context.setFillColor(background.cgColor)
                context.fillPath()
            case let .horizontalRule(color, height):
                context.setFillColor(color.cgColor)
                context.fill(
                    CGRect(
                        x: lineRect.minX, y: lineRect.midY - height / 2,
                        width: lineRect.width, height: height
                    )
                )
            case let .inlineCode(background, radius):
                // Inline chrome is painted per line fragment by the inline pass.
                _ = (background, radius)
            case let .alertBox(title, background, border):
                let path = CGPath(
                    roundedRect: lineRect.insetBy(dx: 0, dy: 0),
                    cornerWidth: EditorMetrics.radiusMedium,
                    cornerHeight: EditorMetrics.radiusMedium,
                    transform: nil
                )
                context.addPath(path)
                context.setFillColor(background.cgColor)
                context.fillPath()
                context.setStrokeColor(border.cgColor)
                context.setLineWidth(EditorMetrics.hairline)
                context.addPath(path)
                context.strokePath()
                drawMarker(
                    title, in: lineRect, width: lineRect.width, alignment: .left,
                    theme: theme, context: context, color: border, small: true)
            case let .inlineImage(path, alt, height):

                // An inline image shares its line with other text, so it is drawn from
                // the alt-text run's glyph rect rather than from the whole line.
                if let origin = inlineImageOrigin(lineCharRange, in: view) {
                    view.imagePainter.draw(
                        path: path, at: origin, measureWidth: lineRect.width,
                        minimumHeight: height
                    )
                } else if !alt.isEmpty {
                    // Nothing to draw; the alt text is the fallback and stays hidden, so
                    // show it rather than leaving an empty line.
                    drawMarker(
                        alt, in: lineRect, width: lineRect.width, alignment: .left,
                        theme: theme, context: context, color: theme.marker.nsColor)
                }
            case let .tableGrid(grid):
                // `painted` true means the cells are ours to draw; focus clears it and
                // the block shows its own source instead.
                guard isPainted(lineCharRange, in: view) else { break }
                // Once per block, from its first line: a table is one object, and a
                // line of all-zero-width glyphs is not a reliable place to count rows.
                guard
                    isBlockStart(
                        lineCharRange, blockID: blockID, subBlockID: subBlockID,
                        subScoped: subScoped, in: view
                    )
                else { break }
                // The first fragment's rectangle carries the block margin at its top,
                // above the glyphs. Painting from there offset every row by that
                // margin, so the header band sat over the empty space before the
                // table and the bottom border hung below the last row.
                let margin =
                    (view.textStorage?.attribute(
                        .paragraphStyle, at: lineCharRange.location, effectiveRange: nil
                    ) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
                paintTable(
                    grid, top: lineRect.minY + margin, left: lineRect.minX,
                    width: lineRect.width, theme: theme, context: context
                )
            case .emojiGlyph:
                // Painted from the block's first line only; every fragment of
                // the block would otherwise draw every glyph once each.
                guard
                    isBlockStart(
                        lineCharRange, blockID: blockID, subBlockID: subBlockID,
                        subScoped: subScoped, in: view
                    )
                else { break }
                // The emoji nodes live under the id the plan was registered with;
                // match the other scope too, so an item's own first line paints the
                // glyphs of both its marker scope and its inline content.
                let originID = subScoped ? (subBlockID ?? blockID) : blockID
                let otherID = subScoped ? blockID : subBlockID
                paintEmojiGlyphs(
                    in: view, blockID: originID, ownerID: otherID,
                    layout: layout, theme: theme
                )
            case let .frontMatterTable(front):
                // Painted like a table: from the first line only, and skipped
                // while focused, when the source is showing.
                guard isPainted(lineCharRange, in: view) else { break }
                guard
                    isBlockStart(
                        lineCharRange, blockID: blockID, subBlockID: subBlockID,
                        subScoped: subScoped, in: view
                    )
                else { break }
                let margin =
                    (view.textStorage?.attribute(
                        .paragraphStyle, at: lineCharRange.location, effectiveRange: nil
                    ) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
                paintFrontMatter(
                    front, top: lineRect.minY + margin, left: lineRect.minX,
                    width: lineRect.width, theme: theme, context: context
                )
            case let .tocPlaceholder(color):
                drawMarker(
                    "[Table of Contents]", in: lineRect, width: lineRect.width,
                    alignment: .left, theme: theme, context: context, color: color)
            case let .tocEntries(entries):
                // Painted like a table: only from the block's first line, and
                // only while the block is not focused (focus reveals the source).
                guard isPainted(lineCharRange, in: view) else { break }
                guard
                    isBlockStart(
                        lineCharRange, blockID: blockID, subBlockID: subBlockID,
                        subScoped: subScoped, in: view
                    )
                else { break }
                let margin =
                    (view.textStorage?.attribute(
                        .paragraphStyle, at: lineCharRange.location, effectiveRange: nil
                    ) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
                paintTOC(
                    entries, top: lineRect.minY + margin, left: lineRect.minX,
                    width: lineRect.width, theme: theme, context: context
                )
            }
        }
    }

    /// Whether this line's block is currently shown as its own source text rather
    /// than being painted.
    @MainActor
    private static func isPainted(_ range: NSRange, in view: MarkdownTextView) -> Bool {
        guard let storage = view.textStorage, range.location < storage.length else { return false }
        return storage.attribute(
            MarkdownAttribute.painted, at: range.location, effectiveRange: nil
        ) as? Bool == true
    }

    /// The bottom-left corner of an inline image, in view coordinates.
    ///
    /// Found from the first glyph of the line that belongs to an image node, because the
    /// line rect alone cannot say where in the line the picture starts.
    @MainActor
    private static func inlineImageOrigin(
        _ range: NSRange, in view: MarkdownTextView
    ) -> NSPoint? {
        guard let layoutManager = view.layoutManager, let container = view.textContainer,
            let storage = view.textStorage
        else { return nil }
        // Every glyph of an image - the `![`, the alt text, the `](path)` - is zero
        // width, because the whole element is hidden. A null glyph still has a
        // position, so the line fragment is the anchor rather than a glyph rect.
        let inset = view.textContainerInset
        var position = min(range.location, storage.length - 1)
        while position < NSMaxRange(range) && position < storage.length {
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: position, length: 1),
                actualCharacterRange: nil
            )
            if glyphs.length > 0 {
                let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
                return NSPoint(x: rect.minX + inset.width, y: rect.minY + inset.height)
            }
            position += 1
        }
        return nil
    }

    /// Whether the line fragment carries the item's visible content - the line the
    /// marker belongs to.
    ///
    /// Hidden markers collapse to zero-width glyphs, and TextKit glues those onto
    /// the *preceding* line fragment: the marker's own location sits in a fragment
    /// above the text line, so its position cannot identify the line to draw on.
    /// The first character *after* the marker run is the item's visible content;
    /// the fragment containing it is the one the chrome belongs to.
    private static func markerIsOnLine(
        planOrigin: Int, lineCharRange: NSRange, in layout: LayoutOutput
    ) -> Bool {
        guard let marker = layout.markers.first(where: { $0.blockID == planOrigin }) else {
            return false
        }
        return NSLocationInRange(NSMaxRange(marker.range), lineCharRange)
    }

    /// Whether this line fragment is the first of the block whose chrome is being
    /// painted.
    ///
    /// The test is the character *before* the line, not a stored block range: list
    /// items have no `BlockRange` of their own (only top-level blocks do), so a
    /// range lookup cannot find them. A block-owned plan is first on the line whose
    /// preceding character belongs to a different `md.block` - a bare newline
    /// between blocks, or the previous block's text. A nested plan keys the same
    /// way on `md.subBlock`.
    @MainActor
    private static func isBlockStart(
        _ lineCharRange: NSRange, blockID: Int, subBlockID: Int?,
        subScoped: Bool, in view: MarkdownTextView
    ) -> Bool {
        guard let storage = view.textStorage, lineCharRange.location > 0 else { return true }
        let key = subScoped ? MarkdownAttribute.subBlock : MarkdownAttribute.block
        let id = subScoped ? (subBlockID ?? blockID) : blockID
        let previous = storage.attribute(key, at: lineCharRange.location - 1, effectiveRange: nil) as? Int
        return previous != id
    }

    /// Paints a whole table, stacked down from `top`: header stripe, row separators,
    /// outer border, then the cells.
    ///
    /// Row tops come from the heights the layout pass wrote into the paragraph
    /// styles, not from the line fragments: every glyph of the table is zero width,
    /// so a row's own fragment is not a dependable source for where it ended.
    @MainActor
    private static func paintTable(
        _ grid: TableGrid, top: CGFloat, left: CGFloat, width: CGFloat,
        theme: EditorTheme, context: CGContext
    ) {
        var tops: [CGFloat] = []
        tops.reserveCapacity(grid.rows.count)
        var cursor = top
        for height in grid.rowHeights {
            tops.append(cursor)
            cursor += height
        }
        let box = CGRect(x: left, y: top, width: width, height: cursor - top)
        guard box.height > 0 else { return }

        context.setFillColor(theme.tableStripe.nsColor.cgColor)
        context.fill(CGRect(x: box.minX, y: box.minY, width: box.width, height: grid.rowHeights.first ?? grid.rowHeight))

        context.setStrokeColor(theme.tableBorder.nsColor.cgColor)
        context.setLineWidth(EditorMetrics.hairline)
        for separatorY in tops.dropFirst() {
            context.move(to: CGPoint(x: box.minX, y: separatorY))
            context.addLine(to: CGPoint(x: box.maxX, y: separatorY))
        }
        context.strokePath()
        context.stroke(box.insetBy(dx: 0.5, dy: 0.5))

        for (rowIndex, cells) in grid.rows.enumerated() {
            let rowTop = tops[rowIndex]
            let bandHeight = grid.rowHeights[rowIndex]
            for (column, cell) in cells.enumerated() where !cell.isEmpty {
                guard column < grid.columnCount else { break }
                let alignment = column < grid.alignments.count ? grid.alignments[column] : .left
                let style = TableGrid.wrapStyle(lineHeight: grid.rowHeight)
                style.alignment = alignment
                let run = NSAttributedString(
                    string: cell,
                    attributes: [.font: grid.font, .foregroundColor: grid.color, .paragraphStyle: style]
                )
                let columnWidth = grid.columnWidths[column]
                let originX = left + grid.columnOffsets[column]
                let measured = run.boundingRect(
                    with: CGSize(width: columnWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).size
                // Centred inside the band the row occupies, however many line boxes
                // the row was sized for.
                let originY = rowTop + max(0, (bandHeight - measured.height) / 2)
                // Clipped to the column so a cell that still overruns after wrapping
                // cannot paint over its neighbour.
                context.saveGState()
                context.clip(
                    to: CGRect(
                        x: originX - 1, y: rowTop, width: columnWidth + 2, height: bandHeight
                    ))
                run.draw(
                    with: NSRect(x: originX, y: originY, width: columnWidth, height: measured.height),
                    options: [.usesLineFragmentOrigin], context: nil
                )
                context.restoreGState()
            }
        }
    }

    /// Paints one row per heading, stacked down from `top`: the same row
    /// geometry the builder reserved through the paragraph style, so rows and
    /// hit-testing agree on where each entry sits.
    @MainActor
    private static func paintTOC(
        _ entries: [MarkdownDocument.Heading], top: CGFloat, left: CGFloat,
        width: CGFloat, theme: EditorTheme, context: CGContext
    ) {
        let rowHeight = theme.bodyLineHeight * theme.bodyFontSize
        let font = EditorFont.nsSystem(size: theme.bodyFontSize)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        for (index, entry) in entries.enumerated() {
            let rowTop = top + CGFloat(index) * rowHeight
            let indent = CGFloat(max(entry.level - 1, 0)) * 20
            let run = NSAttributedString(
                string: entry.text.isEmpty ? "(untitled)" : entry.text,
                attributes: [
                    .font: font,
                    .foregroundColor: theme.text.nsColor,
                    .paragraphStyle: style,
                ]
            )
            let measured = run.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: rowHeight),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).size
            context.saveGState()
            context.clip(
                to: CGRect(x: left + indent, y: rowTop, width: max(0, width - indent), height: rowHeight)
            )
            run.draw(
                with: NSRect(
                    x: left + indent, y: rowTop + max(0, (rowHeight - measured.height) / 2),
                    width: max(0, width - indent), height: measured.height
                ),
                options: [.usesLineFragmentOrigin], context: nil
            )
            context.restoreGState()
        }
    }

    /// Paints every emoji glyph of a block over its hidden `:name:` source.
    ///
    /// Positions come from the hidden name runs themselves: null glyphs carry
    /// no advance but keep their pen position, so the glyph draws exactly where
    /// the source sits, mid-line included. An element revealed under the caret
    /// shows its source instead and is skipped here.
    ///
    /// All geometry is container-based: `boundingRect(forGlyphRange:)` for the
    /// pen position, `lineFragmentRect(forGlyphAt:)` for the line box the glyph
    /// centres in. `location(forGlyphAt:)` is deliberately not used - it
    /// returns fragment-relative baseline coordinates, which drew every glyph
    /// near the container origin.
    @MainActor
    private static func paintEmojiGlyphs(
        in view: MarkdownTextView, blockID: Int, ownerID: Int?,
        layout: LayoutOutput, theme: EditorTheme
    ) {
        guard let manager = view.layoutManager, let container = view.textContainer,
            let storage = view.textStorage
        else { return }
        let inset = view.textContainerInset
        // The plan may be registered under the nested child (a paragraph inside an
        // item) or under the owning item (the item's own first line); match both so
        // every emoji of the line's block paints.
        for node in layout.inlineNodes
        where node.kind == .emoji && (node.blockID == blockID || node.blockID == ownerID) {
            guard node.contentRange.length > 0,
                NSMaxRange(node.contentRange) <= storage.length
            else { continue }
            // Revealed markers mean the caret is inside: source, not glyph.
            let hidden =
                storage.attribute(
                    MarkdownAttribute.hidden, at: node.contentRange.location, effectiveRange: nil
                ) as? Bool
            guard hidden == true else { continue }
            let name = (storage.string as NSString).substring(with: node.contentRange)
            let glyph = EmojiCatalog.glyph(for: name)
            guard !glyph.isEmpty else { continue }
            // The run's own font, so headings draw heading-sized glyphs; the
            // system falls back to the colour-emoji face for the scalars.
            let font =
                (storage.attribute(.font, at: node.contentRange.location, effectiveRange: nil)
                    as? NSFont) ?? EditorFont.nsSystem(size: theme.bodyFontSize)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: theme.text.nsColor,
            ]
            let glyphs = manager.glyphRange(
                forCharacterRange: node.contentRange, actualCharacterRange: nil
            )
            guard glyphs.length > 0 else { continue }
            let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let fragment = manager.lineFragmentRect(
                forGlyphAt: glyphs.location, effectiveRange: nil
            )
            let size = (glyph as NSString).size(withAttributes: attributes)
            let point = NSPoint(
                x: bounds.minX + inset.width,
                y: fragment.minY + inset.height + max(0, (fragment.height - size.height) / 2)
            )
            (glyph as NSString).draw(at: point, withAttributes: attributes)
        }
    }

    /// Paints a front matter block's key/value rows, stacked down from `top`.
    /// Row tops come from the layout's own heights - fence rows collapsed -
    /// so the rows sit on the source lines they stand in for.
    @MainActor
    private static func paintFrontMatter(
        _ front: FrontMatterLayout, top: CGFloat, left: CGFloat, width: CGFloat,
        theme: EditorTheme, context: CGContext
    ) {
        let font = EditorFont.nsSystem(size: theme.bodyFontSize)
        let keyFont = NSFont.systemFont(ofSize: theme.bodyFontSize, weight: .semibold)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        // The key column fits the longest key, capped so a pathological key
        // cannot eat the values.
        var keyWidth: CGFloat = 0
        for row in front.rows where !row.isFence && !row.key.isEmpty {
            keyWidth = max(
                keyWidth,
                (row.key as NSString).size(withAttributes: [.font: keyFont]).width
            )
        }
        keyWidth = min(keyWidth + 16, max(width * 0.35, 0))
        var cursor = top
        for row in front.rows {
            let height =
                row.isFence ? FrontMatterLayout.collapsedFenceLineHeight : front.rowHeight
            defer { cursor += height }
            guard !row.isFence else { continue }
            if row.key.isEmpty {
                // No colon: running text across the whole measure, one line.
                let run = NSAttributedString(
                    string: row.value,
                    attributes: [
                        .font: font, .foregroundColor: theme.text.nsColor,
                        .paragraphStyle: style,
                    ]
                )
                let measured = run.boundingRect(
                    with: CGSize(width: max(1, width), height: front.rowHeight),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).size
                context.saveGState()
                context.clip(to: CGRect(x: left, y: cursor, width: width, height: height))
                run.draw(
                    with: NSRect(
                        x: left, y: cursor + max(0, (height - measured.height) / 2),
                        width: width, height: measured.height
                    ),
                    options: [.usesLineFragmentOrigin], context: nil
                )
                context.restoreGState()
                continue
            }
            let key = NSAttributedString(
                string: row.key,
                attributes: [.font: keyFont, .foregroundColor: theme.marker.nsColor]
            )
            let value = NSAttributedString(
                string: row.value,
                attributes: [
                    .font: font, .foregroundColor: theme.text.nsColor,
                    .paragraphStyle: style,
                ]
            )
            let keySize = key.size()
            let valueWidth = max(0, width - keyWidth)
            let valueHeight = value.boundingRect(
                with: CGSize(width: max(1, valueWidth), height: height),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).size.height
            context.saveGState()
            context.clip(to: CGRect(x: left, y: cursor, width: width, height: height))
            key.draw(
                at: NSPoint(
                    x: left, y: cursor + max(0, (height - keySize.height) / 2)
                ))
            value.draw(
                with: NSRect(
                    x: left + keyWidth, y: cursor + max(0, (height - valueHeight) / 2),
                    width: valueWidth, height: valueHeight
                ),
                options: [.usesLineFragmentOrigin], context: nil
            )
            context.restoreGState()
        }
    }

    private static func drawMarker(
        _ text: String, in rect: NSRect, width: CGFloat, alignment: NSTextAlignment,
        theme: EditorTheme, context: CGContext,
        color: NSColor? = nil, small: Bool = false
    ) {
        let font =
            small
            ? NSFont.systemFont(ofSize: 9, weight: .semibold)
            : EditorFont.nsSystem(size: theme.bodyFontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color ?? theme.text.nsColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        var originX: CGFloat
        switch alignment {
        case .right: originX = rect.minX + width - size.width - 4
        default: originX = rect.minX + 2
        }
        NSGraphicsContext.saveGraphicsState()
        context.saveGState()
        // TextKit 1's line rects are in the text view's coordinate space, which is
        // already flipped for an NSTextView, so no flip is needed here.
        (text as NSString).draw(
            at: NSPoint(x: originX, y: rect.minY + (rect.height - size.height) / 2),
            withAttributes: attributes
        )
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
    }
}
