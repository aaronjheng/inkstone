import Foundation

/// Renders a document's outline as OPML.
///
/// The original's outline export is OPML rather than Markdown, and that is the whole reason
/// this exists alongside `HTMLWriter`: the outline is a *structure*, not a document, so
/// it wants a format that has headings and nesting and nothing else. Headings become
/// `outline` elements at their real level, and everything else becomes `body` text
/// carried up to the nearest heading.
public enum OPMLWriter {
    public static func write(document: MarkdownDocument, title: String) -> String {
        let head: [String] = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<opml version=\"2.0\">",
            "  <head>",
            "    <title>\(escape(title))</title>",
            "  </head>",
            "  <body>",
            "    <outline text=\"\(escape(title))\" title=\"\(escape(title))\">",
        ]
        var out = head.joined(separator: "\n") + "\n"
        var headings: [Heading] = []
        var preamble: [String] = []
        // Body text hangs one level below whichever heading it sits under, so a `##`
        // that follows a paragraph is still a sibling of that paragraph rather than its
        // child.
        var currentLevel = 7
        for block in document.blocks {
            switch block.kind {
            case .heading:
                currentLevel = max(1, min(6, block.attributes.level))
                headings.append(
                    Heading(level: currentLevel, text: plainText(inlines: block.inlines))
                )
            case .frontMatter, .toc, .linkDefinition:
                continue
            case .emptyLine:
                continue
            default:
                let text = plainText(inlines: block.inlines)
                guard !text.isEmpty else { continue }
                // An outline entry is a point in the document, so body text belongs to
                // the heading above it rather than beside it. Keep it as a sibling
                // outline: OPML's own note attribute is a display hint, not a container.
                if headings.isEmpty {
                    preamble.append(text)
                } else {
                    headings.append(Heading(level: currentLevel + 1, text: text))
                }
            }
        }
        for text in preamble {
            out.append("    <outline text=\"\(escape(text))\"/>\n")
        }
        out.append(nest(headings, depth: 2))
        // One closing tag per line, like the head above: the old tail ran three
        // closing tags together on one line.
        out.append("</outline>\n")
        out.append("  </body>\n")
        out.append("</opml>\n")
        return out
    }

    private struct Heading {
        var level: Int
        var text: String
    }

    /// Emits headings as a tree, skipping a level the document never used.
    ///
    /// OPML nests by depth, so a document that jumps from `#` to `###` would otherwise
    /// produce a level-3 outline with no parent. Levels are renumbered to the depth they
    /// actually occupy, which is the one transformation that cannot lose information.
    private static func nest(_ headings: [Heading], depth: Int) -> String {
        guard let first = headings.first else { return "" }
        let pad = String(repeating: "  ", count: depth)
        var out = "\(pad)<outline text=\"\(escape(first.text))\">\n"

        var index = 1
        while index < headings.count {
            // Everything shallower than the heading we just opened closes it.
            if headings[index].level <= first.level {
                out += "\(pad)</outline>\n"
                out += nest(Array(headings[index...]), depth: depth)
                return out
            }
            var end = index
            while end < headings.count && headings[end].level > first.level { end += 1 }
            out += nest(Array(headings[index..<end]), depth: depth + 1)
            index = end
        }
        out += "\(pad)</outline>\n"
        return out
    }

    /// The visible text of an inline run, with the syntax dropped.
    private static func plainText(inlines: [InlineNode]) -> String {
        var out = ""
        for node in inlines {
            switch node.kind {
            case .text:
                out += node.payload
            case .code, .emoji, .autolink:
                // The payload, not the verbatim: code dropped its backticks and
                // emoji its colons in the outline.
                out += node.payload
            case .entity:
                // The verbatim (`&amp;`) would be escaped a second time below and
                // arrive in the reader as literal text.
                out += node.payload.isEmpty ? node.verbatim : InlineNode.decodeEntity(node.payload)
            case .softBreak, .hardBreak:
                out += " "
            case .image, .refImage:
                // The alt text, not the link title (which is usually nil).
                out += node.attributes.name ?? node.payload
            case .footnoteRef:
                out += "[\(node.attributes.reference ?? "")]"
            default:
                out += plainText(inlines: node.children)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
