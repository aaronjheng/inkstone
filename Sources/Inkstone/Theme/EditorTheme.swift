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
    var inlineCodeBackground: DynamicColor
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
    /// scale (1 renders body text at 16pt). Set by
    /// `SettingsStore.resolvedTheme`; themes never touch it.
    var fontScale: CGFloat = 1

    /// `html { font-size: 16px }` from github.css, the reference transcription.
    static let baseFontSize: CGFloat = 16
    /// `code, tt { font-size: 0.9em }` from github.css — fractional on purpose:
    /// the reference renders 14.4px and rounds, and rounding here shifted every
    /// code advance (chip widths ~2pt off against the baseline).
    static let codeFontScale: CGFloat = 0.9
    /// `h1..h6 { font-size: 2.25em | 1.75em | 1.5em | 1.25em | 1em | 1em }`.
    static let headingScales: [CGFloat] = [2.25, 1.75, 1.5, 1.25, 1.0, 1.0]
    /// `h1..h6 { line-height: 1.2 | 1.225 | 1.43 | 1.4 | 1.4 | 1.4 }`.
    static let headingLineHeights: [CGFloat] = [1.2, 1.225, 1.43, 1.4, 1.4, 1.4]
    /// github.css sets every heading bold.
    static let headingWeights: [Font.Weight] = [.bold, .bold, .bold, .bold, .bold, .bold]
    /// github.css names `"Open Sans"` for body and headings (the four faces are
    /// bundled and registered at startup).
    static let bodyFontName = "Open Sans"
    static let headingFontName = "Open Sans"
    /// Chromium resolves the theme's `monospace` fallback to Menlo on macOS.
    static let codeFontName = "Menlo"
    /// `body { line-height: 1.6 }`.
    var bodyLineHeight: CGFloat = 1.6

    var contentMaxWidth: CGFloat = 860
    /// Widening breakpoints, matching the theme's `@media` rules.
    var wideMaxWidth: CGFloat = 1024
    var widestMaxWidth: CGFloat = 1200
    var wideBreakpoint: CGFloat = 1400
    var widestBreakpoint: CGFloat = 1800
    var contentPadding: CGFloat = 30
    var contentBottomPadding: CGFloat = 100
    /// `p, blockquote, ul, ol, dl, table { margin: 0.8em 0 }`
    var blockMargin: CGFloat = 12.8
    /// `h1..h6 { margin: 1rem 0 }`
    var headingMargin: CGFloat = 16
    /// `ul, ol { padding-left: 30px }`, so the text column moves 30pt per level.
    /// The reference was re-measured against a rendered document after a 26pt
    /// tightening misfired: the tighter column read heavier than the reference, not
    /// closer to it, and the marker ladder below hangs the glyph at a fixed gap
    /// from the column, exactly like a browser's outside marker.
    var listIndent: CGFloat = 30
    /// `blockquote { padding: 0 15px }`
    var quoteIndent: CGFloat = 15
    var quoteBarWidth: CGFloat = 4
    /// `.md-fences { padding: 8px 0 6px }` plus the CSS cascade's horizontal
    /// inset: `.md-fences` 4px + `.CodeMirror-lines` 4px + `pre` 4px = 12.
    var codePadding: CGFloat = 8
    var codePaddingLeft: CGFloat? = 12
    /// Painted insets around a code block's body, from the theme's
    /// `.md-fences { padding-top: 8px; padding-bottom: 6px }`: the paragraph
    /// style cannot express per-block top/bottom padding, so the decorator
    /// grows the first/last body line's background by these amounts.
    var codePaddingTop: CGFloat = 8
    var codePaddingBottom: CGFloat = 6
    /// `li p { margin: .5rem 0 }` in the original's base style - the gap between
    /// consecutive list items (`li { margin: 0 }` itself contributes none). The
    /// reference renders a 35pt baseline pitch per row (25.6pt line box + 9.4pt),
    /// measured off a rendered document; the bare `.5rem` (8pt) sat a touch tight
    /// and drifted ~1.4pt per item against it.
    var listItemSpacing: CGFloat = 9.4
    /// `hr { margin: 16px 0 }` - the space above a thematic break; the block
    /// after it contributes its own top spacing, as CSS margin collapsing would.
    var ruleMargin: CGFloat = 16
    /// `.md-fences { margin: 15px 0 }` - the space around a fenced code block.
    var fencesMargin: CGFloat = 15
    var tableCellPadding: CGFloat = 6

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
        return (Self.baseFontSize * fontScale * Self.headingScales[index]).rounded()
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
        inlineCodeBackground: DynamicColor,
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
        codeBorder: DynamicColor? = nil
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
        copy.listIndent *= factor
        copy.quoteIndent *= factor
        copy.tableCellPadding *= factor
        copy.codePadding *= factor
        copy.codePaddingTop *= factor
        copy.codePaddingBottom *= factor
        copy.listItemSpacing *= factor
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
        comment: DynamicColor, tag: DynamicColor, attribute: DynamicColor,
        function: DynamicColor, type: DynamicColor, `operator`: DynamicColor,
        punctuation: DynamicColor, plain: DynamicColor, marker: DynamicColor
    ) {
        self.keyword = keyword
        self.string = string
        self.number = number
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
        BuiltInTheme.theme(named: identifier) ?? BuiltInTheme.github
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
