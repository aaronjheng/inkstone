import AppKit

/// CSS for an exported document, derived from the active theme.
///
/// An export has to stand alone - the reader may open it with no network and no
/// sibling stylesheet - so the theme's colours are inlined rather than referenced.
/// Only the light variant is emitted: an exported file is read once, usually on a
/// white background, and a `prefers-color-scheme` block would be the one place the
/// export could disagree with what the author saw while writing.
enum ExportCSS {
    static func styleSheet(for theme: EditorTheme) -> String {
        let body = hex(theme.text.nsColor)
        let background = hex(theme.background.nsColor)
        let link = hex(theme.link.nsColor)
        let code = hex(theme.codeText.nsColor)
        let codeBackground = hex(theme.codeBlockBackground.nsColor)
        let inlineCodeBackground = theme.inlineCodeBackground.map { hex($0.nsColor) } ?? "transparent"
        let quoteBar = hex(theme.quoteBar.nsColor)
        let border = hex(theme.tableBorder.nsColor)
        let marker = hex(theme.marker.nsColor)
        let h1Rule = hex(theme.headingRule(1)?.nsColor ?? theme.tableBorder.nsColor)
        let h2Rule = hex(theme.headingRule(2)?.nsColor ?? theme.tableBorder.nsColor)

        let size = Int(theme.bodyFontSize.rounded())
        let lineHeight = String(format: "%.2f", theme.bodyLineHeight)
        let indent = Int(theme.listIndent.rounded())
        let quoteWidth = String(format: "%.1f", theme.quoteBarWidth)
        let contentWidth = Int(theme.contentWidth(for: 900).rounded())

        let lines: [String] = [
            ":root { color-scheme: light; }",
            "body {",
            "  margin: 0;",
            "  padding: 48px 24px;",
            "  background: \(background);",
            "  color: \(body);",
            "  font: \(size)px/\(lineHeight) -apple-system, BlinkMacSystemFont, \"Helvetica Neue\", sans-serif;",
            "}",
            ".markdown-body { max-width: \(contentWidth)px; margin: 0 auto; }",
            ".markdown-body h1, .markdown-body h2, .markdown-body h3,",
            ".markdown-body h4, .markdown-body h5, .markdown-body h6 {",
            "  color: \(body);",
            "  line-height: 1.25;",
            "  margin: 1.4em 0 0.6em;",
            "  font-weight: 600;",
            "}",
            ".markdown-body h1 {",
            "  font-size: 2em;",
            "  padding-bottom: 0.3em;",
            "  border-bottom: 1px solid \(h1Rule);",
            "}",
            ".markdown-body h2 {",
            "  font-size: 1.5em;",
            "  padding-bottom: 0.3em;",
            "  border-bottom: 1px solid \(h2Rule);",
            "}",
            ".markdown-body h3 { font-size: 1.25em; }",
            ".markdown-body h4 { font-size: 1em; }",
            ".markdown-body h5 { font-size: 0.875em; }",
            ".markdown-body h6 { font-size: 0.85em; color: \(marker); }",
            ".markdown-body p { margin: 0 0 0.8em; }",
            ".markdown-body a { color: \(link); text-decoration: none; }",
            ".markdown-body a:hover { text-decoration: underline; }",
            ".markdown-body ul, .markdown-body ol { padding-left: \(indent * 2)px; margin: 0 0 0.8em; }",
            ".markdown-body li { margin: 0.2em 0; }",
            ".markdown-body .task-list-item {",
            "  list-style: none;",
            "  margin-left: -1.4em;",
            "}",
            ".markdown-body blockquote {",
            "  margin: 0 0 0.8em;",
            "  padding: 0 0 0 \(indent)px;",
            "  border-left: \(quoteWidth)px solid \(quoteBar);",
            "  color: \(marker);",
            "}",
            ".markdown-body code {",
            "  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;",
            "  font-size: 0.9em;",
            "  background: \(inlineCodeBackground);",
            "  color: \(code);",
            "  padding: 0.15em 0.35em;",
            "  border-radius: 3px;",
            "}",
            ".markdown-body pre {",
            "  background: \(codeBackground);",
            "  padding: 14px 16px;",
            "  border-radius: 5px;",
            "  overflow-x: auto;",
            "  margin: 0 0 0.8em;",
            "}",
            ".markdown-body pre code { background: none; padding: 0; color: \(code); }",
            ".markdown-body table { border-collapse: collapse; margin: 0 0 0.8em; width: 100%; }",
            ".markdown-body th, .markdown-body td { border: 1px solid \(border); padding: 6px 12px; }",
            ".markdown-body th { background: \(codeBackground); font-weight: 600; }",
            ".markdown-body hr { border: none; border-top: 1px solid \(border); margin: 1.4em 0; }",
            ".markdown-body img { max-width: 100%; }",
            ".markdown-body .math-display {",
            "  font-family: \"Times New Roman\", Times, serif;",
            "  font-style: italic;",
            "  text-align: center;",
            "  padding: 10px 0;",
            "}",
            ".markdown-body .math { font-family: \"Times New Roman\", Times, serif; font-style: italic; }",
            ".markdown-body .footnotes {",
            "  border-top: 1px solid \(border);",
            "  margin-top: 2em;",
            "  font-size: 0.9em;",
            "}",
            ".markdown-body mark { background: #fff3a3; }",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// `#rrggbb`, or black when the colour cannot be expressed in one.
    static func hex(_ color: NSColor) -> String {
        guard let converted = color.usingColorSpace(.sRGB) else { return "#000000" }
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", red, green, blue)
    }
}
