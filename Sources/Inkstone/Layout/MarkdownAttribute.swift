import AppKit
import Foundation

/// Custom attributes the layout pass writes into the text storage.
///
/// The renderer needs to carry structural information that no standard attribute
/// can express, and the editor needs to read it back without re-parsing.
enum MarkdownAttribute {
    /// `md.block` - the `BlockNode.id` this range belongs to. Lets the editor
    /// find the focused block from a caret offset in one step.
    static let block = NSAttributedString.Key("md.block")

    /// `md.marker` - index into `LayoutOutput.markers`. Holds the verbatim
    /// marker text and its role, which the renderer and the zero-width hider both
    /// need. An integer rather than the struct itself: attribute values get boxed
    /// and compared constantly, and this keeps the comparison free.
    static let marker = NSAttributedString.Key("md.marker")

    /// `md.hidden` - when true the marker takes no width and is not drawn.
    ///
    /// This is the switch behind the original's `md-expand`: setting it to false on the
    /// markers of the inline element under the caret makes them appear in place
    /// without touching the text. See `MarkerHider` for why it has to be an
    /// attribute rather than delegate state.
    static let hidden = NSAttributedString.Key("md.hidden")

    /// `md.inline` - index into `LayoutOutput.inlineNodes`, identifying the
    /// inline element a range belongs to.
    static let inline = NSAttributedString.Key("md.inline")

    /// `md.blockKind` - the block kind's raw value, so the editor can decide how to
    /// present a block without walking the node tree.
    static let blockKind = NSAttributedString.Key("md.blockKind")

    /// `md.rawblock` - marks a block that the original renders as a panel and shows as
    /// source when focused. The editor uses it to drive the mode switch.
    static let rawBlock = NSAttributedString.Key("md.rawblock")

    /// `md.searchHit` - a find-replacement match range, drawn by the decoration
    /// layer. Attribute-only, so it never enters the undo stack.
    static let searchHit = NSAttributedString.Key("md.searchHit")

    /// `md.painted` - the block's text carries no visible glyphs because the
    /// decoration layer draws the block instead.
    ///
    /// Set on pipe tables. Focus flips it off for the focused block, which brings the
    /// original source text back verbatim - the buffer never changed either way, so
    /// the caret stays where the user put it and saving writes what they typed.
    static let painted = NSAttributedString.Key("md.painted")

    /// `md.blockDepth` - nesting depth, so the decoration layer can indent gutter
    /// decorations without walking the tree.
    static let blockDepth = NSAttributedString.Key("md.blockDepth")

    /// Reads the hidden flag at `location` in an O(1)-amortised way.
    static func isHidden(_ storage: NSTextStorage, at location: Int) -> Bool {
        guard location >= 0, location < storage.length else { return false }
        return storage.attribute(MarkdownAttribute.hidden, at: location, effectiveRange: nil) as? Bool == true
    }
}

/// One marker occurrence in the buffer.
struct MarkerOccurrence {
    let index: Int
    /// The verbatim marker text.
    let text: String
    /// Range in the produced string.
    let range: NSRange
    /// Index of the block the marker belongs to.
    let blockID: Int
    /// Index of the inline element, when the marker is part of one.
    let inlineIndex: Int?

    /// Whether the marker is shown while the caret is elsewhere.
    ///
    /// The original hides block markers entirely (they are represented by CSS
    /// `list-style`, the quote border or a drawn rule) and reveals inline markers
    /// only for the element under the caret.
    var isInline: Bool { inlineIndex != nil }
}

/// One inline element's range in the produced string.
struct InlineRange {
    let index: Int
    let kind: InlineKind
    let range: NSRange
    let blockID: Int
}

/// One block's range in the produced string.
struct BlockRange {
    let id: Int
    let kind: BlockKind
    /// The block's full extent, including its own text but not the blank lines
    /// that separate it from the previous block.
    let range: NSRange
    let sourceOffset: Int
}

/// Everything the layout pass produced, alongside the attributed string.
struct LayoutOutput {
    var attributed: NSAttributedString
    var blocks: [BlockRange] = []
    var inlineNodes: [InlineRange] = []
    var markers: [MarkerOccurrence] = []
    /// Drawing instructions, keyed by block id.
    var decorations: [Int: [DecorationPlan]] = [:]

    func block(containing location: Int) -> BlockRange? {
        blocks.last { $0.range.contains(location) }
    }

    func inlineElement(containing location: Int) -> InlineRange? {
        inlineNodes.last { $0.range.contains(location) }
    }

    /// The innermost inline elements containing `location`, outermost first.
    func inlineChain(at location: Int) -> [InlineRange] {
        inlineNodes.filter { $0.range.contains(location) }
    }

    /// Marker ranges whose element is in `chain` and whose delimiter role is
    /// `role`. Used by the editor to reveal exactly one element's syntax.
    func markerRanges(inlineIndices: Set<Int>, roles: Set<MarkerRole>) -> [NSRange] {
        markers.compactMap { marker in
            guard let inline = marker.inlineIndex, inlineIndices.contains(inline) else {
                return nil
            }
            guard marker.range.length > 0 else { return nil }
            return marker.range
        }
    }
}

/// The kinds of syntax marker, mirroring the original's `md-meta` spans.
enum MarkerRole {
    // Block-level: never shown inline; represented by a drawn affordance.
    case headingHash
    case bullet
    case orderedNumber
    case taskCheckbox
    case quoteMark
    case fenceDelimiter
    case tablePipe
    case tableDelimiterRow
    case frontMatterFence
    case tocToken
    case horizontalRule
    // Inline-level: revealed when the caret is inside the element.
    case emphasisOpen
    case emphasisClose
    case strongOpen
    case strongClose
    case strikethrough
    case highlight
    case `subscript`
    case superscript
    case codeFence
    case linkOpen
    case linkClose
    case imageOpen
    case imageClose
    case footnoteOpen
    case footnoteClose
    case mathDelimiter

    /// Whether the marker is hidden while the caret is elsewhere.
    ///
    /// `orderedNumber` and `horizontalRule` are the two exceptions: an ordered
    /// list's `1.` is synthesised at render time rather than read from the buffer,
    /// and a horizontal rule is drawn.
    var isHiddenWhenIdle: Bool { self != .orderedNumber && self != .horizontalRule }
}

/// Where and how wide the document is laid out.
struct LayoutContext {
    var containerWidth: CGFloat
    var isExport = false
    /// Folder relative image paths resolve against. Set by the editor so `Layout/` does
    /// not have to know which document it is laying out.
    var imageBaseDirectory: URL?
    /// Renders every marker as visible. Source mode and copy-as-markdown use it.
    var showsAllMarkers = false
}
extension Dictionary where Key == NSAttributedString.Key, Value == Any {
    /// Layers `other` over the receiver, preferring `other`'s value.
    ///
    /// `Dictionary.merge` is the mutating form and returns `Void`; the layout pass
    /// needs the non-mutating one, which is `merging`.
    func merged(_ other: Self) -> Self {
        merging(other) { _, new in new }
    }
}
