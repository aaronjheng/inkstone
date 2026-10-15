import AppKit

/// Geometry and parsing for a YAML front matter block's painted table.
///
/// The block's source stays in the buffer byte for byte; the decoration layer
/// paints one row per line over it - the same painted route pipe tables take,
/// including focus revealing the source. Fence lines (`---`) collapse the way
/// a table's delimiter row does, and `key: value` lines become two columns.
struct FrontMatterLayout {
    /// One source line: a fence, or a body line split on its first colon.
    struct Row {
        /// Empty when the line held no colon and shows as running text.
        var key: String
        var value: String
        var isFence: Bool
    }

    /// Every source line, fences flagged.
    var rows: [Row]
    var rowHeight: CGFloat

    /// Line height of a fence row while the block is painted.
    ///
    /// The row is in the buffer but shows nothing, so its line should not be
    /// seen. `0` reads as "unconstrained" to TextKit, hence the sliver - the
    /// same value the table grid uses for its delimiter row.
    static let collapsedFenceLineHeight: CGFloat = 0.01

    /// Splits `source` into rows: the first and last lines are the fences and
    /// every other line breaks on its first colon. A trailing `\r` is source
    /// punctuation, not cell content.
    static func parse(source: String, rowHeight: CGFloat) -> FrontMatterLayout {
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var rows: [Row] = []
        for (index, line) in lines.enumerated() {
            let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if index == 0 || index == lines.count - 1 {
                rows.append(Row(key: "", value: "", isFence: true))
                continue
            }
            if let colon = clean.firstIndex(of: ":") {
                rows.append(
                    Row(
                        key: clean[..<colon].trimmingCharacters(in: .whitespaces),
                        value: clean[clean.index(after: colon)...].trimmingCharacters(
                            in: .whitespaces
                        ),
                        isFence: false
                    )
                )
            } else if let equals = clean.firstIndex(of: "=") {
                // `+++` TOML blocks use `key = value`; without this they
                // showed as a single running-text column.
                rows.append(
                    Row(
                        key: clean[..<equals].trimmingCharacters(in: .whitespaces),
                        value: clean[clean.index(after: equals)...].trimmingCharacters(
                            in: .whitespaces
                        ),
                        isFence: false
                    )
                )
            } else {
                rows.append(Row(key: "", value: clean, isFence: false))
            }
        }
        return FrontMatterLayout(rows: rows, rowHeight: rowHeight)
    }

    /// The paragraph style the buffer's `index`-th source row has to carry.
    ///
    /// Painted, a fence row collapses and a body row takes one line box;
    /// revealed, every row is an ordinary line the user can edit.
    func paragraphStyle(
        forSourceRow index: Int, revealed: Bool, spacing: CGFloat
    ) -> NSParagraphStyle {
        let height: CGFloat
        if revealed {
            height = rowHeight
        } else if rows.indices.contains(index), rows[index].isFence {
            height = Self.collapsedFenceLineHeight
        } else {
            height = rowHeight
        }
        return NSParagraphStyle.markdownBody(lineHeight: height, spacing: spacing)
    }
}
