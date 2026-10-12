import Foundation

/// Regenerates source for attachment-rendered blocks (table, math block,
/// HTML block, TOC). These blocks occupy one placeholder character in the
/// buffer (`U+FFFC`), so their source must be rebuilt from `attributes` and,
/// for tables, the replay state (`TableState.userText` / `alignText`).
///
/// The design goal is byte-fidelity where possible: when the replay fields
/// are present the original rows are emitted verbatim; when they have been
/// cleared (because the user edited a cell) a canonical table is rebuilt from
/// the children's inline content.
public enum AttachmentWriter {
    /// The source text of an attachment-rendered block, rebuilt from its node.
    public static func source(for block: BlockNode) -> String {
        switch block.kind {
        case .table:
            return tableSource(for: block)
        case .mathBlock:
            return mathSource(for: block)
        case .htmlBlock:
            // HTML blocks are byte-faithful by construction: their source is
            // the buffer content between the opening and closing tags.
            return block.source
        case .toc:
            return tocSource(for: block)
        default:
            return block.source
        }
    }

    // MARK: - Table

    private static func tableSource(for block: BlockNode) -> String {
        let state = block.attributes.table
        // Replay mode: emit the original rows exactly as the user typed them.
        // This preserves irregular padding, extra spaces, and non-standard
        // delimiter rows that a rebuilt table would normalise away.
        if let userText = state.userText, let alignText = state.alignText {
            var lines = userText
            if lines.count >= 2 {
                lines.insert(alignText.joined(separator: "\n"), at: 1)
            }
            return lines.joined(separator: "\n") + (block.source.hasSuffix("\n") ? "" : "\n")
        }
        // Rebuild mode: regenerate from children's inline content.
        guard !block.children.isEmpty else { return block.source }
        let rows = block.children.map { $0.inlines.plainText }
        let headerRow = rows.first ?? ""
        let bodyRows = Array(rows.dropFirst())

        let delimiterRow = state.columnAlignments.map { $0.delimiter }.joined(separator: " | ")
        var rebuilt = ""
        rebuilt += "| \(headerRow) |\n"
        rebuilt += "| \(delimiterRow) |\n"
        for rowText in bodyRows {
            rebuilt += "| \(rowText) |\n"
        }
        return rebuilt
    }

    // MARK: - Math block

    private static func mathSource(for block: BlockNode) -> String {
        let open = block.attributes.mathOpen
        let close = block.attributes.mathClose
        let tag = block.attributes.mathTag
        var lines: [String] = []
        if let userText = block.source.components(separatedBy: "\n") as? [String] {
            // Filter out empty opening/closing fence lines to recover body.
            for line in userText {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == open || trimmed == close { continue }
                lines.append(line)
            }
        }
        let body = lines.joined(separator: "\n")
        if let tag = tag, !tag.isEmpty {
            return "\(open){\(tag)}\n\(body)\n\(close)"
        }
        return "\(open)\n\(body)\n\(close)"
    }

    // MARK: - HTML block

    private static func htmlSource(for block: BlockNode) -> String {
        // HTML blocks keep their original source verbatim.
        return block.source
    }

    // MARK: - Table of contents

    private static func tocSource(for block: BlockNode) -> String {
        let token = block.attributes.tocToken
        return token.isEmpty ? "[TOC]" : token
    }

    // MARK: - Table reset (tryResetTable)

    /// Clears the replay state when a table's cell text has been edited, ensuring
    /// the user's typing is preserved on the next save rather than being silently
    /// discarded.
    ///
    /// The original (`tryResetTable`) clears replay fields in eight situations:
    /// move row, move column, resize, delete row, delete column, insert row,
    /// insert column, change cell text, change alignment, delete table.
    /// The cell-text case (`change cell text`) was missing, which meant editing
    /// a cell's content would leave the replay fields intact; the writer then
    /// replayed the stale original rows and overwrote the user's new text.
    public static func tryResetTable(for block: inout BlockNode) {
        guard block.kind == .table else { return }
        // When any child (table cell) has been edited, the replay state must be
        // cleared so the rebuilt table reflects the new cell content rather than
        // replaying obsolete rows.
        var edited = false
        for child in block.children {
            if child.inlines.plainText != child.source.trimmingCharacters(in: .whitespacesAndNewlines) {
                edited = true
                break
            }
        }
        if edited {
            block.attributes.table.invalidateReplay()
        }
    }
}
