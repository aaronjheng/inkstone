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
/// Values are transcribed from `TypeMark/style/themes/*.css`. The `em` sizes in
/// those files are resolved against the theme's root font size.
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
    /// Sidebar item font size; `nil` is the 14pt base (pixyll sets
    /// `#typora-sidebar { font-size: 1rem }` → 16pt).
    var sidebarFontSize: CGFloat?
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

    // MARK: Typography

    /// Root font size. GitHub's `html { font-size: 16px }`.
    var rootFontSize: CGFloat
    /// Multipliers applied to `rootFontSize`, transcribed from the theme's `em`
    /// heading rules.
    var headingScales: [CGFloat]
    var headingWeights: [Font.Weight]
    var headingLineHeights: [CGFloat]
    /// Headings that carry a bottom rule, with its colour.
    var headingRules: [Int: DynamicColor]
    /// Heading colour when the theme sets one (`h1..h6 { color: #DEDEDE }`);
    /// `nil` falls back to `text`.
    var headingTextColor: DynamicColor?
    /// Named heading face when the theme sets one (`"Lucida Grande"` in night);
    /// `nil` falls back to the system face.
    var headingFontName: String?
    /// Per-level `letter-spacing` from the theme (`h1 { letter-spacing: -1.5px }`);
    /// `nil` falls back to zero tracking.
    var headingTracking: [CGFloat]?
    /// Named body face when the theme sets one (`"Helvetica Neue"` in night);
    /// `nil` falls back to the system face.
    var bodyFontName: String?
    var bodyLineHeight: CGFloat
    /// Multiplier on `rootFontSize` for body text, for themes whose `body`
    /// sizes itself independently of the `html` root (pixyll's
    /// `p { font-size: 1.25rem }`).
    var bodyFontScale: CGFloat
    var codeFontScale: CGFloat
    /// Named code face when the theme sets one (`"Monaco"` in night);
    /// `nil` falls back to the system mono face.
    var codeFontName: String?

    // MARK: Metrics

    var contentMaxWidth: CGFloat
    /// Widening breakpoints, matching the theme's `@media` rules.
    var wideMaxWidth: CGFloat
    var widestMaxWidth: CGFloat
    var wideBreakpoint: CGFloat
    var widestBreakpoint: CGFloat
    var contentPadding: CGFloat
    var contentBottomPadding: CGFloat
    var blockMargin: CGFloat
    var headingMargin: CGFloat
    var listIndent: CGFloat
    /// The glyph drawn for an unordered item. Every built-in theme ships `disc`:
    /// Typora renders `disc` even where the theme CSS says `square` (its `#write`
    /// base rules outrank the theme's bare `ul` selector), so matching the
    /// rendered reference means drawing `•` everywhere.
    var listBullet: Character
    var quoteIndent: CGFloat
    var quoteBarWidth: CGFloat
    var codePadding: CGFloat
    /// Left padding for code blocks when the theme's padding is asymmetric
    /// (`pre.md-fences { padding: 10px 10px 10px 30px }`); `nil` uses `codePadding`.
    var codePaddingLeft: CGFloat?
    /// Painted insets around a code block's body, from the theme's
    /// `.md-fences { padding-top: 8px; padding-bottom: 6px }`: the paragraph
    /// style cannot express per-block top/bottom padding, so the decorator
    /// grows the first/last body line's background by these amounts.
    var codePaddingTop: CGFloat
    var codePaddingBottom: CGFloat
    /// `.md-fences, code, tt { border: 1px solid #e7eaed }`; `nil` draws no
    /// border (the base style has none for themes that do not declare one).
    var codeBorder: DynamicColor?
    /// `li p { margin: .5rem 0 }` in the original's base style - the gap between
    /// consecutive list items (`li { margin: 0 }` itself contributes none).
    var listItemSpacing: CGFloat
    /// `hr { margin: 16px 0 }` - the space above a thematic break; the block
    /// after it contributes its own top spacing, as CSS margin collapsing would.
    var ruleMargin: CGFloat
    var tableCellPadding: CGFloat

    // MARK: Derived

    var bodyFontSize: CGFloat { (rootFontSize * bodyFontScale).rounded() }
    var codeFontSize: CGFloat { (bodyFontSize * codeFontScale).rounded() }

    func headingSize(_ level: Int) -> CGFloat {
        let index = min(max(level, 1), headingScales.count) - 1
        return (rootFontSize * headingScales[index]).rounded()
    }

    func headingWeight(_ level: Int) -> Font.Weight {
        let index = min(max(level, 1), headingWeights.count) - 1
        return headingWeights[index]
    }

    func headingLineHeight(_ level: Int) -> CGFloat {
        let index = min(max(level, 1), headingLineHeights.count) - 1
        // Absolute points, not a multiple: the consumer feeds this straight into
        // `NSParagraphStyle.minimumLineHeight`, and scaling by the root size here
        // collapsed an h1 to a 19pt line box that clipped its 36pt glyphs.
        return headingSize(level) * headingLineHeights[index]
    }

    func headingRule(_ level: Int) -> DynamicColor? { headingRules[level] }

    func headingTrackingAmount(_ level: Int) -> CGFloat {
        guard let headingTracking, !headingTracking.isEmpty else { return 0 }
        let index = min(max(level, 1), headingTracking.count) - 1
        return headingTracking[index]
    }

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
        sidebarFontSize: CGFloat? = nil,
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
        rootFontSize: CGFloat,
        headingScales: [CGFloat],
        headingWeights: [Font.Weight],
        headingLineHeights: [CGFloat],
        headingRules: [Int: DynamicColor],
        headingTextColor: DynamicColor? = nil,
        headingFontName: String? = nil,
        headingTracking: [CGFloat]? = nil,
        bodyFontName: String? = nil,
        bodyLineHeight: CGFloat,
        bodyFontScale: CGFloat = 1.0,
        codeFontScale: CGFloat,
        codeFontName: String? = nil,
        contentMaxWidth: CGFloat,
        wideMaxWidth: CGFloat,
        widestMaxWidth: CGFloat,
        wideBreakpoint: CGFloat,
        widestBreakpoint: CGFloat,
        contentPadding: CGFloat,
        contentBottomPadding: CGFloat,
        blockMargin: CGFloat,
        headingMargin: CGFloat,
        listIndent: CGFloat,
        listBullet: Character = "•",
        quoteIndent: CGFloat,
        quoteBarWidth: CGFloat,
        codePadding: CGFloat,
        codePaddingLeft: CGFloat? = nil,
        codePaddingTop: CGFloat = 0,
        codePaddingBottom: CGFloat = 0,
        codeBorder: DynamicColor? = nil,
        listItemSpacing: CGFloat = 0,
        ruleMargin: CGFloat = 0,
        tableCellPadding: CGFloat
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
        self.sidebarFontSize = sidebarFontSize
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
        self.rootFontSize = rootFontSize
        self.headingScales = headingScales
        self.headingWeights = headingWeights
        self.headingLineHeights = headingLineHeights
        self.headingRules = headingRules
        self.headingTextColor = headingTextColor
        self.headingFontName = headingFontName
        self.headingTracking = headingTracking
        self.bodyFontName = bodyFontName
        self.bodyLineHeight = bodyLineHeight
        self.bodyFontScale = bodyFontScale
        self.codeFontScale = codeFontScale
        self.codeFontName = codeFontName
        self.contentMaxWidth = contentMaxWidth
        self.wideMaxWidth = wideMaxWidth
        self.widestMaxWidth = widestMaxWidth
        self.wideBreakpoint = wideBreakpoint
        self.widestBreakpoint = widestBreakpoint
        self.contentPadding = contentPadding
        self.contentBottomPadding = contentBottomPadding
        self.blockMargin = blockMargin
        self.headingMargin = headingMargin
        self.listIndent = listIndent
        self.listBullet = listBullet
        self.quoteIndent = quoteIndent
        self.quoteBarWidth = quoteBarWidth
        self.codePadding = codePadding
        self.codePaddingLeft = codePaddingLeft
        self.codePaddingTop = codePaddingTop
        self.codePaddingBottom = codePaddingBottom
        self.codeBorder = codeBorder
        self.listItemSpacing = listItemSpacing
        self.ruleMargin = ruleMargin
        self.tableCellPadding = tableCellPadding
    }

    /// Typography and spacing scaled by the user's font-size preference.
    func scaled(by factor: CGFloat) -> EditorTheme {
        guard factor > 0, abs(factor - 1) > 0.001 else { return self }
        var copy = self
        copy.rootFontSize = rootFontSize * factor
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

    var rootFontSize: CGFloat?
    var bodyLineHeight: CGFloat?
    var bodyFontScale: CGFloat?
    var contentMaxWidth: CGFloat?
    var contentPadding: CGFloat?
    var listIndent: CGFloat?
    var codeFontScale: CGFloat?

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
        if let rootFontSize { theme.rootFontSize = rootFontSize }
        if let bodyLineHeight { theme.bodyLineHeight = bodyLineHeight }
        if let bodyFontScale { theme.bodyFontScale = bodyFontScale }
        if let contentMaxWidth { theme.contentMaxWidth = contentMaxWidth }
        if let contentPadding { theme.contentPadding = contentPadding }
        if let listIndent { theme.listIndent = listIndent }
        if let codeFontScale { theme.codeFontScale = codeFontScale }
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
