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
            guard let blockID, let plans = layout.decorations[blockID], !plans.isEmpty else {
                return
            }
            paint(
                plans, in: view, theme: theme, lineRect: lineRect,
                lineCharRange: lineCharRange, layout: layout, blockID: blockID
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
        _ plans: [DecorationPlan], in view: MarkdownTextView, theme: EditorTheme,
        lineRect: NSRect, lineCharRange: NSRange, layout: LayoutOutput, blockID: Int
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // `lineFragmentRect` is in text-container coordinates while the graphics
        // context is the view's, and the container sits inset inside the view.
        // Without this conversion every decoration landed `textContainerInset` away
        // from the line it belonged to.
        let inset = view.textContainerInset
        let lineRect = lineRect.offsetBy(dx: inset.width, dy: inset.height)
        for plan in plans {
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
                drawMarker(
                    text, in: lineRect, width: width, alignment: alignment,
                    theme: theme, context: context)
            case let .taskCheckbox(checked, width):
                let side: CGFloat = 12
                let box = CGRect(
                    x: lineRect.minX + width - side * 1.9,
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
                guard let start = blockStart(of: blockID, in: layout),
                    lineCharRange.location == start
                else { break }
                // The first fragment's rectangle carries the block margin at its top,
                // above the glyphs. Painting from there offset every row by that
                // margin, so the header band sat over the empty space before the
                // table and the bottom border hung below the last row.
                let margin =
                    (view.textStorage?.attribute(
                        .paragraphStyle, at: start, effectiveRange: nil
                    ) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
                paintTable(
                    grid, top: lineRect.minY + margin, left: lineRect.minX,
                    width: lineRect.width, theme: theme, context: context
                )
            case let .tocPlaceholder(color):
                drawMarker(
                    "[Table of Contents]", in: lineRect, width: lineRect.width,
                    alignment: .left, theme: theme, context: context, color: color)
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

    private static func blockStart(of blockID: Int, in layout: LayoutOutput) -> Int? {
        layout.blocks.first { $0.id == blockID }?.range.location
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
