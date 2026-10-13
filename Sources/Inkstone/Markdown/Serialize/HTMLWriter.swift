import Foundation

/// Renders a parsed document to standalone HTML.
///
/// Walks the node tree rather than the buffer, for the same reason source mode does:
/// the buffer holds Markdown syntax, and the output has to hold semantics. A `**` in
/// the text becomes `<strong>`, not two asterisks inside a `<p>`.
///
/// The CSS is inlined because an exported document has to open correctly from a
/// folder with nothing next to it - the whole point of exporting rather than printing.
public enum HTMLWriter {
    /// Indentation of one level, and the tag soup it produces.
    private static let indents = [
        "blockquote", "ul", "ol", "table", "thead", "tbody", "tr", "pre", "div",
    ]

    public static func write(
        document: MarkdownDocument,
        title: String,
        css: String,
        includeFrontMatter: Bool = false
    ) -> String {
        let header: [String] = [
            "<!DOCTYPE html>",
            "<html lang=\"en\">",
            "<head>",
            "<meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
            "<title>\(escape(title))</title>",
            "<style>",
            "\(css)",
            "</style>",
            "</head>",
            "<body>",
            "<div class=\"markdown-body\">",
        ]
        var out = header.joined(separator: "\n") + "\n"
        for block in document.blocks {
            if block.kind == .frontMatter && !includeFrontMatter { continue }
            out.append(write(block: block, depth: 0))
            out.append("\n")
        }
        out.append("</div>\n</body>\n</html>\n")
        return out
    }

    // MARK: - Blocks

    private static func write(block: BlockNode, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        let inlines = html(inlines: block.inlines)

        switch block.kind {
        case .frontMatter:
            return ""
        case .heading:
            let level = max(1, min(6, block.attributes.level))
            return "\(pad)<h\(level)>\(inlines)</h\(level)>\n"
        case .paragraph:
            return "\(pad)<p>\(inlines)</p>\n"
        case .blockquote:
            return "\(pad)<blockquote>\n\(nested(block, depth: depth))\(pad)</blockquote>\n"
        case .list:
            let tag = block.attributes.isOrdered ? "ol" : "ul"
            return "\(pad)<\(tag)>\n\(nested(block, depth: depth))\(pad)</\(tag)>\n"
        case .listItem:
            return "\(pad)<li>\(inlines)\n\(nested(block, depth: depth))\(pad)</li>\n"
        case .taskItem:
            let checked = block.attributes.checked == true
            let box = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
            let tag = checked ? " checked" : ""
            return "\(pad)<li class=\"task-list-item\"\(tag)>\(box)\(inlines)\n"
                + "\(nested(block, depth: depth))\(pad)</li>\n"
        case .fences:
            let language = block.attributes.language
            let attribute = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
            return "\(pad)<pre><code\(attribute)>\(escape(codeBody(of: block)))</code></pre>\n"
        case .indentedCode:
            return "\(pad)<pre><code>\(escape(codeBody(of: block)))</code></pre>\n"
        case .mathBlock:
            return "\(pad)<div class=\"math math-display\">\(escape(mathBody(of: block)))</div>\n"
        case .hr:
            return "\(pad)<hr>\n"
        case .table:
            return write(table: block, depth: depth)
        case .htmlBlock:
            // Passed through verbatim: it is the author's markup, and the only way to
            // "convert" it without an HTML parser would be to get it wrong.
            return block.source
        case .toc:
            return "\(pad)<div class=\"toc\"></div>\n"
        case .linkDefinition:
            return ""
        case .footnoteDefinition:
            // The parser stores the definition's body in `definitionTitle` and
            // fills neither `inlines` nor `children`, so the old path emitted an
            // empty section and the footnote text vanished from the export.
            let label = block.attributes.definitionLabel
            let body = block.attributes.definitionTitle ?? ""
            return "\(pad)<section class=\"footnotes\">\n"
                + "\(pad)  <div id=\"fn-\(escape(label))\">\(escape(body))</div>\n"
                + "\(pad)</section>\n"
        case .emptyLine:
            return ""
        }
    }

    private static func nested(_ block: BlockNode, depth: Int) -> String {
        guard !block.children.isEmpty else { return "" }
        return block.children.map { write(block: $0, depth: depth + 1) }.joined()
    }

    private static func write(table block: BlockNode, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        let rows = tableRows(of: block)
        guard !rows.isEmpty else { return "" }
        var out = "\(pad)<table>\n\(pad)  <thead>\n"
        for cell in rows[0] {
            out += "\(pad)    <th>\(escape(cell))</th>\n"
        }
        out += "\(pad)  </thead>\n\(pad)  <tbody>\n"
        for row in rows.dropFirst() {
            out += "\(pad)    <tr>\n"
            for cell in row {
                out += "\(pad)      <td>\(escape(cell))</td>\n"
            }
            out += "\(pad)    </tr>\n"
        }
        return out + "\(pad)  </tbody>\n\(pad)</table>\n"
    }

    /// Every row of a pipe table, cells split by the same recognizer the parser
    /// and the painted grid use.
    ///
    /// This used to be a private re-implementation with its own delimiter rule
    /// (three dashes minimum, where the parser accepts one), so a valid GFM table
    /// like `|-|-|` rendered in the editor and silently vanished from the export.
    private static func tableRows(of block: BlockNode) -> [[String]] {
        var lines = block.source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count > 1, TableRecognizer.isDelimiterRow(lines[1]) else {
            return []
        }
        lines.remove(at: 1)
        return lines.map { TableRecognizer.split($0) }
    }

    // MARK: - Inlines

    private static func html(inlines: [InlineNode]) -> String {
        inlines.map { node in
            let children = html(inlines: node.children)
            switch node.kind {
            case .text, .softBreak:
                return escape(node.verbatim)
            case .hardBreak:
                return "<br>\n"
            case .entity:
                return node.payload.isEmpty ? escape(node.verbatim) : escape(node.payload)
            case .escape:
                // The escape's whole point is the literal character behind the
                // backslash; exporting the backslash undid it.
                return escape(node.payload.isEmpty ? node.verbatim : node.payload)
            case .strong:
                return wrap("strong", children.isEmpty ? escape(node.payload) : children)
            case .em:
                return wrap("em", children.isEmpty ? escape(node.payload) : children)
            case .underline:
                return wrap("u", children.isEmpty ? escape(node.payload) : children)
            case .strike:
                return wrap("del", children.isEmpty ? escape(node.payload) : children)
            case .highlight:
                return wrap("mark", children.isEmpty ? escape(node.payload) : children)
            case .sub:
                return wrap("sub", children.isEmpty ? escape(node.payload) : children)
            case .sup:
                return wrap("sup", children.isEmpty ? escape(node.payload) : children)
            case .code:
                return "<code>\(escape(node.payload))</code>"
            case .inlineMath:
                return "<span class=\"math\">\(escape(node.payload))</span>"
            case .link:
                let href = node.attributes.destination ?? ""
                let title = node.attributes.title.map { " title=\"\(escape($0))\"" } ?? ""
                return "<a href=\"\(escape(href))\"\(title)>\(children)</a>"
            case .refLink:
                let reference = node.attributes.reference ?? ""
                return "<a href=\"#\(escape(reference))\">\(children)</a>"
            case .autolink:
                return "<a href=\"\(escape(node.payload))\">\(escape(node.payload))</a>"
            case .image, .refImage:
                let source = node.attributes.destination ?? node.payload
                // The alt text lives in `name` (the lexer stores the optional link
                // title separately); the old code exported the title as alt and
                // dropped both the real alt text and the title.
                let alt = node.attributes.name ?? node.payload
                let title = node.attributes.title.map { " title=\"\(escape($0))\"" } ?? ""
                return "<img src=\"\(escape(source))\" alt=\"\(escape(alt))\"\(title)>"
            case .footnoteRef:
                let reference = node.attributes.reference ?? ""
                return "<sup id=\"fnref-\(escape(reference))\">"
                    + "<a href=\"#fn-\(escape(reference))\">\(escape(reference))</a></sup>"
            case .emoji:
                return "<span class=\"emoji\">\(escape(node.payload))</span>"
            case .html:
                return node.verbatim
            case .ruby:
                return "<ruby>\(children)</ruby>"
            }
        }.joined()
    }

    private static func wrap(_ tag: String, _ body: String) -> String {
        "<\(tag)>\(body)</\(tag)>"
    }

    // MARK: - Text extraction

    private static func codeBody(of block: BlockNode) -> String {
        var lines = block.source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        // Drop the opening and closing fences, keeping everything between them byte for
        // byte: re-indenting here would change what the code says.
        let fence = block.attributes.fenceChar
        let marker = String(repeating: fence, count: block.attributes.fenceLength)
        let isFence = lines.first?.hasPrefix(marker) ?? false
        if isFence, lines.count >= 2 { lines.removeFirst() }
        if lines.last?.hasPrefix(marker) == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func mathBody(of block: BlockNode) -> String {
        var lines = block.source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        if lines.first?.trimmingCharacters(in: .whitespaces)
            .hasPrefix(block.attributes.mathOpen) == true
        {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespaces)
            .hasPrefix(block.attributes.mathClose) == true
        {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Escaping

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
