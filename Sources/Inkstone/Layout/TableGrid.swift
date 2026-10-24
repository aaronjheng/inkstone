import AppKit

/// Column geometry for a pipe table.
///
/// TextKit 1 can only align runs on tab stops, and the buffer is required to stay
/// byte-identical to the Markdown source, so there is nowhere legal to put a tab.
/// A pipe table therefore cannot become columns inside the text. The rows carry no
/// visible glyphs and the cells are painted from here instead - which is also how
/// The original draws its tables rather than typesetting them.
///
/// The source is untouched, so focusing the table reveals it again as plain text and
/// the user edits exactly what they wrote. See `MarkdownAttribute.paintedBlock`.
struct TableGrid {
    /// Cell text per row, padding trimmed. The delimiter row is not included.
    var rows: [[String]]
    /// Whether each cell is entirely a code span (mono in the preview).
    var cellMono: [[Bool]] = []
    var alignments: [NSTextAlignment]
    /// Left edge of every column, in points from the block's left edge.
    var columnOffsets: [CGFloat]
    /// Usable text width of every column, padding excluded.
    var columnWidths: [CGFloat]
    var font: NSFont
    /// The header row's face: the UA's `th { font-weight: bold }`.
    var headerFont: NSFont
    /// The face for cells that are entirely code spans (`code` renders mono
    /// in the preview).
    var monoFont: NSFont
    var color: NSColor
    /// Height of one wrapped line, pinned by the layout pass.
    var rowHeight: CGFloat = 0
    /// Height of every painted row, in `rows` order. A row that has to wrap is
    /// several of these tall; the layout pass writes the same number into the
    /// row's paragraph style so the two stay in step.
    var rowHeights: [CGFloat] = []
    /// Sum of `rowHeights` - the height the painted table occupies.
    var totalHeight: CGFloat = 0
    /// The shrink-to-fit element width (columns + gutters), clamped to the
    /// measure.
    var totalWidth: CGFloat = 0
    /// Per-column painted rects (x, w) in points from the block's left edge —
    /// the dump exports them for the comparator's per-column check.
    var columnRects: [[CGFloat]] = []
    /// Position of the `|---|` row in the buffer, `nil` when the table has none.
    var delimiterIndex: Int?

    /// Line height of the delimiter row while the table is painted.
    ///
    /// The row is in the buffer but shows nothing, so its line should not be seen.
    /// `0` is not usable: TextKit reads it as "unconstrained" and falls back to the
    /// font's natural height, so the smallest honest value is a sliver.
    static let collapsedDelimiterLineHeight: CGFloat = 0.01

    var columnCount: Int { columnOffsets.count }

    /// Splits a row into cells, honouring `\|` escapes and the parser's own
    /// rules for leading and trailing pipes. Delegated to `TableRecognizer`
    /// (Markdown/Parse) so the painted geometry can never disagree with the
    /// parsed cells: the old hand-rolled split dropped empty interior cells
    /// (`| a || b |`) and shifted every later column one left.
    static func cells(in row: String) -> [String] {
        TableRecognizer.split(row)
    }

    /// The cell's visible text: the preview renders each cell's inline
    /// markdown — links show their text, emphasis and code strip their
    /// markers — so the column widths and the painted cells measure the same
    /// glyphs the reference does. (Round 1: the common inline constructs;
    /// raw HTML and images pass through.)
    /// The cell's inline-markdown strips, in application order: images and
    /// links render their label, code spans strip to their content, emphasis
    /// pairs strip their markers, and backslash escapes render their
    /// character. The preview renders each cell's inline markdown the same
    /// way, so the column widths and the painted cells measure the same
    /// glyphs the reference does.
    private static let cellStrips: [(NSRegularExpression, String)] = {
        let rules: [(String, String)] = [
            ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"), // images
            ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"), // inline links
            ("\\[([^\\]]+)\\](?:\\[[^\\]]*\\])?", "$1"), // reference links
            ("`+([^`]+)`+", "$1"), // code spans
            ("(?:\\*\\*\\*|___)([^*_]+?)(?:\\*\\*\\*|___)", "$1"), // bold-italic
            ("\\*\\*([^*]+)\\*\\*", "$1"), // bold
            ("__([^_]+)__", "$1"),
            ("\\*([^*\n]+)\\*", "$1"), // italic
            ("_([^_\n]+)_", "$1"),
            ("~~([^~\n]+)~~", "$1"), // strikethrough
            ("\\\\([\\\\`*_{}\\[\\]()#+.!~-])", "$1"), // backslash escapes
        ]
        // The patterns are static constants above; the force try cannot fire.
        return rules.compactMap { pattern, template in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, template)
        }
    }()

    /// The cell's visible text plus whether the whole cell is one code span
    /// (the preview's `code { font-family: editor }` renders it mono).
    static func plainCell(_ cell: String) -> (String, Bool) {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        if trimmed.first == "`", trimmed.last == "`",
            let regex = try? NSRegularExpression(pattern: "^`+([^`]+)`+$"),
            let match = regex.firstMatch(
                in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)
            )
        {
            let inner = match.range(at: 1)
            let text = (trimmed as NSString).substring(with: inner)
            return (text, true)
        }
        var text = cell
        for (regex, template) in cellStrips {
            let range = NSRange(text.startIndex..., in: text)
            guard regex.firstMatch(in: text, range: range) != nil else { continue }
            text = regex.stringByReplacingMatches(
                in: text, range: range, withTemplate: template
            )
        }
        return (text, false)
    }

    /// Reads `:---`, `---:` and `:---:` out of the delimiter row.
    static func alignments(fromDelimiterRow row: String) -> [NSTextAlignment] {
        cells(in: row).map { cell in
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right { return .center }
            if right { return .right }
            return .left
        }
    }

    /// Full-width CJK: han, kana, hangul syllables, CJK punctuation and the
    /// fullwidth forms — every glyph the reference's cascade lays out at
    /// exactly 1em (PingFang SC han, Hiragino Sans kana, Apple SD Gothic
    /// hangul, the fullwidth punctuation).
    static func isFullwidth(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F, 0x3041...0x30FF, 0x3400...0x4DBF,
            0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
            0xFF01...0xFF60:
            return true
        default:
            return false
        }
    }

    /// The visible width of a cell the way the reference lays it out.
    ///
    /// `NSString.size` measures the system font's cascade, whose CJK faces
    /// advance han 0.992em, kana 0.949em, hangul 0.865em (measured) — while
    /// the reference lays every full-width CJK glyph at exactly 1em. The
    /// columns are content-sized, so a cell measured from the cascade comes
    /// out narrow (the alignment table 296.15 against 298.00, the kana
    /// column 86.43 against 90.00). Full-width CJK measures at the font
    /// size; the rest keeps the font's own advances.
    static func visibleWidth(_ text: String, font: NSFont) -> CGFloat {
        var fullwidth = 0
        var other = ""
        for scalar in text.unicodeScalars {
            if isFullwidth(scalar) {
                fullwidth += 1
            } else {
                other.unicodeScalars.append(scalar)
            }
        }
        let base = other.isEmpty
            ? 0 : (other as NSString).size(withAttributes: [.font: font]).width
        return base + CGFloat(fullwidth) * font.pointSize
    }

    /// The container's own inset for a nested table: the painted grid offsets
    /// by it (`paintTable`'s left edge), since the rows' line fragments still
    /// start at the container edge.
    var textColumn: CGFloat = 0

    init(
        rows: [[String]], alignments: [NSTextAlignment], theme: EditorTheme,
        containerWidth: CGFloat, delimiterIndex: Int? = nil, textColumn: CGFloat = 0
    ) {
        self.textColumn = textColumn
        let font = EditorFont.nsSystem(size: theme.bodyFontSize)
        // The UA styles `th { font-weight: bold }` and the preview does not
        // override it — the header row measures and paints bold.
        let headerFont = NSFont.systemFont(ofSize: theme.bodyFontSize, weight: .bold)
        // `th, td { padding: 5px 10px }` — vertical padding shapes the row
        // height, horizontal padding shapes the column gutters.
        let padding = theme.tableCellPadding
        let paddingX = theme.tableCellPaddingX
        var columnCount = 0
        for row in rows { columnCount = max(columnCount, row.count) }
        // The cells carry their source markdown; the preview renders each
        // cell's inline markdown (links show their text, emphasis/code strip
        // their markers) — measure and paint the same visible glyphs.
        let safeRows = rows.map {
            ($0 + Array(repeating: "", count: max(0, columnCount - $0.count)))
                .map(Self.plainCell)
        }
        let mono = EditorFont.nsMono(theme: theme, size: theme.bodyFontSize)

        var widths: [CGFloat] = Array(repeating: 0, count: columnCount)
        for (rowIndex, row) in safeRows.enumerated() {
            let rowFont = rowIndex == 0 ? headerFont : font
            for (index, entry) in row.enumerated() where !entry.0.isEmpty {
                let cellFont = entry.1 ? mono : rowFont
                let measured = Self.visibleWidth(entry.0, font: cellFont)
                widths[index] = max(widths[index], measured)
            }
        }

        // A table never runs past the measure.
        //
        // The obvious allocation - scale every column by the same factor - collapses a
        // wide table to nothing, because the widest cell drags the factor down for all
        // of them. Instead every column keeps a floor and the *remaining* width is
        // shared out in proportion to what each column asked for, so a table with one
        // very long cell still has readable cells beside it.
        // The preview's `table` carries no `width` rule: the element hugs its
        // content — every column takes its widest cell (floored at the
        // minimum) with no proportional fill — and only a table that cannot
        // fit the measure shares the shortfall out equally.
        // The preview's tables have no min-width: a column hugs its content
        // (an empty cell is just the padding pair).
        let minimum: CGFloat = 0
        let gutters = paddingX * 2 * CGFloat(max(1, columnCount))
        let available = max(minimum * CGFloat(max(1, columnCount)), containerWidth - gutters)
        let floors = widths.map { max(minimum, $0) }
        let floorTotal = floors.reduce(0, +)
        if floorTotal > available {
            // Even the floors overflow: share the shortfall equally.
            let share = available / CGFloat(max(1, columnCount))
            widths = Array(repeating: max(1, share), count: columnCount)
        } else {
            widths = floors
        }

        var offsets: [CGFloat] = []
        var usable: [CGFloat] = []
        var cursor: CGFloat = 0
        for width in widths {
            offsets.append(cursor + paddingX)
            usable.append(max(1, width))
            cursor += width + paddingX * 2
        }
        self.rows = safeRows.map { $0.map(\.0) }
        self.cellMono = safeRows.map { $0.map(\.1) }
        self.delimiterIndex = delimiterIndex
        let missing = max(0, columnCount - alignments.count)
        let leftFill = Array(repeating: NSTextAlignment.left, count: missing)
        self.alignments = Array(alignments.prefix(columnCount)) + leftFill
        self.columnOffsets = offsets
        self.columnWidths = usable
        self.font = font
        self.headerFont = headerFont
        self.monoFont = EditorFont.nsMono(theme: theme, size: theme.bodyFontSize)
        self.color = theme.text.nsColor
        // `th, td { padding: 5px 10px }` + the collapsed 1px row border:
        // each painted row is the cell's line box plus its vertical padding
        // and border, exactly as the reference's CSS table lays out.
        self.rowHeight = theme.bodyLineHeight * theme.bodyFontSize
            + theme.tableCellPadding * 2 + 1
        // A cell that does not fit wraps, and the row has to grow to hold it: the
        // buffer's row lines are zero width and never wrap on their own, so the
        // space they occupy has to be decided here and then written into the
        // paragraph style of that row.
        self.rowHeights = safeRows.map { cells in
            var lines = 1
            for (index, entry) in cells.enumerated()
            where !entry.0.isEmpty && index < self.columnWidths.count {
                // A code cell renders in the mono face: its wrap points are
                // the mono face's, not the body's (the `~~文本~~` cell measured
                // at the body font overflowed its mono-sized column and grew
                // the row a whole line, 167.00 against 132.56).
                let cellFont = entry.1 ? self.monoFont : self.font
                lines = max(
                    lines,
                    self.wrappedLines(entry.0, width: self.columnWidths[index], font: cellFont)
                )
            }
            return CGFloat(lines) * self.rowHeight
        }
        self.totalHeight = rowHeights.reduce(0, +)
        self.totalWidth = min(
            containerWidth,
            widths.reduce(0, +) + paddingX * 2 * CGFloat(max(1, columnCount))
        )
        // The cell rects = the padding boxes (content + the horizontal
        // padding), matching the reference's `th`/`td` border boxes — the
        // painted text sits at `offset` (content), the cell's own left edge
        // is `offset − paddingX`.
        self.columnRects = zip(columnOffsets, columnWidths).map { offset, width in
            [offset - paddingX, width + paddingX * 2]
        }
    }

    /// The paragraph style the buffer's `index`-th source row has to carry.
    ///
    /// `index` counts rows as the user wrote them, so it includes the delimiter row.
    /// While the table is painted each row gets its own height: a cell that wraps
    /// needs several line boxes, and a line of zero-width glyphs never wraps on its
    /// own, so the room has to be declared up front. Focusing the block reveals the
    /// source instead - the lines then carry real text and wrap by themselves, and
    /// pinning them to a table row's height would blow every wrapped line up by a
    /// whole row.
    func paragraphStyle(
        forSourceRow index: Int, revealed: Bool, spacing: CGFloat
    ) -> NSParagraphStyle {
        NSParagraphStyle.markdownBody(
            lineHeight: paragraphHeight(forSourceRow: index, revealed: revealed),
            spacing: spacing
        )
    }

    private func paragraphHeight(forSourceRow index: Int, revealed: Bool) -> CGFloat {
        if revealed { return rowHeight }
        if index == delimiterIndex { return Self.collapsedDelimiterLineHeight }
        var painted = index
        if let delimiter = delimiterIndex, index > delimiter { painted -= 1 }
        guard rowHeights.indices.contains(painted) else { return rowHeight }
        return rowHeights[painted]
    }

    /// How many line boxes `text` needs inside `width`.
    ///
    /// Measured with the same paragraph style the row is laid out with, so the
    /// count and the height the layout manager picks cannot drift apart. A
    /// cell that fits its column never wraps — the column is content-sized
    /// from the same measurement, and the widest cell must not round into a
    /// second line through `boundingRect`'s pixel snapping.
    private func wrappedLines(_ text: String, width: CGFloat, font: NSFont) -> Int {
        if Self.visibleWidth(text, font: font) <= width { return 1 }
        let box = (text as NSString).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: Self.wrapStyle(lineHeight: rowHeight)]
        )
        return max(1, Int((box.height / rowHeight).rounded(.up)))
    }

    /// The paragraph style a wrapped cell is measured with: one line box of
    /// exactly the row's height, no spacing of its own.
    static func wrapStyle(lineHeight: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineHeightMultiple = 1
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// The cell rectangle for a column, in the block's coordinate space.
    func cellRect(column: Int, rowHeight: CGFloat) -> CGRect {
        guard column < columnOffsets.count else { return .zero }
        return CGRect(
            x: columnOffsets[column],
            y: 0,
            width: columnWidths[column],
            height: rowHeight
        )
    }
}
