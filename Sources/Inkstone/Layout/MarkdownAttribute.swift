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

    /// `md.subBlock` - the `BlockNode.id` of a block whose lines sit inside a list
    /// item's own line range: a nested list, a quote, a code fence, a second
    /// paragraph. `md.block` keeps naming the owning item, so focus, reparse and
    /// painted-block reveal all see one block exactly as before; the decoration
    /// layer scopes the nested block's chrome (bullet, quote bar, code background)
    /// to the lines that carry this key instead.
    static let subBlock = NSAttributedString.Key("md.subBlock")

    /// Marks the *body* lines of a code block - the lines between the hidden
    /// fence delimiters. The decorator unions these lines to draw the block's
    /// background and border as one rounded box, so the invisible fence rows do
    /// not stretch the chrome or receive its padding.
    static let codeBody = NSAttributedString.Key("md.codeBody")

    /// Marks inline-code runs. The native background attribute hugs the glyphs;
    /// the decorator repaints the run's enclosing rects with the theme's
    /// `code, tt` chrome: horizontal padding and the 1px border.
    static let codeRun = NSAttributedString.Key("md.codeRun")

    /// Reads the hidden flag at `location` in an O(1)-amortised way.
    static func isHidden(_ text: NSAttributedString, at location: Int) -> Bool {
        guard location >= 0, location < text.length else { return false }
        return text.attribute(hidden, at: location, effectiveRange: nil) as? Bool == true
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
}

/// One inline element's range in the produced string.
struct InlineRange {
    let index: Int
    let kind: InlineKind
    let range: NSRange
    let blockID: Int
    /// The element's span in the block's *plain text* (the text `NodeSearch`
    /// matches), or a zero range when the element carries none.
    var plainRange = NSRange(location: 0, length: 0)
    /// Where the plain content sits in the buffer, so a plain-text offset can be
    /// translated into a buffer range without guessing from syntax widths.
    var contentRange = NSRange(location: 0, length: 0)
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
    case codeOpen
    case codeClose
    case codeFence
    case linkOpen
    case linkClose
    case imageOpen
    case imageClose
    case footnoteOpen
    case footnoteClose
    case mathDelimiter
    /// An emoji shortcode's colons and name: hidden while idle, revealed with
    /// the element under the caret like every other inline delimiter.
    case emoji

    /// Whether the marker is hidden while the caret is elsewhere.
    ///
    /// Every block marker hides: its visual is a drawn affordance (bullet,
    /// synthesised number, checkbox, rule), never the source characters. An
    /// ordered list's `1.` is drawn by the decoration layer (`.listMarker`), so
    /// the buffer's digits collapse to zero width exactly like a bullet's dash -
    /// which is also what lines the item's text up on the text column no matter
    /// how wide the number is. Inline delimiters hide too and are revealed under
    /// the caret. (`horizontalRule` is never attached to a run today; the
    /// thematic break hides through `emitHidden`.)
    var isHiddenWhenIdle: Bool { self != .horizontalRule }
}

/// Where and how wide the document is laid out.
struct LayoutContext {
    var containerWidth: CGFloat
    /// Folder relative image paths resolve against. Set by the editor so `Layout/` does
    /// not have to know which document it is laying out.
    var imageBaseDirectory: URL?
    /// Image size lookup served from the editor's decode cache, so a resize-driven
    /// relayout does not re-decode every image on the main thread.
    var imageSize: ((String) -> CGSize)?
    /// Largest width an inline image may occupy; mirrors the painter's cap so the
    /// layout pass and the painter agree.
    var imageMaxWidth: CGFloat = 480
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
