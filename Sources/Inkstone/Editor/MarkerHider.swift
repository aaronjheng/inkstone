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
