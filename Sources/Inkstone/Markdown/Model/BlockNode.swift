import Foundation

/// The kinds of block-level Markdown syntax.
///
/// Mirrors the original's `NodeDef.TYPE` so behaviour can be diffed construct by
/// construct against the original.
public enum BlockKind: String, Hashable, Sendable {
    case frontMatter
    case heading
    case paragraph
    case blockquote
    case list
    case listItem
    case taskItem
    case fences
    case indentedCode
    case mathBlock
    case htmlBlock
    case table
    case hr
    case toc
    case linkDefinition
    case footnoteDefinition
    case emptyLine

    /// Whether the block is drawn as a single attachment character in the text
    /// buffer, with its source regenerated on demand. Only these kinds need a
    /// serializer; everything else is byte-faithful by construction because the
    /// buffer *is* the markdown.
    var isAttachmentRendered: Bool {
        switch self {
        case .table, .mathBlock, .htmlBlock, .toc:
            return true
        case .frontMatter, .heading, .paragraph, .blockquote, .list, .listItem,
            .taskItem, .fences, .indentedCode, .hr, .linkDefinition,
            .footnoteDefinition, .emptyLine:
            return false
        }
    }

    /// Blocks that can hold inline content.
    var holdsInlines: Bool {
        switch self {
        case .heading, .paragraph, .listItem, .taskItem, .linkDefinition,
            .footnoteDefinition:
            return true
        default:
            return false
        }
    }

    /// Blocks whose content is a sequence of other blocks.
    var holdsBlocks: Bool {
        switch self {
        case .list, .blockquote:
            return true
        default:
            return false
        }
    }
}

/// Github-style alert kinds recognised inside a blockquote's first line.
public enum AlertKind: String, Hashable, Sendable {
    case note, tip, important, warning, caution

    init?(token: String) {
        self.init(rawValue: token.lowercased())
    }
}

/// One block node.
///
/// ## Why `source` exists
///
/// `source` is the exact original text of the block, sliced out of the input.
/// Saving the document writes these slices back verbatim, so **round-trip is
/// byte-identical by construction** - there is no re-serialisation path for text
/// blocks at all, which removes the entire class of "the writer normalised my
/// list markers" bugs.
///
/// The parsed structure (`inlines`, `children`, `attributes`) is a *view* over
/// `source`, used for rendering, outline, search, word count and export. The two
/// can never drift because the view is derived, never re-entered.
///
/// The exception is `isAttachmentRendered` blocks: those occupy one placeholder
/// character in the buffer, so their text has to be regenerated. See
/// `Markdown/Serialize/AttachmentWriter.swift`.
public struct BlockNode: Identifiable, Hashable, Sendable {
    public var id: Int
    public var kind: BlockKind
    /// The block's exact source text, including its own trailing newline.
    public var source: String
    /// Verbatim text of the blank lines that preceded this block, each terminated
    /// by a newline.
    ///
    /// Storing the text rather than a count is what keeps lines that contain only
    /// spaces round-trip: `a\n    \nb` must not come back as `a\n\nb`.
    public var leadingText: String = ""

    /// How many blank lines preceded this block. Derived from `leadingText`; the
    /// loose-list check uses it.
    public var blankLinesBefore: Int { leadingText.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } }
    /// Byte offset of `source` within the document text it was parsed from.
    /// -1 while the node is synthetic (not yet committed to a buffer).
    public var sourceOffset: Int = -1

    public var inlines: [InlineNode] = []
    public var children: [BlockNode] = []

    public var attributes = Attributes()

    public struct Attributes: Hashable, Sendable {
        // heading
        public var level: Int = 0
        public var isSetext: Bool = false
        // fences
        public var fenceChar: Character = "`"
        public var fenceLength: Int = 3
        public var infoString: String = ""
        // math
        public var mathOpen: String = "$$"
        public var mathClose: String = "$$"
        public var mathTag: String?
        // html
        public var htmlFence: String?
        // quote
        public var quoteDepth: Int = 0
        public var alert: AlertKind?
        // lists
        public var isOrdered: Bool = false
        public var listStart: Int = 1
        public var bulletChar: Character = "-"
        public var orderedDelimiter: Character = "."
        public var isLoose: Bool = false
        public var indentWidth: Int = 2
        public var checked: Bool?
        // hr
        public var hrChar: Character = "-"
        public var hrLength: Int = 3
        // toc
        public var tocToken: String = "[TOC]"
        // definitions
        public var definitionLabel: String = ""
        public var definitionDestination: String = ""
        public var definitionTitle: String?
        // table - the four round-trip fields (see DESIGN.md §6.4)
        public var table = TableState()
        // front matter
        public var frontMatterFence: String = "---"
        // generic
        public var language: String = ""
    }

    public var text: String { inlines.verbatim }
    public var plainText: String { inlines.plainText }

    init(
        id: Int,
        kind: BlockKind,
        source: String,
        leadingText: String = "",
        sourceOffset: Int = -1
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.leadingText = leadingText
        self.sourceOffset = sourceOffset
    }

    /// Re-derives the body of `source` from the current inline tree.
    ///
    /// The round-trip invariant keeps `source` an exact slice of the input, which is
    /// what makes saving byte-exact - but it also means an edit to `inlines` is
    /// invisible until `source` is refreshed. Parsing never needs this; any code
    /// path that mutates inlines does.
    ///
    /// Returns `false` when the old body is not a suffix of `source`, which means the
    /// block is not a text block (a table keeps its original rows in `TableState` and
    /// must be re-rendered through the writer instead).
    @discardableResult
    public mutating func refreshSource(from previousBody: String) -> Bool {
        guard !previousBody.isEmpty, !inlines.isEmpty else { return false }
        guard source.hasSuffix(previousBody) else { return false }
        source = String(source.dropLast(previousBody.count)) + text
        return true
    }

    /// Depth-first walk including this node.
    public func forEachNode(_ body: (BlockNode) -> Void) {
        body(self)
        for child in children {
            child.forEachNode(body)
        }
    }

    /// Concatenated plain text of this node and all descendants.
    public var allPlainText: String {
        var parts: [String] = []
        forEachNode { node in
            if !node.inlines.isEmpty {
                parts.append(node.inlines.plainText)
            }
        }
        return parts.joined(separator: "\n")
    }
}

extension Array where Element == BlockNode {
    /// The exact original text this node was parsed from.
    ///
    /// `source` excludes the newline that terminates the block and the blank
    /// lines that precede it; those are recovered from `blankLinesBefore` and
    /// from the position in the enclosing array by `MarkdownDocument.source`.
    var verbatim: String { map(\.source).joined(separator: "\n") }

    var allPlainText: String {
        var parts: [String] = []
        forEachNode { node in
            if !node.inlines.isEmpty { parts.append(node.inlines.plainText) }
        }
        return parts.joined(separator: "\n")
    }

    public func forEachNode(_ body: (BlockNode) -> Void) {
        for node in self {
            node.forEachNode(body)
        }
    }

    func first(of kind: BlockKind) -> BlockNode? {
        first { $0.kind == kind }
    }
}

/// Table-specific state.
///
/// `userText` and `alignText` are the original's round-trip escape hatch and the
/// single most important detail for table fidelity: while they are present the
/// writer replays the original rows verbatim, which preserves irregular padding
/// and non-aligned delimiters that a recomputed table would rewrite.
///
/// Both are cleared together the moment anything about the table changes -
/// **including a cell's text**, not just its structure. the original clears them in
/// eight places (`tryResetTable`): move row, move column, resize, delete row,
/// delete column, insert row, insert column, change cell text, change alignment,
/// delete table. Missing the cell-text case silently discards the user's typing
/// on the next save.
public struct TableState: Hashable, Sendable {
    public var columnAlignments: [ColumnAlignment] = []
    public var columnCount: Int = 0
    public var rowCount: Int = 0
    /// True when the source uses a GitHub-style table (leading and trailing
    /// pipes on every row).
    public var isPipeDelimited = true
    /// Original row texts, replayed verbatim while present.
    public var userText: [String]?
    /// Original delimiter-row texts, replayed verbatim while present.
    public var alignText: [String]?
    /// Leading/trailing spaces around each cell's content, kept only when the
    /// table is irregular enough that a rebuild would not reproduce the source.
    public var cellPadding: [CellPadding] = []

    public struct CellPadding: Hashable, Sendable {
        public var leading: Int = 0
        public var trailing: Int = 0
    }

    public enum ColumnAlignment: String, Hashable, Sendable {
        case none, left, center, right

        /// Rendered marker for the delimiter row, matching the original's
        /// `right:` / `center:` / `:---:` convention.
        public var delimiter: String {
            switch self {
            case .none: return "---"
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            }
        }

        public static func parse(_ raw: String) -> ColumnAlignment {
            let token = Substring(raw)
            let left = token.hasPrefix(":")
            let right = token.hasSuffix(":")
            if left && right { return .center }
            if right { return .right }
            if left { return .left }
            return .none
        }
    }

    /// Clears the replay state so the next serialisation rebuilds the table.
    /// See the type documentation for the full trigger list.
    public mutating func invalidateReplay() {
        userText = nil
        alignText = nil
    }
}

/// The parsed document: a flat list of top-level blocks plus derived indexes.
public struct MarkdownDocument: Hashable, Sendable {
    public var blocks: [BlockNode]
    /// Whether the source used CRLF.
    ///
    /// Recorded but no longer acted on: every block's `source` is a verbatim slice of
    /// the original text, so it already carries its own `\r`. Re-applying the
    /// substitution here doubled it - a CRLF file came back 86 bytes longer than it
    /// started, on every save.
    public var usesCarriageReturns = false
    /// Whether the source ended with a trailing newline.
    public var endsWithNewline = true
    /// Verbatim blank-line text after the last block, each terminated by a
    /// newline. A file ending in `\n\n` must not be rewritten to end in `\n`.
    public var trailingText: String = ""

    /// Link reference definitions by lowercased label.
    public var linkDefinitions: [String: BlockNode] = [:]
    /// Footnote definitions by label.
    public var footnoteDefinitions: [String: BlockNode] = [:]

    public init(
        blocks: [BlockNode],
        usesCarriageReturns: Bool = false,
        endsWithNewline: Bool = true,
        trailingText: String = ""
    ) {
        self.blocks = blocks
        self.usesCarriageReturns = usesCarriageReturns
        self.endsWithNewline = endsWithNewline
        self.trailingText = trailingText
        rebuildIndexes()
    }

    /// Reassembles the original document text.
    ///
    /// Each block contributes `blankLinesBefore` newlines, a separator newline
    /// when it is not the first, and its own `source`. Because every block's
    /// `source` is a verbatim slice, this reproduces the input byte for byte -
    /// there is no normalisation step to disagree with.
    public var source: String {
        var text = ""
        for (index, block) in blocks.enumerated() {
            if index > 0 { text += "\n" }
            text += block.leadingText
            text += block.source
        }
        // The final newline. `trailingText` already carries one when the file ended in
        // a blank line, and adding another would grow the tail by a byte per save -
        // which is how `a\n\n\n` came back as `a\n\n\n\n`.
        let tailCoversIt = trailingText.hasSuffix("\n")
        if endsWithNewline, !text.isEmpty, !tailCoversIt { text += "\n" }
        text += trailingText
        return text
    }

    public var plainText: String { blocks.allPlainText }

    public mutating func rebuildIndexes() {
        linkDefinitions.removeAll(keepingCapacity: true)
        footnoteDefinitions.removeAll(keepingCapacity: true)
        blocks.forEachNode { node in
            switch node.kind {
            case .linkDefinition:
                linkDefinitions[node.attributes.definitionLabel.lowercased()] = node
            case .footnoteDefinition:
                footnoteDefinitions[node.attributes.definitionLabel] = node
            default:
                break
            }
        }
    }

    /// Headings in document order - the outline and `[TOC]` source.
    public var headings: [Heading] {
        var result: [Heading] = []
        blocks.forEachNode { node in
            guard node.kind == .heading else { return }
            result.append(
                Heading(
                    level: node.attributes.level,
                    text: node.inlines.plainText,
                    blockID: node.id
                )
            )
        }
        return result
    }

    /// One entry in the outline.
    public struct Heading: Hashable, Sendable {
        public var level: Int
        public var text: String
        public var blockID: Int

        public init(level: Int, text: String, blockID: Int) {
            self.level = level
            self.text = text
            self.blockID = blockID
        }
    }
}
