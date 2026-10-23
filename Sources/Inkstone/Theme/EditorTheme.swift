import AppKit
import Foundation
import SwiftUI

/// One Markdown document theme.
///
/// Every value is a token, not a rule. the original expresses a theme as a CSS file
/// with arbitrary selectors and media queries; here a theme is data, which is
/// what makes the editor chrome and the document surface able to share one
/// source of truth and what makes a theme switch a single assignment plus a
/// re-style pass.
///
/// Values are transcribed from `TypeMark/style/themes/*.css`. Themes carry
/// colours, families, and spacing; font *sizes* do not live here - one global
/// type scale (the GitHub reference) serves every theme, scaled uniformly by
/// the user's font-size preference.
struct EditorTheme: Sendable, Equatable {
    let identifier: String
    var displayName: String

    // MARK: Colour

    var background: DynamicColor
    var sidebarBackground: DynamicColor
    /// Sidebar-only colours; `nil` falls back to the editor tokens. Each maps
    /// one Typora sidebar variable: foreground `--control-text-color` (the
    /// item colour; `nil` falls back to `text`), accent
    /// `--active-file-border-color` (the leading bar on the selected row;
    /// `nil` draws none), selection `--active-file-bg-color`, selectionText
    /// `--active-file-text-color`, hover `--item-hover-bg-color`, hoverText
    /// `--item-hover-text-color`.
    var sidebarForeground: DynamicColor?
    var sidebarSecondary: DynamicColor?
    var sidebarAccent: DynamicColor?
    var sidebarSelection: DynamicColor?
    var sidebarSelectionText: DynamicColor?
    var sidebarHover: DynamicColor?
    var sidebarHoverText: DynamicColor?
    var text: DynamicColor
    var link: DynamicColor
    var selection: DynamicColor
    var marker: DynamicColor
    var rawBlockEditingBackground: DynamicColor
    var headingChip: DynamicColor
    var focusBlur: DynamicColor

    var codeBlockBackground: DynamicColor
    var codeText: DynamicColor
    /// `nil` renders inline code as bare mono text — the VS Code preview has
    /// no `code` background, padding or border.
    var inlineCodeBackground: DynamicColor?
    var inlineCodeText: DynamicColor
    var quoteBar: DynamicColor
    var quoteText: DynamicColor
    var rule: DynamicColor
    var tableBorder: DynamicColor
    var tableHeaderBackground: DynamicColor
    var tableStripe: DynamicColor
    var alertBackground: DynamicColor
    var alertBorder: DynamicColor

    /// The palette providing surfaces, washes, and syntax hues for this theme.
    /// When `nil`, the theme falls back to the active system palette.
    var palette: ThemePalette? = ThemePalette.systemLight

    var syntax: SyntaxPalette

    // MARK: Type scale and layout (global - not themed)

    /// Themes colour the document; everything here is shared by both.

    /// The user's font-size preference as a multiplier on the reference type
    /// scale (1 renders body text at 14pt). Set by
    /// `SettingsStore.resolvedTheme`; themes never touch it.
    var fontScale: CGFloat = 1

    /// `markdown.preview.fontSize` default 14 — the VS Code preview's base.
    static let baseFontSize: CGFloat = 14
    /// `code { font-size: 1em }` — VS Code's inline and block code render at
    /// the body size, unlike Typora's 0.9em.
    static let codeFontScale: CGFloat = 1.0
    /// `h1..h6 { font-size: 2em | 1.5em | 1.25em | 1em | 0.875em | 0.85em }`.
    static let headingScales: [CGFloat] = [2.0, 1.5, 1.25, 1.0, 0.875, 0.85]
    /// `h1..h6 { line-height: 1.25 }`.
    static let headingLineHeights: [CGFloat] = [1.25, 1.25, 1.25, 1.25, 1.25, 1.25]
    /// markdown.css sets every heading weight 600.
    static let headingWeights: [Font.Weight] = [.semibold, .semibold, .semibold, .semibold, .semibold, .semibold]
    /// The preview body resolves `-apple-system` — the system face. An empty
    /// name makes `EditorFont.nsBody/nsHeading` fall back to `NSFont.systemFont`.
    static let bodyFontName = ""
    static let headingFontName = ""
    /// The preview's editor font stack pins to Menlo for parity (SF Mono, the
    /// stack's first entry, is not installed system-wide for Chromium).
    static let codeFontName = "Menlo"
    /// `body { line-height: 1.6 }`.
    var bodyLineHeight: CGFloat = 1.6

    var contentMaxWidth: CGFloat = 1_000_000
    /// The preview centres nothing: the content spans the webview minus the
    /// body's `padding: 0 26px`, at every width.
    var wideMaxWidth: CGFloat = 1_000_000
    var widestMaxWidth: CGFloat = 1_000_000
    var wideBreakpoint: CGFloat = 1_000_000
    var widestBreakpoint: CGFloat = 1_000_000
    var contentPadding: CGFloat = 26
    var contentBottomPadding: CGFloat = 50
    /// `p { margin-bottom: 16px; margin-top: 0 }`.
    var blockMargin: CGFloat = 16
    /// `h1..h6 { margin-top: 24px; margin-bottom: 16px }` — except `h1
    /// { margin-top: 0 }`. The top margin rides on `headingMarginTop`, which
    /// `BlockStyle.heading` zeroes for level 1.
    var headingMargin: CGFloat = 16
    var headingMarginTop: CGFloat = 24
    /// `ul, ol { padding-inline-start: 40px }` — the UA default the preview
    /// leaves in place, so the text column moves 40pt per level.
    var listIndent: CGFloat = 40
    /// `blockquote { padding: 0px 16px 0 10px; border-left-width: 5px }` —
    /// the text column sits `quoteBarWidth + quoteIndent` = 15pt in from the
    /// quote's left edge (the 5px bar, then the 10px padding).
    var quoteIndent: CGFloat = 10
    var quoteBarWidth: CGFloat = 5
    /// The quote's right padding (`padding: 0px 16px 0 10px`): wrap width and
    /// nested fills clamp 16pt short of the quote's right edge.
    var quoteRightPadding: CGFloat = 16
    /// The fenced block's box carries NO padding in the preview: the padding
    /// rule (`pre:not(.hljs), pre.hljs code > div`) matches nothing the engine
    /// produces — every fenced block gets the `hljs` class and no inner div
    /// (measured on the reference render). The glyphs sit flush against the
    /// 1px border.
    var codePadding: CGFloat = 0
    var codePaddingLeft: CGFloat? = 0
    var codePaddingTop: CGFloat = 0
    var codePaddingBottom: CGFloat = 0
    /// `li p { margin-bottom: 0.7em }` — the gap between consecutive list
    /// items (li carries no margins of its own).
    var listItemSpacing: CGFloat = 9.8
    /// `li p, blockquote p { margin-bottom: 0.7em }` - the margin a collapsed
    /// blank line inside a quote stands in for.
    var blankLineMargin: CGFloat = 9.8
    /// `hr { margin: 0.5em 0 }` — 7pt at the 14px base.
    var ruleMargin: CGFloat = 7
    /// `pre { margin: 0 0 1em }` — margin-top is reset, the UA bottom stays.
    var fencesMargin: CGFloat = 14
    /// `th, td { padding: 5px 10px }`.
    var tableCellPadding: CGFloat = 5
    var tableCellPaddingX: CGFloat = 10
    /// `th { border-bottom: 1px solid }` — the header's rule is the preview's
    /// darker `th` colour; body row separators use `tableBorder`.
    var tableHeaderBorder: DynamicColor = DynamicColor(0x4F4F4F, 0x9E9E9E)

    // MARK: Colour (themed)

    /// Headings that carry a bottom rule, with its colour.
    var headingRules: [Int: DynamicColor]
    /// Heading colour when the theme sets one (`h1..h6 { color: #DEDEDE }`);
    /// `nil` falls back to `text`.
    var headingTextColor: DynamicColor?
    /// `.md-fences, code, tt { border: 1px solid #e7eaed }`; `nil` draws no
    /// border (the base style has none for themes that do not declare one).
    var codeBorder: DynamicColor?

    // MARK: Derived

    var bodyFontSize: CGFloat { (Self.baseFontSize * fontScale).rounded() }
    var codeFontSize: CGFloat { bodyFontSize * Self.codeFontScale }

    /// The glyph drawn for an unordered item at a 1-based nesting `depth`.
    ///
    /// Typora's `#write` base leaves `list-style-type` to the browser default,
    /// so Chromium renders its UA ladder - `disc`, then `circle`, then `square`
    /// for the third and deeper levels - rather than a flat `disc`.
    func listBullet(depth: Int) -> Character {
        switch max(depth, 1) {
        case 1: return "•"
        case 2: return "◦"
        default: return "▪"
        }
    }

    func headingSize(_ level: Int) -> CGFloat {
        let index = min(max(level, 1), Self.headingScales.count) - 1
        // Fractional on purpose: the preview keeps Chromium's fractional sizes
        // (h5 renders 12.25px), and rounding shifted the line heights.
        return Self.baseFontSize * fontScale * Self.headingScales[index]
    }

    func headingWeight(_ level: Int) -> Font.Weight {
        let index = min(max(level, 1), Self.headingWeights.count) - 1
        return Self.headingWeights[index]
    }

    func headingLineHeight(_ level: Int) -> CGFloat {
        let index = min(max(level, 1), Self.headingLineHeights.count) - 1
        // Absolute points, not a multiple: the consumer feeds this straight into
        // `NSParagraphStyle.minimumLineHeight`, and scaling by the root size here
        // collapsed an h1 to a 19pt line box that clipped its 36pt glyphs.
        return headingSize(level) * Self.headingLineHeights[index]
    }

    func headingRule(_ level: Int) -> DynamicColor? { headingRules[level] }

    /// The measure to use for a given viewport width, honouring the breakpoints.
    func contentWidth(for viewport: CGFloat) -> CGFloat {
        let usable = viewport - contentPadding * 2
        if viewport >= widestBreakpoint { return min(usable, widestMaxWidth) }
        if viewport >= wideBreakpoint { return min(usable, wideMaxWidth) }
        return min(usable, contentMaxWidth)
    }

    /// Memberwise initialiser with defaults, so a user theme file may specify any
    /// subset of the fields and the rest fall back to GitHub's values before being
    /// merged onto the built-in theme with the same identifier.
    init(
        identifier: String,
        displayName: String,
        background: DynamicColor,
        sidebarBackground: DynamicColor = DynamicColor(0xF9F9F9, 0x212121),
        sidebarForeground: DynamicColor? = nil,
        sidebarSecondary: DynamicColor? = nil,
        sidebarAccent: DynamicColor? = nil,
        sidebarSelection: DynamicColor? = nil,
        sidebarSelectionText: DynamicColor? = nil,
        sidebarHover: DynamicColor? = nil,
        sidebarHoverText: DynamicColor? = nil,
        text: DynamicColor,
        link: DynamicColor,
        selection: DynamicColor,
        marker: DynamicColor,
        rawBlockEditingBackground: DynamicColor,
        headingChip: DynamicColor,
        focusBlur: DynamicColor,
        codeBlockBackground: DynamicColor,
        codeText: DynamicColor,
        inlineCodeBackground: DynamicColor?,
        inlineCodeText: DynamicColor,
        quoteBar: DynamicColor,
        quoteText: DynamicColor,
        rule: DynamicColor,
        tableBorder: DynamicColor,
        tableHeaderBackground: DynamicColor,
        tableStripe: DynamicColor,
        alertBackground: DynamicColor,
        alertBorder: DynamicColor,
        syntax: SyntaxPalette,
        headingRules: [Int: DynamicColor] = [:],
        headingTextColor: DynamicColor? = nil,
        codeBorder: DynamicColor? = nil,
        headingMarginTop: CGFloat = 24,
        tableCellPaddingX: CGFloat = 10,
        quoteRightPadding: CGFloat = 16,
        tableHeaderBorder: DynamicColor = DynamicColor(0x4F4F4F, 0x9E9E9E)
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.background = background
        self.sidebarBackground = sidebarBackground
        self.sidebarForeground = sidebarForeground
        self.sidebarSecondary = sidebarSecondary
        self.sidebarAccent = sidebarAccent
        self.sidebarSelection = sidebarSelection
        self.sidebarSelectionText = sidebarSelectionText
        self.sidebarHover = sidebarHover
        self.sidebarHoverText = sidebarHoverText
        self.text = text
        self.link = link
        self.selection = selection
        self.marker = marker
        self.rawBlockEditingBackground = rawBlockEditingBackground
        self.headingChip = headingChip
        self.focusBlur = focusBlur
        self.codeBlockBackground = codeBlockBackground
        self.codeText = codeText
        self.inlineCodeBackground = inlineCodeBackground
        self.inlineCodeText = inlineCodeText
        self.quoteBar = quoteBar
        self.quoteText = quoteText
        self.rule = rule
        self.tableBorder = tableBorder
        self.tableHeaderBackground = tableHeaderBackground
        self.tableStripe = tableStripe
        self.alertBackground = alertBackground
        self.alertBorder = alertBorder
        self.syntax = syntax
        self.headingRules = headingRules
        self.headingTextColor = headingTextColor
        self.codeBorder = codeBorder
        self.headingMarginTop = headingMarginTop
        self.tableCellPaddingX = tableCellPaddingX
        self.quoteRightPadding = quoteRightPadding
        self.tableHeaderBorder = tableHeaderBorder
    }

    /// Typography and spacing scaled by the user's font-size preference.
    func scaled(by factor: CGFloat) -> EditorTheme {
        guard factor > 0, abs(factor - 1) > 0.001 else { return self }
        var copy = self
        copy.fontScale = fontScale * factor
        copy.contentPadding *= factor
        copy.contentBottomPadding *= factor
        copy.blockMargin *= factor
        copy.headingMargin *= factor
        copy.headingMarginTop *= factor
        copy.listIndent *= factor
        copy.quoteIndent *= factor
        copy.quoteRightPadding *= factor
        copy.tableCellPadding *= factor
        copy.tableCellPaddingX *= factor
        copy.codePadding *= factor
        copy.codePaddingTop *= factor
        copy.codePaddingBottom *= factor
        copy.listItemSpacing *= factor
        copy.blankLineMargin *= factor
        copy.ruleMargin *= factor
        copy.fencesMargin *= factor
        return copy
    }
}

/// Token colours for fenced code and inline math source.
struct SyntaxPalette: Sendable, Equatable {
    var keyword: DynamicColor
    var string: DynamicColor
    var number: DynamicColor
    var literal: DynamicColor
    var comment: DynamicColor
    var tag: DynamicColor
    var attribute: DynamicColor
    var function: DynamicColor
    var type: DynamicColor
    var `operator`: DynamicColor
    var punctuation: DynamicColor
    var plain: DynamicColor
    /// The source-mode colour for heading markers (`cm-header`).
    var marker: DynamicColor

    init(
        keyword: DynamicColor, string: DynamicColor, number: DynamicColor,
        literal: DynamicColor? = nil,
        comment: DynamicColor, tag: DynamicColor, attribute: DynamicColor,
        function: DynamicColor, type: DynamicColor, `operator`: DynamicColor,
        punctuation: DynamicColor, plain: DynamicColor, marker: DynamicColor
    ) {
        self.keyword = keyword
        self.string = string
        self.number = number
        // Themes modelled on a highlighter that colours literals differently
        // from numbers (the reference's `hljs-literal`) set this explicitly;
        // the rest reuse the number slot.
        self.literal = literal ?? number
        self.comment = comment
        self.tag = tag
        self.attribute = attribute
        self.function = function
        self.type = type
        self.operator = `operator`
        self.punctuation = punctuation
        self.plain = plain
        self.marker = marker
    }

    /// Creates the syntax palette from the active `ThemePalette`, resolving
    /// light and dark syntax colours automatically.
    init(palette: ThemePalette) {
        self.init(
            keyword: DynamicColor(light: ThemePalette.systemLight.syntaxKey, dark: ThemePalette.neutralDark.syntaxKey),
            string: DynamicColor(light: ThemePalette.systemLight.syntaxString, dark: ThemePalette.neutralDark.syntaxString),
            number: DynamicColor(light: ThemePalette.systemLight.syntaxNumber, dark: ThemePalette.neutralDark.syntaxNumber),
            comment: DynamicColor(light: NSColor.systemGray, dark: NSColor.systemGray),
            tag: DynamicColor(light: ThemePalette.systemLight.syntaxBuiltin, dark: ThemePalette.neutralDark.syntaxBuiltin),
            attribute: DynamicColor(light: ThemePalette.systemLight.syntaxType, dark: ThemePalette.neutralDark.syntaxType),
            function: DynamicColor(light: ThemePalette.systemLight.syntaxBuiltin, dark: ThemePalette.neutralDark.syntaxBuiltin),
            type: DynamicColor(light: ThemePalette.systemLight.syntaxType, dark: ThemePalette.neutralDark.syntaxType),
            operator: DynamicColor(light: ThemePalette.systemLight.syntaxKey, dark: ThemePalette.neutralDark.syntaxKey),
            punctuation: DynamicColor(light: NSColor.systemGray, dark: NSColor.systemGray),
            plain: DynamicColor(light: NSColor.labelColor, dark: NSColor.labelColor),
            marker: DynamicColor(light: NSColor.systemGray, dark: NSColor.systemGray)
        )
    }
}

/// A partial theme, as a user theme file expresses it.
///
/// Only the things a person actually wants to change are representable, and every
/// one of them is optional. A file that sets two colours is a valid theme; the
/// rest comes from the built-in theme with the same identifier. That is the native
/// equivalent of the original's `base.user.css` / `<theme>.user.css` layering, without
/// asking the user to author CSS.
struct ThemeOverride: Codable, Sendable {
    /// Must match a built-in theme's identifier so the rest can be inherited.
    var identifier: String
    var displayName: String?

    var background: DynamicColor?
    var text: DynamicColor?
    var link: DynamicColor?
    var marker: DynamicColor?
    var codeBlockBackground: DynamicColor?
    var codeText: DynamicColor?
    var inlineCodeBackground: DynamicColor?
    var quoteBar: DynamicColor?
    var quoteText: DynamicColor?
    var rule: DynamicColor?
    var tableBorder: DynamicColor?
    var focusBlur: DynamicColor?

    var bodyLineHeight: CGFloat?
    var contentMaxWidth: CGFloat?
    var contentPadding: CGFloat?
    var listIndent: CGFloat?

    var syntaxKeyword: DynamicColor?
    var syntaxString: DynamicColor?
    var syntaxComment: DynamicColor?
    var syntaxNumber: DynamicColor?
    var syntaxMarker: DynamicColor?

    /// The built-in theme this override applies on top of.
    var base: EditorTheme {
        BuiltInTheme.theme(named: identifier) ?? BuiltInTheme.vscode
    }

    /// Applies the set fields. Unset fields keep the base theme's value.
    func applied() -> EditorTheme {
        var theme = base
        if let displayName { theme.displayName = displayName }
        if let background { theme.background = background }
        if let text { theme.text = text }
        if let link { theme.link = link }
        if let marker { theme.marker = marker }
        if let codeBlockBackground { theme.codeBlockBackground = codeBlockBackground }
        if let codeText { theme.codeText = codeText }
        if let inlineCodeBackground { theme.inlineCodeBackground = inlineCodeBackground }
        if let quoteBar { theme.quoteBar = quoteBar }
        if let quoteText { theme.quoteText = quoteText }
        if let rule { theme.rule = rule }
        if let tableBorder { theme.tableBorder = tableBorder }
        if let focusBlur { theme.focusBlur = focusBlur }
        if let bodyLineHeight { theme.bodyLineHeight = bodyLineHeight }
        if let contentMaxWidth { theme.contentMaxWidth = contentMaxWidth }
        if let contentPadding { theme.contentPadding = contentPadding }
        if let listIndent { theme.listIndent = listIndent }
        if let syntaxKeyword { theme.syntax.keyword = syntaxKeyword }
        if let syntaxString { theme.syntax.string = syntaxString }
        if let syntaxComment { theme.syntax.comment = syntaxComment }
        if let syntaxNumber { theme.syntax.number = syntaxNumber }
        if let syntaxMarker { theme.syntax.marker = syntaxMarker }
        return theme
    }
}

extension DynamicColor: Codable {
    /// Encoded as `{ "light": "#rrggbb", "dark": "#rrggbb" }`, which is the shape
    /// a person would write in a theme file and diff in review.
    enum CodingKeys: String, CodingKey {
        case light, dark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let light = try container.decode(UInt32.self, forKey: .light)
        let dark = try container.decode(UInt32.self, forKey: .dark)
        self.init(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(light.hexValue, forKey: .light)
        try container.encode(dark.hexValue, forKey: .dark)
    }
}

extension NSColor {
    /// The nearest 0xRRGGBB value, for round-tripping a theme file.
    var hexValue: UInt32 {
        let red = Int((redComponent * 255).rounded())
        let green = Int((greenComponent * 255).rounded())
        let blue = Int((blueComponent * 255).rounded())
        return UInt32(red << 16 | green << 8 | blue)
    }
}
