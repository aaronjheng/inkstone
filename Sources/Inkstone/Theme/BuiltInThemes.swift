import Foundation

/// The two built-in themes: VS Code for light appearances, Night for dark ones.
///
/// The light theme transcribes VS Code's markdown preview (`markdown.css` +
/// the Light Modern palette), the open-source alignment target. Themes carry
/// colours and spacing; font *sizes* live in `EditorTheme` as one global type
/// scale (the preview's) that both themes render at. The body face is the
/// system font (`-apple-system`); the mono face is Menlo (the preview stack's
/// first installed entry).
enum BuiltInTheme {
    static let all: [EditorTheme] = [vscode, night]

    static func theme(named identifier: String) -> EditorTheme? {
        all.first { $0.identifier == identifier }
    }

    static let identifiers = all.map(\.identifier)

    // MARK: - VS Code

    static let vscode = EditorTheme(
        identifier: "vscode",
        displayName: "VS Code",
        background: DynamicColor(0xFFFFFF, 0x1E1E1E),
        // `.mac-seamless-mode #typora-sidebar { background-color: #fafafa }`.
        sidebarBackground: DynamicColor(0xFAFAFA, 0x212121),
        // `--control-text-color: #777` is the item colour; the dark half
        // keeps the theme's editor text (github.css has no dark-side values).
        sidebarForeground: DynamicColor(0x777777, 0xCCCCCC),
        // github.css leaves the active-file pair to Typora's base styles: an
        // `#eeeeee` row with a `#777` leading bar; text stays the item colour.
        sidebarAccent: DynamicColor(0x777777, 0x777777),
        sidebarSelection: DynamicColor(0xEEEEEE, 0x3E4451),
        text: DynamicColor(0x3B3B3B, 0xBBBBBB),
        link: DynamicColor(0x006AB1, 0x4DAFF2),
        // `--select-text-bg-color: #B5D6FC` from the original's base style; the
        // theme css does not override it.
        selection: DynamicColor(0xB5D6FC, 0x3E4451),
        marker: DynamicColor(0x3B3B3B, 0xBBBBBB),
        rawBlockEditingBackground: DynamicColor(0xF5F6F7, 0x2C313A),
        headingChip: DynamicColor(0xDDDDDD, 0x4B5263),
        focusBlur: DynamicColor(0xC8C8C8, 0x4A5058),
        codeBlockBackground: DynamicColor(0xF8F8F8, 0x2A2A2A),
        codeText: DynamicColor(0x3B3B3B, 0xBBBBBB),
        inlineCodeBackground: nil,
        inlineCodeText: DynamicColor(0x3B3B3B, 0xBBBBBB),
        quoteBar: DynamicColor(0x3B3B3B, 0xBBBBBB),
        quoteText: DynamicColor(0x3B3B3B, 0xBBBBBB),
        rule: DynamicColor(0xD1D1D1, 0x3C3C3C),
        tableBorder: DynamicColor(0xD1D1D1, 0x3C3C3C),
        tableHeaderBackground: DynamicColor(0xFFFFFF, 0x1E1E1E),
        tableStripe: DynamicColor(0xFFFFFF, 0x1E1E1E),
        alertBackground: DynamicColor(0xF1F8FF, 0x1F2A37),
        alertBorder: DynamicColor(0x54AEFF, 0x388BFD),
        syntax: SyntaxPalette(
            // The reference's code colours are the static highlight.css applied
            // over highlight.js 11.8 token classes: the base rules are the
            // vs2015 dark style and the `.vscode-light` overrides win for the
            // light half (keyword #00f, string/attribute/type #a31515, number
            // #008000, comment #008000 italic, tag #00f, attr #f00, title
            // #808080). The dark half is the base style. Operators and
            // punctuation are unclassed in highlight.js and stay the code's
            // plain colour; literals (`false`, `null`) colour separately from
            // numbers (`hljs-literal`).
            keyword: DynamicColor(0x0000FF, 0x569CD6),
            string: DynamicColor(0xA31515, 0xD69D85),
            number: DynamicColor(0x008000, 0xB8D7A3),
            literal: DynamicColor(0xA31515, 0x569CD6),
            comment: DynamicColor(0x008000, 0x57A64A),
            tag: DynamicColor(0x0000FF, 0x9B9B9B),
            attribute: DynamicColor(0xFF0000, 0x9CDCFE),
            function: DynamicColor(0x808080, 0xDCDCDC),
            type: DynamicColor(0xA31515, 0x4EC9B0),
            operator: DynamicColor(0x3B3B3B, 0xBBBBBB),
            punctuation: DynamicColor(0x3B3B3B, 0xBBBBBB),
            plain: DynamicColor(0x3B3B3B, 0xBBBBBB),
            marker: DynamicColor(0xD94F8A, 0xFF7B9C)
        ),
        headingRules: [1: DynamicColor(0xD1D1D1, 0x3C3C3C), 2: DynamicColor(0xD1D1D1, 0x3C3C3C)],
        // github.css names `"Open Sans"` for body and headings (the four faces are
        // bundled and registered at startup); headings inherit the body family.
        codeBorder: DynamicColor(0xE5E5E5, 0x3C3C3C)
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
