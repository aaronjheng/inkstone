import Foundation

/// The two built-in themes: GitHub for light appearances, Night for dark ones.
///
/// Colours are transcribed from `TypeMark/style/themes/<name>.css`. Themes carry
/// colours, font families, and spacing; font *sizes* live in `EditorTheme` as one
/// global type scale (the GitHub reference) that both themes render at. Font
/// families are the documented substitution: the originals ship as web fonts we
/// do not bundle - except Open Sans, which github names and we ship in `Fonts/`.
enum BuiltInTheme {
    static let all: [EditorTheme] = [github, night]

    static func theme(named identifier: String) -> EditorTheme? {
        all.first { $0.identifier == identifier }
    }

    static let identifiers = all.map(\.identifier)

    // MARK: - GitHub

    static let github = EditorTheme(
        identifier: "github",
        displayName: "GitHub",
        background: DynamicColor(0xFFFFFF, 0x333B44),
        // `.mac-seamless-mode #typora-sidebar { background-color: #fafafa }`.
        sidebarBackground: DynamicColor(0xFAFAFA, 0x212121),
        // `--control-text-color: #777` is the item colour; the dark half
        // keeps the theme's editor text (github.css has no dark-side values).
        sidebarForeground: DynamicColor(0x777777, 0xCCCCCC),
        // github.css leaves the active-file pair to Typora's base styles: an
        // `#eeeeee` row with a `#777` leading bar; text stays the item colour.
        sidebarAccent: DynamicColor(0x777777, 0x777777),
        sidebarSelection: DynamicColor(0xEEEEEE, 0x3E4451),
        text: DynamicColor(0x333333, 0xCCCCCC),
        link: DynamicColor(0x4183C4, 0x6CB6FF),
        // `--select-text-bg-color: #B5D6FC` from the original's base style; the
        // theme css does not override it.
        selection: DynamicColor(0xB5D6FC, 0x3E4451),
        marker: DynamicColor(0xC7C5C5, 0x5A6270),
        rawBlockEditingBackground: DynamicColor(0xF5F6F7, 0x2C313A),
        headingChip: DynamicColor(0xDDDDDD, 0x4B5263),
        focusBlur: DynamicColor(0xC8C8C8, 0x4A5058),
        codeBlockBackground: DynamicColor(0xF8F8F8, 0x2F353D),
        codeText: DynamicColor(0x333333, 0xD6DEEB),
        inlineCodeBackground: DynamicColor(0xF3F4F4, 0x31363F),
        inlineCodeText: DynamicColor(0x333333, 0xD6DEEB),
        quoteBar: DynamicColor(0xDFE2E5, 0x4B5263),
        quoteText: DynamicColor(0x777777, 0x9AA4B2),
        rule: DynamicColor(0xE7E7E7, 0x3A4048),
        tableBorder: DynamicColor(0xDFE2E5, 0x444C56),
        tableHeaderBackground: DynamicColor(0xF8F8F8, 0x2F353D),
        tableStripe: DynamicColor(0xF8F8F8, 0x2B3038),
        alertBackground: DynamicColor(0xF1F8FF, 0x1F2A37),
        alertBorder: DynamicColor(0x54AEFF, 0x388BFD),
        syntax: SyntaxPalette(
            keyword: DynamicColor(0xD73A49, 0xFF7B72),
            string: DynamicColor(0x032F62, 0xA5D6FF),
            number: DynamicColor(0x005CC5, 0x79C0FF),
            comment: DynamicColor(0x6A737D, 0x8B949E),
            tag: DynamicColor(0x22863A, 0x7EE787),
            attribute: DynamicColor(0x6F42C1, 0xD2A8FF),
            function: DynamicColor(0x6F42C1, 0xD2A8FF),
            type: DynamicColor(0x005CC5, 0x79C0FF),
            operator: DynamicColor(0xD73A49, 0xFF7B72),
            punctuation: DynamicColor(0x5A5A5A, 0x8B949E),
            plain: DynamicColor(0x333333, 0xC9D1D9),
            marker: DynamicColor(0xD94F8A, 0xFF7B9C)
        ),
        headingRules: [1: DynamicColor(0xEEEEEE, 0x444C56), 2: DynamicColor(0xEEEEEE, 0x444C56)],
        // github.css names `"Open Sans"` for body and headings (the four faces are
        // bundled and registered at startup); headings inherit the body family.
        codeBorder: DynamicColor(0xE7EAED, 0x444C56)
    )

    // MARK: - Night

    /// Night is a full rewrite in the original (1035 lines versus GitHub's 416), using
    /// absolute `rem` sizes and `26px` line heights rather than `em`.
    static let night = EditorTheme(
        identifier: "night",
        displayName: "Night",
        background: DynamicColor(0x363B40, 0x363B40),
        // Night forces a dark surface in both appearances, so its sidebar can't
        // ride the generic chrome pair: the light-side F9F9F9 would sit beside
        // the dark editor under a light system appearance. It shares the
        // theme's own background instead.
        sidebarBackground: DynamicColor(0x2E3033, 0x2E3033),
        // Night's sidebar is its own surface: `--side-bar-bg-color`,
        // `--control-text-color`, `--active-file-bg-color`,
        // `--active-file-text-color`, `--active-file-border-color`,
        // `--item-hover-bg-color`, `--item-hover-text-color`.
        sidebarForeground: DynamicColor(0xB7B7B7, 0xB7B7B7),
        sidebarSecondary: DynamicColor(0xB7B7B7, 0xB7B7B7),
        // `--active-file-border-color: #8d8df0`, Typora's leading bar on the
        // selected row.
        sidebarAccent: DynamicColor(0x8D8DF0, 0x8D8DF0),
        sidebarSelection: DynamicColor(0x222222, 0x222222),
        sidebarSelectionText: DynamicColor(0xFFFFFF, 0xFFFFFF),
        sidebarHover: DynamicColor(0x70717D, 0x70717D),
        sidebarHoverText: DynamicColor(0xFFFFFF, 0xFFFFFF),
        text: DynamicColor(0xB8BFC6, 0xB8BFC6),
        link: DynamicColor(0xE0E0E0, 0xE0E0E0),
        selection: DynamicColor(0x4A5560, 0x4A5560),
        marker: DynamicColor(0x7E8B99, 0x7E8B99),
        rawBlockEditingBackground: DynamicColor(0x3B4147, 0x3B4147),
        headingChip: DynamicColor(0x5A636E, 0x5A636E),
        focusBlur: DynamicColor(0x5A636E, 0x5A636E),
        codeBlockBackground: DynamicColor(0x333333, 0x333333),
        codeText: DynamicColor(0xB8BFC6, 0xB8BFC6),
        inlineCodeBackground: DynamicColor(0x3A3F44, 0x3A3F44),
        inlineCodeText: DynamicColor(0xB8BFC6, 0xB8BFC6),
        quoteBar: DynamicColor(0x4B5259, 0x4B5259),
        quoteText: DynamicColor(0x999999, 0x999999),
        rule: DynamicColor(0x474D54, 0x474D54),
        tableBorder: DynamicColor(0x474D54, 0x474D54),
        tableHeaderBackground: DynamicColor(0x3B4147, 0x3B4147),
        tableStripe: DynamicColor(0x394047, 0x394047),
        alertBackground: DynamicColor(0x3B4147, 0x3B4147),
        alertBorder: DynamicColor(0x4B9FD5, 0x4B9FD5),
        syntax: SyntaxPalette(
            keyword: DynamicColor(0xC792EA, 0xC792EA),
            string: DynamicColor(0xC3E88D, 0xC3E88D),
            number: DynamicColor(0xF78C6C, 0xF78C6C),
            comment: DynamicColor(0x8AA1E1, 0x8AA1E1),
            tag: DynamicColor(0xFF6188, 0xFF6188),
            attribute: DynamicColor(0xFFCB6B, 0xFFCB6B),
            function: DynamicColor(0x82AAFF, 0x82AAFF),
            type: DynamicColor(0xFFCB6B, 0xFFCB6B),
            operator: DynamicColor(0x89DDFF, 0x89DDFF),
            punctuation: DynamicColor(0x89DDFF, 0x89DDFF),
            plain: DynamicColor(0xCCCCCC, 0xCCCCCC),
            marker: DynamicColor(0xCEBCCA, 0xCEBCCA)
        ),
        headingRules: [:],
        // `h1..h6 { color: #DEDEDE }`.
        headingTextColor: DynamicColor(0xDEDEDE, 0xDEDEDE)
    )
}
