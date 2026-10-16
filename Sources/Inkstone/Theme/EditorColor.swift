import AppKit
import Foundation
import SwiftUI

/// A colour that follows the system appearance.
///
/// Themes are authored as explicit light/dark pairs (the original's CSS does the same,
/// with a doubled declaration for older WebKit). Wrapping them in a dynamic
/// `NSColor` means switching appearance needs no re-render at all - the token is
/// identical, only its resolved value changes.
struct DynamicColor: Hashable, Sendable {
    let light: NSColor
    let dark: NSColor

    init(light: NSColor, dark: NSColor) {
        self.light = light
        self.dark = dark
    }

    var nsColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    init(_ light: UInt32, _ dark: UInt32) {
        self.init(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }
}

extension NSColor {
    /// `0xRRGGBB`, alpha always 1.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    convenience init(hex: UInt32, alpha: CGFloat) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Token colours shared by the editor chrome and the document surface.
///
/// Values come from the original's `:root` custom properties (`base.css`,
/// `base-control.css`, `window.css`), which is where the original engine keeps
/// everything that is not a content rule.
enum EditorColor {
    /// `--bg-color` / `--text-color` — derived from the active palette.
    static let background: DynamicColor = DynamicColor(
        light: ThemePalette.systemLight.windowBackground,
        dark: ThemePalette.neutralDark.windowBackground)
    static let text: DynamicColor = DynamicColor(0x333333, 0xCCCCCC)

    /// `--side-bar-bg-color` — derived from the active palette.
    static let sidebarBackground: DynamicColor = DynamicColor(
        light: ThemePalette.systemLight.sidebarBackground,
        dark: ThemePalette.neutralDark.sidebarBackground)

    /// `--select-text-bg-color`
    static let selection = DynamicColor(0xDAE3EA, 0x3E4451)

    /// `--md-char-color` — syntax markers derived from palette.
    static let marker: DynamicColor = DynamicColor(
        light: ThemePalette.systemLight.syntaxBool,
        dark: ThemePalette.neutralDark.syntaxBool)

    /// `--rawblock-edit-panel-bd` — derived from palette.
    static let rawBlockEditingBackground: DynamicColor = DynamicColor(
        light: ThemePalette.systemLight.secondaryBackground,
        dark: ThemePalette.neutralDark.secondaryBackground)

    /// `--heading-char-color` — derived from palette.
    static let headingChip: DynamicColor = DynamicColor(
        light: ThemePalette.systemLight.pillBackground,
        dark: ThemePalette.neutralDark.pillBackground)

    /// `--blur-text-color` — derived from palette.
    static let focusBlur: DynamicColor = DynamicColor(
        light: ThemePalette.systemLight.pillBackground,
        dark: ThemePalette.neutralDark.pillBackground)

    static let link = DynamicColor(0x4183C4, 0x6CB6FF)
    static let quoteText = DynamicColor(0x777777, 0x9AA4B2)
    static let rule = DynamicColor(0xE7E7E7, 0x3A4048)
    static let codeText = DynamicColor(0x333333, 0xD6DEEB)
    static let caret = DynamicColor(0x0969DA, 0x7CB0FF)

    static func status(_ code: Int) -> DynamicColor {
        switch code {
        case 200..<300: DynamicColor(0x1A7F37, 0x3FB950)
        case 300..<400: DynamicColor(0x0969DA, 0x58A6FF)
        case 400..<500: DynamicColor(0x9A6700, 0xD29922)
        default: DynamicColor(0xCF222E, 0xF85149)
        }
    }
}

/// Font tokens for the document surface.
enum EditorFont {
    /// Theme-selected body face. the original themes name web fonts; we use the system
    /// stack and record the substitution (DESIGN.md §7).
    static func body(theme: EditorTheme) -> Font {
        .system(size: theme.bodyFontSize)
    }

    static func heading(theme: EditorTheme, level: Int) -> Font {
        let size = theme.headingSize(level)
        let weight: Font.Weight = theme.headingWeight(level)
        return .system(size: size, weight: weight)
    }

    static let mono = Font.system(size: 13, design: .monospaced)
    static let code = Font.system(size: 13, design: .monospaced)
    static let small = Font.system(size: 11)
    static let gutter = Font.system(size: 9, weight: .semibold)

    /// Matches the `NSTextView` default typing font; kept in sync by
    /// `EditorTheme.scaleFactor` rather than hard-coded, so a theme font-size
    /// change moves both.
    static func nsMono(size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Body face. A theme that names a face (`night` uses Helvetica Neue,
    /// which ships with macOS) gets it.
    static func nsBody(theme: EditorTheme) -> NSFont {
        if let font = NSFont(name: EditorTheme.bodyFontName, size: theme.bodyFontSize) {
            return font
        }
        return .systemFont(ofSize: theme.bodyFontSize)
    }

    /// Code face. A theme that names one (`night` uses Monaco) gets it; the
    /// fallback is the system mono face.
    static func nsMono(theme: EditorTheme, size: CGFloat) -> NSFont {
        if let font = NSFont(name: EditorTheme.codeFontName, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func nsSystem(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    /// Heading face. A theme that names a face (`night` uses Lucida Grande,
    /// which ships with macOS) gets it; the bold levels are converted with the
    /// font manager so one family covers both weights.
    static func nsHeading(theme: EditorTheme, level: Int, weight: NSFont.Weight) -> NSFont {
        let size = theme.headingSize(level)
        if let named = NSFont(name: EditorTheme.headingFontName, size: size) {
            if weight.rawValue >= NSFont.Weight.bold.rawValue {
                let bold = NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask)
                if bold.fontName != named.fontName { return bold }
            }
            return named
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// Math face: serif and italic, matching TeX's default variables.
    ///
    /// There is no TeX engine here and MathJax is forbidden, so a display formula
    /// cannot be typeset. Rendering the source in the face and metrics TeX would use
    /// is what keeps a math block legible instead of looking like a stray code line.
    static func nsMath(size: CGFloat) -> NSFont {
        let named = NSFont(name: "TimesNewRomanPS-ItalicMT", size: size)
        let base = named ?? NSFont.systemFont(ofSize: size)
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }
}

/// Spacing, radius, line-width and opacity tokens.
///
/// A single value per line of Swift rather than one enum per axis: these are
/// used close together, and splitting them across enums makes call sites longer
/// without making the relationships clearer.
enum EditorMetrics {
    static let tiny: CGFloat = 2
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24

    static let radiusSmall: CGFloat = 3
    static let radiusMedium: CGFloat = 5
    static let radiusLarge: CGFloat = 8

    static let hairline: CGFloat = 1
    static let focusRing: CGFloat = 2

    static let controlHeight: CGFloat = 24
    static let sidebarWidth: CGFloat = 270

    static let markerBackgroundAlpha: CGFloat = 0.22
    static let searchHighlightAlpha: CGFloat = 0.35
    static let searchCurrentAlpha: CGFloat = 0.62
    static let quoteBarAlpha: CGFloat = 0.85
}
