import AppKit
import Foundation

/// Collapses syntax markers to zero width.
///
/// ## Why a delegate at all
///
/// TextKit has no `display: none`. Marker characters must stay in the buffer -
/// the buffer *is* the markdown - so they can only be made invisible, and the
/// invisible ones must not consume horizontal space either. Attributes alone
/// cannot do that: negative kerning is clamped at run boundaries, and a tiny font
/// leaves a visible gap (measured at 35-72% of the marker width).
///
/// `GlyphProperty.null` in `layoutManager(_:shouldGenerateGlyphs:...)` removes
/// the glyph *and* its advance. Measured on a 31-unit sample: a marker run of
/// 1, 2, 3 or 4 characters, and multi-character runs like `](`, all collapse to
/// exactly 0.00pt while the characters remain in the string.
///
/// ## The one hard constraint
///
/// Glyph properties are generated once and cached forever. None of
/// `invalidateLayout(forCharacterRange:)`, `invalidateDisplay` or
/// `beginEditing`/`endEditing` re-invokes the delegate. The *only* thing that
/// regenerates glyphs is an attribute change on the affected range.
///
/// That is why the hidden flag lives in the text storage as `md.hidden` rather
/// than in this object: revealing the markers of the inline element under the
/// caret is expressed as an attribute flip, which both regenerates the glyphs and
/// keeps this delegate stateless. A mutable `hiddenRanges` set here would drift
/// out of sync with the cache and silently stop working.
final class MarkerHider: NSObject, NSLayoutManagerDelegate {
    /// The gap below a list-item row (`li p { margin: .5rem 0 }` in the original's
    /// base style). Set by the text view whenever the theme changes.
    ///
    /// It reaches the layout through this delegate rather than through the items'
    /// paragraph style on purpose: the items' hidden marker glyphs are zero-width
    /// and glue backwards into the previous line fragment, so an item paragraph's
    /// first line fragment is the *previous* item's row - and TextKit drops both
    /// the paragraph's own `spacingBefore` and the previous paragraph's
    /// `spacingAfter` at that glued boundary. The delegate is asked per row, after
    /// the layout knows exactly where the row ends, which is why the gap survives
    /// here.
    var listItemSpacing: CGFloat = 0
    /// The blockquote's own margin (`blockquote { margin: 0.8em 0 }`), applied
    /// when a row hands over to the next quote level: the levels are glued into
    /// one paragraph, so the margin between them reaches the layout through
    /// this delegate - same trick as the item spacing.
    var quoteLevelSpacing: CGFloat = 0
    /// The quote paragraph's bottom margin (`p { margin-bottom: 16px }`):
    /// the blank strut between a quote's paragraphs glues away its own margin
    /// (measured: the paragraphs land contiguously), so the paragraph margin
    /// reaches the layout through this delegate — same trick as the item
    /// spacing.
    var quoteParagraphSpacing: CGFloat = 0

    /// The layout engine's own baseline offset, per line fragment, keyed by
    /// the line's first character location.
    ///
    /// Captured from `shouldSetLineFragmentRect`: with a fixed line height
    /// (`min == max`, the heading styles) TextKit clamps the line box from the
    /// descent side, so the real baseline depends on the fonts actually on the
    /// line — including CJK fallback faces the text storage never names
    /// (PingFang descends 0.333em where Open Sans descends 0.293em, a 1pt
    /// swing at h1 size). No public API hands that number back after the fact,
    /// so it is recorded as the layout happens. The offset measures from the
    /// fragment rect's top, paragraph spacing included (verified: a heading
    /// with `spacingBefore` 16 reports 16 + the box offset).
    ///
    /// The one mutable cache in this class, and safe: entries are keyed by
    /// glyph location and refreshed whenever TextKit re-lays that line — the
    /// same lifetime as TextKit's own glyph/fragment caches. Lines before an
    /// edit keep their location and their offset; lines after it re-layout and
    /// overwrite. Never cleared on invalidation: a partial re-layout would
    /// drop baselines for lines that will not re-fire.
    private(set) var baselines: [Int: CGFloat] = [:]

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard glyphRange.length > 0 else { return 0 }
        guard let storage = layoutManager.textStorage, storage.length > 0 else { return 0 }

        // TextKit 1 generates one glyph per UTF-16 code unit and hands us strictly
        // increasing, non-repeating character indexes, so reading the attribute
        // per glyph is exact even for surrogate pairs and combining sequences.
        let hiddenFlag = MarkdownAttribute.hidden
        var modified = [NSLayoutManager.GlyphProperty](
            repeating: [], count: glyphRange.length
        )
        var touched = false
        for offset in 0..<glyphRange.length {
            let location = charIndexes[offset]
            guard location < storage.length else {
                modified[offset] = props[offset]
                continue
            }
            let value = storage.attribute(
                hiddenFlag, at: location, effectiveRange: nil
            )
            if value as? Bool == true {
                modified[offset] = props[offset].union(.null)
                touched = true
            } else {
                modified[offset] = props[offset]
            }
        }
        guard touched else { return 0 }

        modified.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            layoutManager.setGlyphs(
                glyphs, properties: base, characterIndexes: charIndexes,
                font: aFont, forGlyphRange: glyphRange
            )
        }
        return glyphRange.length
    }

    /// Records the engine's proposed baseline for each line (see `baselines`).
    /// Returning `true` keeps the proposed values — layout is untouched.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        baselines[glyphRange.location] = baselineOffset.pointee
        return true
    }

    /// The gap below a list-item row.
    ///
    /// The row's last content character carries `md.blockKind` for the row's own
    /// block (the trailing newline carries none), so the kind read there - or one
    /// glyph back, when the row ends in something glyph-less - decides whether
    /// this is an item row.
    ///
    /// Two rows must NOT receive the spacing:
    ///
    /// - A collapsed boundary row (the backfill newline that starts the list's
    ///   paragraph, proposed at the strut's ~0 height). Spacing there pushed the
    ///   first item `listItemSpacing` below the block's margin edge - visible as
    ///   an extra gap between the heading and the list that Typora does not have
    ///   (16pt measured vs 25.4pt before the fix).
    /// - The list's LAST row. The next characters belong to a different block
    ///   (the following heading's or paragraph's boundary backfill), so the
    ///   item margin must not stack on top of the next block's own spacing -
    ///   CSS collapses those margins, TextKit would add them.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        lineSpacingAfterGlyphAt glyphIndex: Int,
        withProposedLineFragmentRect rect: NSRect
    ) -> CGFloat {
        guard let storage = layoutManager.textStorage,
            storage.length > 0
        else { return 0 }
        // A ruled heading's rows (see `BlockStyle.heading`): the style's
        // after-spacing assumes the attribute face's descent — the largest a
        // heading row mixes on the system stack. A row whose first visible
        // glyph's face descends less (a CJK heading: the substituted
        // PingFang UI face) gets the difference handed back here, so the
        // rule→content distance stays the preview's `margin + 1` (the
        // collapsed margin below the border) for every heading regardless of
        // script. Additive-only by engine constraint — TextKit clamps
        // negative returns (measured) — which is why the style assumes the
        // larger descent and this corrects upward. The row's fonts are read
        // instead of the captured baseline: this delegate fires BEFORE
        // `shouldSetLineFragmentRect` for the same row (measured), so the
        // baseline map is empty here — but glyph generation has already
        // substituted the fallback face into the storage's font attribute,
        // which is exactly what the descent depends on. Only the row before
        // other blocks gets it: a wrapped heading's earlier rows must not
        // space themselves apart.
        if let rowChars = ruledHeadingRowChars(layoutManager, glyphIndex: glyphIndex, storage: storage) {
            // A later row of the same heading follows: no spacing between them.
            let next = NSMaxRange(rowChars)
            if next < storage.length,
                storage.attribute(MarkdownAttribute.headingRuleGap, at: next, effectiveRange: nil) != nil
            {
                return 0
            }
            guard
                storage.attribute(
                    MarkdownAttribute.headingRuleGap, at: rowChars.location, effectiveRange: nil
                ) != nil
            else { return 0 }
            // The engine clamps the fixed line height with the descent of the
            // row's first visible glyph's face — the CJK fallback face when
            // the row opens with CJK (glyph generation has already
            // substituted it into the font attribute), the attribute face
            // otherwise. The style's after-spacing assumed the attribute
            // face; hand back the difference when the actual face descends
            // less, so the rule→content distance stays `margin + 1` for
            // every script. Additive-only: TextKit clamps negative returns
            // (measured), and the attribute face is the stack's largest
            // descent, so the correction only ever adds.
            // The engine clamps the fixed line height with the LARGEST
            // descent among the row's visible runs (the hidden markers do not
            // count — measured across pure-CJK, Latin and chip-bearing
            // heading rows).
            var visibleDesc: CGFloat = 0
            storage.enumerateAttribute(.font, in: rowChars, options: []) { value, range, _ in
                guard let font = value as? NSFont else { return }
                if storage.attribute(
                    MarkdownAttribute.hidden, at: range.location, effectiveRange: nil
                ) as? Bool != true {
                    visibleDesc = max(visibleDesc, -font.descender)
                }
            }
            let firstVisibleDesc: CGFloat? = visibleDesc > 0 ? visibleDesc : nil
            // The attribute face's descent rides the row's own attributes (the
            // hidden marker runs carry the heading's base, so the first
            // character has it): reconstructing it from the row's fonts would
            // drag in substituted/chip faces instead.
            let attrDesc = storage.attribute(
                MarkdownAttribute.headingRuleAttrDesc,
                at: rowChars.location, effectiveRange: nil
            ) as? CGFloat
            guard let firstVisibleDesc, firstVisibleDesc > 0, let attrDesc, attrDesc > 0
            else { return 0 }
            return max(0, attrDesc.rounded() - firstVisibleDesc.rounded())
        }
        guard listItemSpacing > 0 else { return 0 }
        func kind(at location: Int) -> String? {
            guard location >= 0, location < storage.length else { return nil }
            return storage.attribute(MarkdownAttribute.blockKind, at: location, effectiveRange: nil)
                as? String
        }
        // A collapsed blank row (a bare `>` line between a quote's paragraphs,
        // a container's boundary hairline) renders no row; the margin it stands
        // in for reaches the layout here. The row's own kind decides whose
        // margin it is: a quote's blank line carries the quote's paragraph
        // margin, a list's blank line the item spacing (a boundary hairline
        // between top-level blocks carries the next block's spacing on its own
        // paragraph style, so it stays flat here).
        if rect.height <= 1 {
            // A collapsed boundary row is not a rendered row - never space
            // after it: the boundary's own paragraph style carries the next
            // block's collapsed margin, and a list's blank rows take the item
            // spacing from the row before them.
            return 0
        }
        // A container-nested code block's rows carry the CONTAINER's block kind
        // (the visual owner: a list item), so the kind check below reads them
        // as item rows and spacing was applied to every code line (measured
        // 32.4pt pitch inside a list-item fence against 23.04). The sub-kind is
        // the row's own scope: code rows manage their own line height.
        if let sub = storage.attribute(
            MarkdownAttribute.subKind,
            at: min(glyphIndex, storage.length - 1),
            effectiveRange: nil
        ) as? String, sub == BlockKind.fences.rawValue
            || sub == BlockKind.indentedCode.rawValue
            || sub == BlockKind.htmlBlock.rawValue
            || sub == BlockKind.mathBlock.rawValue
        {
            return 0
        }
        // Don't apply the item spacing when the next content is a container-
        // nested code block: the code manages its own line height and the fill's
        // top chrome provides the gap. The lookahead finds the code's subKind
        // within the boundary region after this row's last glyph.
        var codeAhead = false
        var codeOffset = 1
        while codeOffset <= 12, glyphIndex + codeOffset < storage.length {
            if let sub = storage.attribute(
                MarkdownAttribute.subKind,
                at: glyphIndex + codeOffset, effectiveRange: nil
            ) as? String, sub == BlockKind.fences.rawValue
                || sub == BlockKind.indentedCode.rawValue
                || sub == BlockKind.htmlBlock.rawValue
                || sub == BlockKind.mathBlock.rawValue
            {
                codeAhead = true
                break
            }
            codeOffset += 1
        }
        if codeAhead { return 0 }
        // The item row itself: the row's last glyph, or one glyph back when the
        // row ends in something glyph-less.
        let listKinds: Set<String> = [BlockKind.listItem.rawValue, BlockKind.taskItem.rawValue]
        let rowKind = [min(glyphIndex, storage.length - 1), glyphIndex - 1]
            .compactMap { kind(at: $0) }.first
        // A quote level handover: the levels are glued into one paragraph, so
        // the blockquote margin between them comes from here. The row's own
        // content carries its level's `md.subBlock`; the first character shortly
        // after the row that carries a DIFFERENT sub is the next row handing
        // over to another level. The margin only belongs between the two when
        // the handover is direct:
        //
        // - A blank row between (a bare `>` line) lays out its own strut at
        //   exactly the quote margin - spacing here doubled every level gap
        //   crossed by a blank line (measured 51.2pt pitch vs 38.4). Two row
        //   breaks between the row and the handover char mean a strut sits
        //   between.
        // - A different `md.block` means the next row belongs to another
        //   block entirely (the next quote after this one): the boundary
        //   backfill between blocks already carries the collapsed margin.
        if rowKind == BlockKind.blockquote.rawValue, quoteLevelSpacing > 0 {
            func subBlock(at location: Int) -> Int? {
                guard location >= 0, location < storage.length else { return nil }
                return storage.attribute(MarkdownAttribute.subBlock, at: location, effectiveRange: nil)
                    as? Int
            }
            func blockID(at location: Int) -> Int? {
                guard location >= 0, location < storage.length else { return nil }
                return storage.attribute(MarkdownAttribute.block, at: location, effectiveRange: nil)
                    as? Int
            }
            func character(at location: Int) -> Character? {
                guard location >= 0, location < storage.length else { return nil }
                return (storage.string as NSString).substring(with: NSRange(location: location, length: 1))
                    .first
            }
            let probe = min(glyphIndex, storage.length - 1)
            let own = subBlock(at: probe)
            let ownBlock = blockID(at: probe)
            // Walk to the first differently-scoped character, counting row
            // breaks (`\r\n` counts once: only the `\n` is counted). The window
            // must span a row terminator plus a deep level's marker prefix.
            var handover: Int?
            var rowBreaks = 0
            var lookahead = 1
            while handover == nil, lookahead <= 16, glyphIndex + lookahead < storage.length {
                let at = glyphIndex + lookahead
                if let block = blockID(at: at), block != ownBlock { break }
                if let sub = subBlock(at: at), sub != own {
                    handover = at
                } else if character(at: at) == "\n" {
                    rowBreaks += 1
                }
                lookahead += 1
            }
            if handover != nil, rowBreaks == 1 {
                return quoteLevelSpacing
            }
            // A paragraph boundary inside the quote level: the blank strut
            // between the paragraphs glues away its own margin (measured: the
            // paragraphs land contiguously), so the paragraphs' `p
            // { margin-bottom }` reaches the layout here — two row breaks
            // (the boundary blank) and then the same scope again. A single
            // break is a soft-wrapped row of the same paragraph: no spacing;
            // a different block after the breaks is the quote's end (its own
            // zero bottom margin handles it).
            if handover == nil, rowKind == BlockKind.blockquote.rawValue {
                var boundaryBreaks = 0
                var boundaryLookahead = 1
                var boundaryLog: [String] = []
                while boundaryLookahead <= 16, glyphIndex + boundaryLookahead < storage.length {
                    let at = glyphIndex + boundaryLookahead
                    if let block = blockID(at: at), block != ownBlock {
                        boundaryLog.append("block\(block)@\(at)")
                        break
                    }
                    let chOpt = character(at: at)
                    if chOpt == "\n" { boundaryBreaks += 1 }
                    let subAt = subBlock(at: at)
                    let ch = chOpt.map(String.init) ?? "?"
                    boundaryLog.append("ch\(ch)sub=\(subAt ?? -1)b\(boundaryBreaks)")
                    if boundaryBreaks >= 2, let sub = subBlock(at: at), sub == own {
                        return quoteParagraphSpacing
                    }
                    boundaryLookahead += 1
                }
            }
        }
        guard
            [min(glyphIndex, storage.length - 1), glyphIndex - 1].contains(where: {
                kind(at: $0).map(listKinds.contains) == true
            })
        else { return 0 }
        // The list's last row: ahead of it the next block's boundary backfill
        // carries a non-list kind (a few characters in, past the backfill
        // newline and the row's own glued hidden markers).
        let lookahead = max(glyphIndex - 1, 0)...min(glyphIndex + 6, storage.length - 1)
        for location in lookahead where location > glyphIndex {
            if let ahead = kind(at: location), !listKinds.contains(ahead) { return 0 }
        }
        return listItemSpacing
    }

    /// TEMPORARY round-1 debug: the ruled-heading correction path, appended
    /// to /tmp/ruled-debug.txt during parity iterations.
    /// The character range of this row when it belongs to a ruled heading
    /// (carries `md.headingRuleGap`), else nil.
    ///
    /// The row's characters are walked straight off the storage text — back
    /// from the row's last glyph to the previous line terminator — because
    /// this fires mid-layout, where `characterRange(forGlyphRange:)` answers
    /// from a fragment cache that is still in flux and hands back ranges that
    /// span whole paragraphs (measured: `{0, 64}` for an 8-character heading).
    private func ruledHeadingRowChars(
        _ layoutManager: NSLayoutManager, glyphIndex: Int, storage: NSTextStorage
    ) -> NSRange? {
        let ns = storage.string as NSString
        let last = min(glyphIndex, storage.length - 1)
        guard ns.character(at: last) != 0x0A, ns.character(at: last) != 0x0D else {
            return nil
        }
        var start = last
        while start > 0 {
            let previous = ns.character(at: start - 1)
            if previous == 0x0A || previous == 0x0D { break }
            start -= 1
        }
        let rowChars = NSRange(location: start, length: last - start + 1)
        guard storage.attribute(
            MarkdownAttribute.headingRuleGap, at: rowChars.location, effectiveRange: nil
        ) != nil
        else { return nil }
        return rowChars
    }
}

/// Reads and flips `md.hidden`, and finds the caret's enclosing inline element.
///
/// This is the whole of the original's `md-expand` behaviour, and it needs no text
/// mutation: revealing markers is an attribute change on the storage, which is
/// outside the undo stack.
struct MarkerVisibility {
    private let storage: NSTextStorage
    private let layout: LayoutOutput

    init(storage: NSTextStorage, layout: LayoutOutput) {
        self.storage = storage
        self.layout = layout
    }

    /// The inline elements whose markers should be visible for a selection.
    ///
    /// The original reveals the element containing the caret, plus every ancestor of it,
    /// so `**bold with *em* inside**` shows both layers when the caret is in `em`.
    func visibleInlineIndices(for range: NSRange) -> Set<Int> {
        let location = min(range.location, max(storage.length - 1, 0))
        var indices = Set(layout.inlineChain(at: location).map(\.index))
        if range.length > 1 {
            // A multi-line or multi-element selection shows the syntax of
            // everything it touches - the original's `md-expand-on-selection`.
            var position = range.location
            while position < NSMaxRange(range) {
                if let element = layout.inlineElement(containing: position) {
                    indices.insert(element.index)
                }
                position += 1
            }
        }
        return indices
    }

    /// Applies the reveal/hide state for a selection.
    ///
    /// Returns the ranges whose attribute changed, so the caller can invalidate
    /// just those - an attribute change is what makes TextKit regenerate the
    /// glyphs, and TextKit only does that for the range that changed.
    @discardableResult
    func apply(for range: NSRange) -> [NSRange] {
        let visible = visibleInlineIndices(for: range)
        var changed: [NSRange] = []
        storage.beginEditing()
        for marker in layout.markers {
            let isInline = marker.inlineIndex.map { visible.contains($0) } ?? false
            let shouldHide = !isInline
            guard marker.range.length > 0, marker.range.location < storage.length else { continue }
            let current =
                storage.attribute(
                    MarkdownAttribute.hidden, at: marker.range.location, effectiveRange: nil
                ) as? Bool
            guard current != shouldHide else { continue }
            let target = clamp(marker.range)
            storage.addAttribute(MarkdownAttribute.hidden, value: shouldHide, range: target)
            changed.append(target)
        }
        storage.endEditing()
        return changed
    }

    private func clamp(_ range: NSRange) -> NSRange {
        let location = max(0, min(range.location, storage.length))
        let length = max(0, min(range.length, storage.length - location))
        return NSRange(location: location, length: length)
    }
}
