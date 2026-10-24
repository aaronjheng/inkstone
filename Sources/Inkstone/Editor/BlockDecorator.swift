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
        // block owns it. Lines are collected first: code-block chrome is per
        // BLOCK - one rounded, padded, bordered box around the whole body - which
        // needs the union of a block's lines rather than any single fragment.
        //
        // `enumerateLineFragments` rather than a hand-rolled walk: deriving a line's
        // character range from a glyph range that runs to the end of the document
        // covers every following line too, which made the walk stop after the first
        // line - so nothing below the first line was ever decorated.
        var lines: [LineFragment] = []
        manager.enumerateLineFragments(forGlyphRange: glyphRange) {
            lineRect, _, _, lineGlyphRange, _ in
            let lineCharRange = manager.characterRange(
                forGlyphRange: lineGlyphRange, actualGlyphRange: nil
            )
            guard lineCharRange.length > 0, lineCharRange.location < length else { return }
            // A fragment may open with characters that carry no block identity: a
            // boundary separator newline, or a collapsed delimiter row's
            // terminator that the next painted row's zero-width glyphs glued
            // onto. Probe forward to the block's own first character — reading
            // the raw location made every glued painted row (whole tables after
            // their first) invisible.
            guard let storage = view.textStorage else { return }
            // A fragment may open with characters that belong to the container
            // rather than to the row: a boundary separator newline, or a quote's
            // marker run (md.block only — no sub-scope, nothing painted) ahead
            // of a nested table's painted rows. Scan the whole fragment: the
            // block identity, the sub-scope and the painted flag each come from
            // their own first carrier — reading them at the raw location made
            // nested painted rows (tables in quotes and list items) lose their
            // plans and never paint.
            var blockLocation: Int?
            var subBlockID: Int?
            var paintedLocation: Int?
            var scanLocation = lineCharRange.location
            while scanLocation < NSMaxRange(lineCharRange) {
                if blockLocation == nil,
                    storage.attribute(
                        MarkdownAttribute.block, at: scanLocation, effectiveRange: nil
                    ) != nil
                { blockLocation = scanLocation }
                if subBlockID == nil,
                    let value = storage.attribute(
                        MarkdownAttribute.subBlock, at: scanLocation, effectiveRange: nil
                    ) as? Int
                { subBlockID = value }
                if paintedLocation == nil,
                    storage.attribute(
                        MarkdownAttribute.painted, at: scanLocation, effectiveRange: nil
                    ) as? Bool == true
                { paintedLocation = scanLocation }
                if blockLocation != nil, subBlockID != nil, paintedLocation != nil { break }
                scanLocation += 1
            }
            let blockID = storage.attribute(
                MarkdownAttribute.block,
                at: blockLocation ?? lineCharRange.location, effectiveRange: nil
            ) as? Int
            guard let blockID else { return }
            lines.append(
                LineFragment(
                    rect: lineRect, charRange: lineCharRange, blockID: blockID,
                    subBlockID: subBlockID,
                    blockLocation: blockLocation ?? lineCharRange.location,
                    paintedLocation: paintedLocation
                )
            )
        }

        // The block's first painted character: the painted-row guards key on it,
        // so a block paints once. A glued hairline fragment (a boundary newline
        // with the row's zero-width glyphs) and the real row both pass
        // `isBlockStart` — painting from each doubled every rule and band.
        var paintFrom: [Int: Int] = [:]
        var paintHeight: [Int: CGFloat] = [:]
        for line in lines {
            guard let painted = line.paintedLocation,
                line.charRange.contains(painted)
            else { continue }
            let key = line.subBlockID ?? line.blockID
            if line.rect.height > (paintHeight[key] ?? -1) {
                paintHeight[key] = line.rect.height
                paintFrom[key] = line.charRange.location
            }
        }

        // Which ids own code-block chrome, from the layout's registered plans.
        var codeOwners: [Int: DecorationPlan] = [:]
        for (id, plans) in layout.decorations {
            if let plan = plans.first(where: { plan in
                if case .codeBlock = plan { return true }
                return false
            }) {
                codeOwners[id] = plan
            }
        }
        paintCodeBlocks(lines, in: view, theme: theme, owners: codeOwners)

        for line in lines {
            let focused = view.focusedBlockID
            // A nested block's lines - a list inside an item, a quote, a code fence -
            // carry `md.subBlock`; its chrome is scoped by that id, while `md.block`
            // still names the owning item. The plans merge so a line can carry both
            // its own and its owner's chrome (an item's marker over its first line);
            // each plan keeps its origin so the first-line guard tests the right
            // scope.
            var plans: [(plan: DecorationPlan, subScoped: Bool)] = []
            if let subBlockID = line.subBlockID, let nested = layout.decorations[subBlockID] {
                plans += nested.map { ($0, true) }
            }
            if let blockPlans = layout.decorations[line.blockID] {
                plans += blockPlans.map { ($0, false) }
            }
            // Code-block chrome is painted per block above; per-line fills would
            // break the border and the painted padding.
            plans = plans.filter { plan, _ in
                if case .codeBlock = plan { return false }
                return true
            }
            guard !plans.isEmpty else { continue }
            paint(
                plans, in: view, theme: theme, lineRect: line.rect,
                lineCharRange: line.charRange, layout: layout, blockID: line.blockID,
                subBlockID: line.subBlockID, blockLocation: line.blockLocation,
                paintedLocation: line.paintedLocation,
                paintFromLocation: paintFrom[line.subBlockID ?? line.blockID]
            )
            // Focus mode dims everything the caret is not in. A scrim rather than a
            // colour change: the glyphs are already generated and cached by TextKit,
            // and re-running the layout in a second colour is what the zero-width
            // marker mechanism makes expensive.
            let isDimmed = view.isFocusModeEnabled && line.blockID != focused
            if isDimmed, let context = NSGraphicsContext.current?.cgContext {
                let inset = view.textContainerInset
                let rect = line.rect.offsetBy(dx: inset.width, dy: inset.height)
                context.setFillColor(theme.background.nsColor.withAlphaComponent(0.72).cgColor)
                context.fill(rect)
            }
        }
    }

    /// One visible line fragment. The block identity resolves after the
    /// enumeration (a storage read in the enumeration block raised the
    /// "edited during layout" exception).
    private struct LineFragment {
        var rect: NSRect
        var charRange: NSRange
        var blockID: Int = 0
        var subBlockID: Int?
        /// The block's own first character inside the range: a fragment may open
        /// with characters that carry no block identity (a boundary separator
        /// newline the row's zero-width glyphs glued onto), so the painted-row
        /// guards read here, not at `charRange.location`.
        var blockLocation: Int = 0
        /// The fragment's first character that carries `md.painted`: a nested
        /// painted row's fragment opens with the container's marker run, which
        /// is not painted.
        var paintedLocation: Int?
    }

    /// The geometry the decoration layer paints for a list marker.
    ///
    /// The reference leaves `list-style-type` to the browser, so the outside
    /// marker is the UA ladder - disc, circle, square by depth - and it hangs
    /// like a browser marker: centred a fixed em-gap left of the text column
    /// (ink-measured 1.0em on the VS Code reference render), not mid-indent,
    /// so the gap
    /// stays constant at every nesting level. Drawing the `•` glyph instead
    /// rendered it at ~60% of the reference size and off-centre, which is why
    /// shapes are painted. Exposed for the headless layout dump so the exported
    /// geometry is the exact geometry this layer paints.
    struct ListMarkerGeometry {
        enum Shape {
            case disc, ring, square, text(String)
        }

        var shape: Shape
        var center: CGPoint
        /// Disc diameter, ring outer diameter, square side.
        var size: CGFloat
        /// Ring stroke width; zero for the other shapes.
        var lineWidth: CGFloat

        init(shape: Shape, center: CGPoint, size: CGFloat, lineWidth: CGFloat = 0) {
            self.shape = shape
            self.center = center
            self.size = size
            self.lineWidth = lineWidth
        }
    }

    static func listMarkerGeometry(
        text: String, width: CGFloat, lineRect: NSRect, theme: EditorTheme
    ) -> ListMarkerGeometry {
        let em = theme.bodyFontSize
        // Chromium's UA outside marker: the disc's centre sits exactly one em
        // left of the text column (ink-measured on the VS Code reference
        // render: the 5px disc at 14px body text centres 14pt in from the
        // column).
        let center = CGPoint(x: lineRect.minX + width - em, y: lineRect.midY)
        switch text {
        case "•":
            return ListMarkerGeometry(shape: .disc, center: center, size: em * 0.375)
        case "◦":
            return ListMarkerGeometry(
                shape: .ring, center: center, size: em * 0.4375, lineWidth: em * 0.0625
            )
        case "▪":
            return ListMarkerGeometry(shape: .square, center: center, size: em * 0.375)
        default:
            return ListMarkerGeometry(shape: .text(text), center: center, size: 0)
        }
    }

    /// The chip rects the decoration layer paints for a line's inline code,
    /// in container coordinates (before the container inset).
    ///
    /// The reference chips inline code snugly: a rounded box hugging the run's
    /// own font box, 2px side padding and the 1px `code, tt` border - not the
    /// full line box a background attribute would fill. Exposed for the
    /// headless layout dump alongside `listMarkerGeometry`.
    /// One chip: the painted rect plus the font metrics it was derived from.
    struct ChipRun {
        var rect: CGRect
        var fontSize: CGFloat
        var fontBox: CGFloat
        /// The row's engine baseline in container coordinates, exported for
        /// the dump's position comparison (the reference measures its code
        /// spans against the same anchor).
        var baseline: CGFloat
    }

    static func inlineCodeChipRuns(
        theme: EditorTheme,
        storage: NSTextStorage, manager: NSLayoutManager,
        container: NSTextContainer, lineCharRange: NSRange,
        baselines: [Int: CGFloat]
    ) -> [ChipRun] {
        var runs: [ChipRun] = []
        storage.enumerateAttribute(
            MarkdownAttribute.codeRun, in: lineCharRange, options: []
        ) { value, range, _ in
            guard (value as? Bool) == true else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            // The bounding rect spans the line's full height; the chip hugs the
            // run's own font box around the line's baseline instead. The baseline
            // sits mid-line: the dominant font's box centres in the fixed line
            // height, and the chip's box hangs from it.
            //
            // The storage's font attribute is read AFTER layout, and TextKit 1
            // rewrites it in place when the run holds characters the set face
            // cannot render: a CJK code span comes back as PingFang at the same
            // size, whose box is ~3.4pt taller than the mono face's. The chip is
            // chrome for the code face, so derive the box from that face at the
            // run's (preserved) size instead of the substituted attribute.
            let measured = storage.attribute(.font, at: range.location, effectiveRange: nil)
                as? NSFont
            guard let measured else { return }
            let font = EditorFont.nsMono(theme: theme, size: measured.pointSize)
            let bounding = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let contentHeight = font.ascender - font.descender
            guard contentHeight > 0, bounding.height > 0 else { return }
            // The run's horizontal extent comes from the laid-out advances, not
            // from the bounding rect: TextKit 1 pads the bounding box at
            // attribute-run boundaries for CJK glyphs (~5.5pt over four), while
            // the glyphs' locations carry the exact advances (28.0pt per full-width
            // glyph at 28pt, matching the reference's shaping). The next glyph's
            // location is the run's end; when the run ends its line, the
            // fragment's used width is. The bounding rect is kept only for the
            // vertical maths, which stays empirically aligned.
            let firstGlyph = glyphs.location
            let nextGlyph = NSMaxRange(glyphs)
            var lineGlyphs = NSRange()
            _ = manager.lineFragmentRect(
                forGlyphAt: firstGlyph, effectiveRange: &lineGlyphs,
                withoutAdditionalLayout: true
            )
            let xStart = manager.location(forGlyphAt: firstGlyph).x
            let xEnd: CGFloat
            if nextGlyph < manager.numberOfGlyphs, NSLocationInRange(nextGlyph, lineGlyphs) {
                xEnd = manager.location(forGlyphAt: nextGlyph).x
            } else {
                xEnd = manager.lineFragmentUsedRect(
                    forGlyphAt: firstGlyph, effectiveRange: nil, withoutAdditionalLayout: true
                ).maxX
            }
            var dominant = font
            storage.enumerateAttribute(.font, in: lineCharRange, options: []) {
                candidate, _, _ in
                if let candidate = candidate as? NSFont,
                    candidate.ascender - candidate.descender
                        > dominant.ascender - dominant.descender
                {
                    dominant = candidate
                }
            }
            // The chip hugs the mono font box, and the mono glyphs sit on the
            // row's real baseline — captured by the layout delegate. The old
            // model centred the dominant font's box in the fixed line height,
            // which is where Chromium puts its baseline, not where TextKit
            // does (it clamps the box from the descent side), so chips
            // floated ~3pt below their glyphs. Baseline-relative the model is
            // unchanged: the box centre sits at `baseline − (asc + desc)/2`.
            // The layout delegate fires before this paint, so the capture is
            // always populated; the strut model stays as the fallback.
            var rowGlyphs = NSRange()
            _ = manager.lineFragmentRect(
                forGlyphAt: lineCharRange.location, effectiveRange: &rowGlyphs,
                withoutAdditionalLayout: true
            )
            let baseline: CGFloat
            if let engineBaseline = baselines[rowGlyphs.location] {
                // The bounding rect spans the row the glyphs live on, so its
                // origin is the fragment top the offset measures from.
                baseline = engineBaseline
            } else {
                baseline =
                    (bounding.height - (dominant.ascender - dominant.descender)) / 2
                    + dominant.ascender
            }
            let absoluteBaseline = bounding.minY + baseline
            let contentCenter = baseline - (font.ascender + font.descender) / 2
            // The rect is what the decoration layer paints: a padded, ringed
            // box for themes that chip inline code, and the bare mono font
            // box for themes that render it as plain text (VS Code) —
            // exactly what the reference's `code` element rect reports.
            let painted = theme.inlineCodeBackground != nil
            let ring: CGFloat = painted ? EditorMetrics.hairline : 0
            let padding: CGFloat = painted ? EditorMetrics.tiny : 0
            runs.append(
                ChipRun(
                    rect: CGRect(
                        x: xStart - padding - ring,
                        y: bounding.minY + contentCenter - contentHeight / 2
                            - ring,
                        width: xEnd - xStart + (padding + ring) * 2,
                        height: contentHeight + ring * 2
                    ),
                    fontSize: font.pointSize,
                    fontBox: contentHeight,
                    baseline: absoluteBaseline
                )
            )
        }
        return runs
    }

    /// The heading rule's y for one line.
    ///
    /// The reference hangs the border-bottom at the heading's line-box
    /// bottom. For a plain heading that is the strut's extent, expressed off
    /// the engine baseline: `strutY` (the reference's own baseline→rule
    /// distance — see `DecorationPlan.headingRule`). When the heading carries
    /// inline code, the code box reaches below the strut (measured 2pt at h2
    /// size) and the reference's border follows it down — anchoring to the
    /// strut alone would draw the rule straight through the painted chip
    /// (chip bottom 1118.97 vs strut anchor 1115.90 on the fixtures' h2 with
    /// an inline code span). So the rule sits at the lower of the two: the
    /// strut anchor, or the lowest chip's bottom edge plus the reference's
    /// border-to-chip gap (measured 0.3pt: border top 1171.83 over chip box
    /// bottom 1171.53). `chipRects` come in the same space as `strutY`.
    static func headingRuleY(strutY: CGFloat, chipRects: [CGRect]) -> CGFloat {
        guard let lowest = chipRects.map(\.maxY).max() else { return strutY }
        return max(strutY, lowest + 0.3)
    }

    /// Draws one rounded background-and-border box per code block.
    ///
    /// Typora paints a single box around the whole fence (`border: 1px solid
    /// #e7eaed`, `padding-top: 8px; padding-bottom: 6px`), which per-line fills
    /// cannot express: the border would cut through every wrapped line. The box
    /// is the union of the block's *body* lines (`md.codeBody` - the invisible
    /// fence rows are excluded), grown by the theme's painted top/bottom insets
    /// when the first/last body line is on screen.
    @MainActor
    private static func paintCodeBlocks(
        _ lines: [LineFragment], in view: MarkdownTextView, theme: EditorTheme,
        owners: [Int: DecorationPlan]
    ) {
        guard let storage = view.textStorage,
            let context = NSGraphicsContext.current?.cgContext
        else { return }

        struct Accumulator {
            var plan: DecorationPlan
            var rect: NSRect?
            var sawFirst = false
            var sawLast = false
            var owner: Int
            /// The smallest body-row head indent: the container column the
            /// fence's fill hangs from (a fence inside a quote or list item
            /// indents with its container, like the reference's pre).
            var headIndent: CGFloat?
            /// The rows resolve to a blockquote container: the reference's
            /// blockquote carries 1em right padding and its pre paints inside
            /// it, so the fill clamps to that edge.
            var quoteNested = false
        }
        var boxes: [Int: Accumulator] = [:]
        for line in lines {
            // BlockNode ids are unique across the document, so the resolved owner
            // id - the nested fence's own id, else the block's - keys the box.
            let ownerID: Int
            let plan: DecorationPlan
            if let subBlockID = line.subBlockID, let candidate = owners[subBlockID] {
                ownerID = subBlockID
                plan = candidate
            } else if let candidate = owners[line.blockID] {
                ownerID = line.blockID
                plan = candidate
            } else {
                continue
            }
            guard case .codeBlock = plan else { continue }

            var bodyRange = NSRange()
            let isBodyLine =
                storage.attribute(
                    MarkdownAttribute.codeBody, at: line.charRange.location,
                    effectiveRange: &bodyRange
                ) != nil
            var sawFirst = false
            var sawLast = false
            if isBodyLine {
                // `md.codeBody` runs merge across adjacent body lines, so the
                // effective range spans the whole body: the first body line starts
                // it, the last one ends it.
                if line.charRange.location == bodyRange.location { sawFirst = true }
                if NSMaxRange(line.charRange) >= NSMaxRange(bodyRange) { sawLast = true }
            }
            var box = boxes[ownerID] ?? Accumulator(plan: plan, owner: ownerID)
            // The fill spans the block's body rows only. Delimiter rows reach
            // here as their own fragments inside a container (the top-level
            // emitter's rows glue into the boundary and never resolve to the
            // fence), and unioning them grew every container fence's box by
            // their full line height (measured 83.12 against 60.09).
            if isBodyLine {
                box.rect = box.rect.map { $0.union(line.rect) } ?? line.rect
            }
            if !box.quoteNested,
                let containerKind = storage.attribute(
                    MarkdownAttribute.blockKind, at: line.charRange.location,
                    effectiveRange: nil
                ) as? String
            {
                box.quoteNested = containerKind == BlockKind.blockquote.rawValue
            }
            box.sawFirst = box.sawFirst || sawFirst
            box.sawLast = box.sawLast || sawLast
            if isBodyLine {
                // The row's fragment may start with the previous row's glued
                // terminator: probe forward to the row's own first character -
                // the terminator carries the previous row's paragraph, whose
                // head indent is not this row's.
                var probe = line.charRange.location
                let ns = storage.string as NSString
                while probe < NSMaxRange(line.charRange),
                    ns.substring(with: NSRange(location: probe, length: 1)) == "\n"
                {
                    probe += 1
                }
                if probe < NSMaxRange(line.charRange),
                    let rowStyle = storage.attribute(
                        .paragraphStyle, at: probe, effectiveRange: nil
                    ) as? NSParagraphStyle
                {
                    box.headIndent = min(box.headIndent ?? rowStyle.headIndent, rowStyle.headIndent)
                }
            }
            boxes[ownerID] = box
        }

        let inset = view.textContainerInset
        for box in boxes.values {
            guard case let .codeBlock(background, radius, border, topInset, bottomInset) = box.plan,
                var rect = box.rect
            else { continue }
            if box.sawFirst {
                rect.origin.y -= topInset
                rect.size.height += topInset
            }
            if box.sawLast {
                rect.size.height += bottomInset
            }
            // The preview's `pre` content box bottoms out at the inline-block
            // code plus a 1.39pt descent slack, and never below the strut
            // (body line-height 1.6): a single-row block is strut-height, not
            // code-row-height (measured 22.39 / 39.39 / 58.39 for 1/2/3
            // rows). Grow the fill to that at the bottom.
            rect.size.height = max(
                rect.height + 1.39,
                theme.bodyLineHeight * theme.bodyFontSize
            )
            // The fill's left edge is the container column the fence hangs in:
            // the body rows' head indent minus the code padding. A fence inside
            // a quote or list item then indents with its container exactly like
            // the reference's pre. The border ring sits inside the element edge
            // in the reference (`box-sizing: border-box`): the background fills
            // the padding box, 1pt narrower each side than the full-bleed union.
            if let headIndent = box.headIndent {
                // The union spans the full container width; the fill keeps that
                // right edge and takes its left from the container column:
                // width = container right - new left (the old maxX moved with
                // the origin, so `maxX - minX` was a no-op and the box ran past
                // the container's right edge by the whole origin shift). A
                // quote's content box carries 1em right padding in the
                // reference (`blockquote { padding: 0 1em }`) and its pre
                // paints inside it.
                let rightInset = box.quoteNested ? theme.quoteRightPadding : 0
                let containerRight = rect.maxX - rightInset
                rect.origin.x = headIndent - (theme.codePaddingLeft ?? theme.codePadding)
                rect.size.width = containerRight - rect.minX
            }
            rect = rect.insetBy(dx: EditorMetrics.hairline, dy: 0)
            rect = rect.offsetBy(dx: inset.width, dy: inset.height)
            let path = CGPath(
                roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
            )
            context.addPath(path)
            context.setFillColor(background.cgColor)
            context.fillPath()
            if let border {
                context.setStrokeColor(border.cgColor)
                context.setLineWidth(EditorMetrics.hairline)
                context.addPath(path)
                context.strokePath()
            }
        }
    }

    @MainActor
    private static func paint(
        _ plans: [(plan: DecorationPlan, subScoped: Bool)], in view: MarkdownTextView,
        theme: EditorTheme,
        lineRect: NSRect, lineCharRange: NSRange, layout: LayoutOutput, blockID: Int,
        subBlockID: Int? = nil, blockLocation: Int? = nil, paintedLocation: Int? = nil,
        paintFromLocation: Int? = nil
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
            case let .headingRule(color, baselineGap):
                // Under the heading, not across it: the text view is flipped, so the
                // bottom of the line fragment is `maxY`. Anchoring to `minY` drew the
                // rule at the top of the line, straight through the glyphs.
                //
                // And anchoring to `maxY` alone put it in the paragraph's bottom
                // margin: the fragment rect includes the 1rem `paragraphSpacing`,
                // which measured 15pt of air under the ink against the reference's
                // 3–3.5pt. The reference draws the rule at the heading line box's
                // bottom; the engines place the same glyphs at different heights
                // inside an identical box (TextKit clamps from the descent side,
                // Chromium centres the strut), so the rule hangs off the line's real
                // baseline — captured by the layout delegate — by the reference's
                // own baseline→rule distance (`baselineGap`). Missing capture falls
                // back to the old anchor; the dump comparison flags it.
                let strutY = view.markerHider.baselines[lineCharRange.location].map {
                    lineRect.minY + $0 + baselineGap
                } ?? lineRect.maxY - EditorMetrics.hairline
                // The reference's border follows an inline code box down when the
                // heading carries one — see `headingRuleY`.
                let chipRects: [CGRect]
                if let storage = view.textStorage,
                    let manager = view.layoutManager, let container = view.textContainer {
                    chipRects = inlineCodeChipRuns(
                        theme: theme,
                        storage: storage, manager: manager, container: container,
                        lineCharRange: lineCharRange,
                        baselines: view.markerHider.baselines
                    ).map { $0.rect.offsetBy(dx: inset.width, dy: inset.height) }
                } else {
                    chipRects = []
                }
                let ruleY = headingRuleY(strutY: strutY, chipRects: chipRects)
                context.setFillColor(color.cgColor)
                context.fill(
                    CGRect(
                        x: lineRect.minX, y: ruleY,
                        width: lineRect.width, height: EditorMetrics.hairline
                    )
                )
            case let .quoteBar(color, width, inset):
                // `inset` is the bar's x offset from the line's origin: the
                // content edge for a top-level quote, the owning item's text
                // column for one nested inside a list item.
                context.setFillColor(color.withAlphaComponent(EditorMetrics.quoteBarAlpha).cgColor)
                context.fill(
                    CGRect(
                        x: lineRect.minX + inset, y: lineRect.minY,
                        width: width, height: lineRect.height
                    )
                )
            case let .listMarker(text, width, alignment):
                // The marker draws on the one line that contains its own marker run:
                // never on a wrapped fragment, and never on the nested lines an item
                // contains. A nested item's line 0 also merges its owner's plans; the
                // owner's marker run sits on the owner's first line, not here, so the
                // containment test filters it out.
                guard
                    markerIsOnLine(
                        planOrigin: subScoped ? (subBlockID ?? blockID) : blockID,
                        lineCharRange: lineCharRange, in: layout, storage: view.textStorage
                    )
                else { break }
                let geometry = listMarkerGeometry(
                    text: text, width: width, lineRect: lineRect, theme: theme
                )
                context.setFillColor(theme.text.nsColor.cgColor)
                switch geometry.shape {
                case .disc:
                    context.fillEllipse(
                        in: CGRect(
                            x: geometry.center.x - geometry.size / 2,
                            y: geometry.center.y - geometry.size / 2,
                            width: geometry.size, height: geometry.size
                        )
                    )
                case .ring:
                    let lineWidth = min(EditorMetrics.hairline, geometry.lineWidth)
                    let radius = (geometry.size - lineWidth) / 2
                    context.setStrokeColor(theme.text.nsColor.cgColor)
                    context.setLineWidth(lineWidth)
                    context.strokeEllipse(
                        in: CGRect(
                            x: geometry.center.x - radius, y: geometry.center.y - radius,
                            width: radius * 2, height: radius * 2
                        )
                    )
                case .square:
                    context.fill(
                        CGRect(
                            x: geometry.center.x - geometry.size / 2,
                            y: geometry.center.y - geometry.size / 2,
                            width: geometry.size, height: geometry.size
                        )
                    )
                case .text(let glyph):
                    // Anything else - an ordered item's `1.` - stays text,
                    // right-aligned so wide numbers grow leftwards into the indent.
                    drawMarker(
                        glyph, in: lineRect, width: width, alignment: alignment,
                        theme: theme, context: context)
                }
            case let .taskCheckbox(checked, width):
                // One box on the first line: without the guard every fragment
                // of a wrapped item drew its own, while hit-testing only knows
                // the first. The first line is the one carrying the item's own
                // marker run - see `.listMarker`.
                guard
                    markerIsOnLine(
                        planOrigin: subScoped ? (subBlockID ?? blockID) : blockID, lineCharRange: lineCharRange, in: layout,
                        storage: view.textStorage)
                else { break }
                // The reference's checkbox: the browser's 13pt default input,
                // absolutely positioned at the item's top-left with
                // `margin-top: calc(1em - 10px)` - i.e. 6pt below the line box
                // top, right edge 3pt before the text column.
                let side: CGFloat = 13
                // Right edge 3pt before the text column, like the drawn bullets.
                let box = CGRect(
                    x: lineRect.minX + width - side - 3,
                    y: lineRect.minY + 6,
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
            case .codeBlock:
                // Block chrome is painted per block in `paintCodeBlocks`; the
                // per-line fills it replaced cannot express the border or the
                // painted top/bottom padding.
                break
            case let .horizontalRule(color, height):
                context.setFillColor(color.cgColor)
                context.fill(
                    CGRect(
                        x: lineRect.minX, y: lineRect.midY - height / 2,
                        width: lineRect.width, height: height
                    )
                )
            case let .inlineCode(background, radius):
                // A nil background = the theme renders inline code as bare
                // text (VS Code): the plan only drives the headless dump's
                // chip export.
                guard let background,
                    let storage = view.textStorage,
                    let manager = view.layoutManager, let container = view.textContainer,
                    !isPainted(lineCharRange, in: view)
                else { break }
                for chip in inlineCodeChipRuns(
                    theme: theme,
                    storage: storage, manager: manager, container: container,
                    lineCharRange: lineCharRange,
                    baselines: view.markerHider.baselines
                ) {
                    // Chip rects are in container coordinates; the line rects the
                    // decorator paints are already offset into the view, so the chip
                    // follows them (see `inlineImageOrigin`).
                    let rect = chip.rect.offsetBy(dx: inset.width, dy: inset.height)
                    let path = CGPath(
                        roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                        transform: nil
                    )
                    context.setFillColor(background.cgColor)
                    context.addPath(path)
                    context.fillPath()
                    if let border = theme.codeBorder?.nsColor {
                        context.setStrokeColor(border.cgColor)
                        context.setLineWidth(EditorMetrics.hairline)
                        context.addPath(path)
                        context.strokePath()
                    }
                }
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
                guard let paintedLocation = paintedLocation,
                    isPainted(NSRange(location: paintedLocation, length: 1), in: view)
                else { break }
                // Once per block, from its first line. NOTE: a paintFrom
                // discriminator (the tallest fragment containing the first
                // painted character) passed its guard and paintTable still drew
                // nothing at every width — the painted rows vanished. Reverted
                // to `isBlockStart`; the double-paint ink excess is the known
                // 14-18% visual flag pending a correct discriminator.
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
                        .paragraphStyle,
                        at: blockLocation ?? lineCharRange.location, effectiveRange: nil
                    ) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
                print(
                    "PAINTTABLE blk=\(blockID) sub=\(subBlockID ?? -1) top=\(lineRect.minY + margin) "
                        + "left=\(lineRect.minX) w=\(grid.totalWidth) rows=\(grid.rowHeights)"
                )
                paintTable(
                    grid, top: lineRect.minY + margin, left: lineRect.minX + grid.textColumn,
                    width: grid.totalWidth, theme: theme, context: context
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
                guard let paintedLocation = paintedLocation,
                    isPainted(NSRange(location: paintedLocation, length: 1), in: view)
                else { break }
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
    static func isPainted(_ range: NSRange, in view: MarkdownTextView) -> Bool {
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
    static func markerIsOnLine(
        planOrigin: Int, lineCharRange: NSRange, in layout: LayoutOutput,
        storage: NSTextStorage?
    ) -> Bool {
        guard let marker = layout.markers.first(where: { $0.blockID == planOrigin }) else {
            return false
        }
        // The first *visible* character after the marker run is the item's content;
        // every hidden character between the marker and that content (a link's `[`,
        // a task's `[x] `) is zero-width and glues backwards into whatever fragment
        // precedes the content, so scanning to the first non-hidden character is
        // what keeps the chrome on the row the content actually sits on.
        var location = NSMaxRange(marker.range)
        if let storage {
            while location < storage.length, MarkdownAttribute.isHidden(storage, at: location) {
                location += 1
            }
        }
        return NSLocationInRange(location, lineCharRange)
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

        context.setLineWidth(EditorMetrics.hairline)
        for (index, separatorY) in tops.dropFirst().enumerated() {
            // `tbody tr + tr td { border-top: 1px }` in the preview's gray;
            // the header's own border-bottom is the darker `th` rule.
            context.setStrokeColor(
                (index == 0 ? theme.tableHeaderBorder : theme.tableBorder).nsColor.cgColor
            )
            context.move(to: CGPoint(x: box.minX, y: separatorY))
            context.addLine(to: CGPoint(x: box.maxX, y: separatorY))
            context.strokePath()
        }

        for (rowIndex, cells) in grid.rows.enumerated() {
            let rowTop = tops[rowIndex]
            let bandHeight = grid.rowHeights[rowIndex]
            let rowFont = rowIndex == 0 ? grid.headerFont : grid.font
            let monoFlags = rowIndex < grid.cellMono.count ? grid.cellMono[rowIndex] : []
            for (column, cell) in cells.enumerated() where !cell.isEmpty {
                guard column < grid.columnCount else { break }
                let alignment = column < grid.alignments.count ? grid.alignments[column] : .left
                let style = TableGrid.wrapStyle(lineHeight: grid.rowHeight)
                style.alignment = alignment
                let cellFont = column < monoFlags.count && monoFlags[column]
                    ? grid.monoFont : rowFont
                let run = NSAttributedString(
                    string: cell,
                    attributes: [.font: cellFont, .foregroundColor: grid.color, .paragraphStyle: style]
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
            // The reference renders `table.frontmatter` with the full cell
            // grid (`th, td { border: 1px solid }` at the 6px 13px padding).
            let rowBorder = CGRect(x: left, y: cursor, width: width, height: height)
            context.saveGState()
            context.setStrokeColor(theme.tableBorder.nsColor.cgColor)
            context.setLineWidth(EditorMetrics.hairline)
            context.stroke(rowBorder)
            context.restoreGState()
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
            // The key/value column separator, per the reference's two cells.
            context.setStrokeColor(theme.tableBorder.nsColor.cgColor)
            context.setLineWidth(EditorMetrics.hairline)
            context.move(to: CGPoint(x: left + keyWidth, y: cursor))
            context.addLine(to: CGPoint(x: left + keyWidth, y: cursor + height))
            context.strokePath()
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
