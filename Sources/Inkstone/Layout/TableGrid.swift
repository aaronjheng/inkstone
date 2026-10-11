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
    var alignments: [NSTextAlignment]
    /// Left edge of every column, in points from the block's left edge.
    var columnOffsets: [CGFloat]
    /// Usable text width of every column, padding excluded.
    var columnWidths: [CGFloat]
    var font: NSFont
    var color: NSColor
    /// Height of one wrapped line, pinned by the layout pass.
    var rowHeight: CGFloat = 0
    /// Height of every painted row, in `rows` order. A row that has to wrap is
    /// several of these tall; the layout pass writes the same number into the
    /// row's paragraph style so the two stay in step.
    var rowHeights: [CGFloat] = []
    /// Sum of `rowHeights` - the height the painted table occupies.
    var totalHeight: CGFloat = 0
    /// Position of the `|---|` row in the buffer, `nil` when the table has none.
    var delimiterIndex: Int?

    /// Line height of the delimiter row while the table is painted.
    ///
    /// The row is in the buffer but shows nothing, so its line should not be seen.
    /// `0` is not usable: TextKit reads it as "unconstrained" and falls back to the
    /// font's natural height, so the smallest honest value is a sliver.
    static let collapsedDelimiterLineHeight: CGFloat = 0.01

    var columnCount: Int { columnOffsets.count }

    /// Splits a row on unescaped pipes and trims the padding that only exists to
    /// space the source out.
    static func cells(in row: String) -> [String] {
        let characters = Array(row)
        var cells: [String] = []
        var start: Int?
        var index = 0
        while index <= characters.count {
            let atEnd = index == characters.count
            let isPipe =
                atEnd || (characters[index] == "|" && (index == 0 || characters[index - 1] != "\\"))
            if isPipe {
                // An empty span is the row's leading or trailing pipe, not a cell.
                if let begin = start, begin < index {
                    cells.append(String(characters[begin..<index]))
                }
                start = index + 1 <= characters.count ? index + 1 : nil
            }
            index += 1
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
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

    init(
        rows: [[String]], alignments: [NSTextAlignment], theme: EditorTheme,
        containerWidth: CGFloat, delimiterIndex: Int? = nil
    ) {
        let font = EditorFont.nsSystem(size: theme.bodyFontSize)
        let padding = theme.tableCellPadding
        var columnCount = 0
        for row in rows { columnCount = max(columnCount, row.count) }
        let safeRows = rows.map { $0 + Array(repeating: "", count: max(0, columnCount - $0.count)) }

        var widths: [CGFloat] = Array(repeating: 0, count: columnCount)
        for row in safeRows {
            for (index, cell) in row.enumerated() where !cell.isEmpty {
                let measured = (cell as NSString).size(withAttributes: [.font: font]).width
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
        let minimum: CGFloat = 44
        let gutters = padding * 2 * CGFloat(max(1, columnCount))
        let available = max(minimum * CGFloat(max(1, columnCount)), containerWidth - gutters)
        let floors = widths.map { max(minimum, $0) }
        let floorTotal = floors.reduce(0, +)
        if floorTotal > available {
            // Even the floors overflow: share the shortfall equally.
            let share = available / CGFloat(max(1, columnCount))
            widths = Array(repeating: max(1, share), count: columnCount)
        } else {
            let extra = available - floorTotal
            let wants = widths.reduce(0, +)
            widths = zip(widths, floors).map { want, floor in
                floor + (wants > 0 ? extra * want / wants : 0)
            }
        }

        var offsets: [CGFloat] = []
        var usable: [CGFloat] = []
        var cursor: CGFloat = 0
        for width in widths {
            offsets.append(cursor + padding)
            usable.append(max(1, width))
            cursor += width + padding * 2
        }
        self.rows = safeRows
        self.delimiterIndex = delimiterIndex
        let missing = max(0, columnCount - alignments.count)
        let leftFill = Array(repeating: NSTextAlignment.left, count: missing)
        self.alignments = Array(alignments.prefix(columnCount)) + leftFill
        self.columnOffsets = offsets
        self.columnWidths = usable
        self.font = font
        self.color = theme.text.nsColor
        self.rowHeight = theme.bodyLineHeight * theme.bodyFontSize
        // A cell that does not fit wraps, and the row has to grow to hold it: the
        // buffer's row lines are zero width and never wrap on their own, so the
        // space they occupy has to be decided here and then written into the
        // paragraph style of that row.
        self.rowHeights = safeRows.map { cells in
            var lines = 1
            for (index, cell) in cells.enumerated()
            where !cell.isEmpty && index < self.columnWidths.count {
                lines = max(lines, self.wrappedLines(cell, width: self.columnWidths[index]))
            }
            return CGFloat(lines) * self.rowHeight
        }
        self.totalHeight = rowHeights.reduce(0, +)
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
    /// count and the height the layout manager picks cannot drift apart.
    private func wrappedLines(_ text: String, width: CGFloat) -> Int {
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
