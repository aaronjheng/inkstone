import AppKit
import SwiftUI

/// Semantic colour tokens for the editor chrome, sidebar, and content
/// surfaces. Every token resolves from the active `ThemePalette` side, so
/// switching appearance (or introducing a selectable theme later) requires
/// zero call-site changes.
///
/// Washes (translucent fills for hover, press, track, banner states) stay alpha
/// strengths inside the palette; the base colour (`labelColor`, `systemRed`,
/// `systemOrange`) is resolved at draw time, ensuring the same wash reads
/// correctly on both light and dark.
enum AppThemeColor {

    // MARK: Backgrounds

    static var windowBackground: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.windowBackground
                        : ThemePalette.systemLight.windowBackground
                }))
    }

    static var windowBackgroundNS: NSColor {
        NSColor(
            name: nil,
            dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? ThemePalette.neutralDark.windowBackground
                    : ThemePalette.systemLight.windowBackground
            })
    }

    static var secondaryBackground: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.secondaryBackground
                        : ThemePalette.systemLight.secondaryBackground
                }))
    }

    static var sidebarBackground: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.sidebarBackground
                        : ThemePalette.systemLight.sidebarBackground
                }))
    }

    static var pillBackground: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.pillBackground
                        : ThemePalette.systemLight.pillBackground
                }))
    }

    static var codeBackground: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.codeBackground
                        : ThemePalette.systemLight.codeBackground
                }))
    }

    static var fieldHoverBackground: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.fieldHoverBackground
                        : ThemePalette.systemLight.fieldHoverBackground
                }))
    }

    static var fieldFocusBackground: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.fieldFocusBackground
                        : ThemePalette.systemLight.fieldFocusBackground
                }))
    }

    // MARK: Interactive washes

    /// Hover wash for rows and custom controls.
    static var hoverBackground: Color {
        adaptiveWash(ThemePalette.systemLight.hoverBackground, ThemePalette.neutralDark.hoverBackground)
    }

    /// Hover wash for small icon buttons.
    static var iconHoverBackground: Color {
        adaptiveWash(ThemePalette.systemLight.iconHoverBackground, ThemePalette.neutralDark.iconHoverBackground)
    }

    /// Pressed / selected fill.
    static var controlFillBackground: Color {
        adaptiveWash(ThemePalette.systemLight.controlFillBackground, ThemePalette.neutralDark.controlFillBackground)
    }

    /// Subtle fill for badges and secondary chrome.
    static var subtleBackground: Color {
        adaptiveWash(ThemePalette.systemLight.subtleBackground, ThemePalette.neutralDark.subtleBackground)
    }

    /// Hairline stroke / border.
    static var subtleBorder: Color {
        adaptiveWash(ThemePalette.systemLight.subtleBorder, ThemePalette.neutralDark.subtleBorder)
    }

    /// Sidebar tint layered over the opaque base.
    static var sidebarTint: Color {
        adaptiveWash(ThemePalette.systemLight.sidebarTint, ThemePalette.neutralDark.sidebarTint)
    }

    /// Track background for meters.
    static var trackBackground: Color {
        adaptiveWash(ThemePalette.systemLight.trackBackground, ThemePalette.neutralDark.trackBackground)
    }

    /// Shell output block background.
    static var shellOutputBackground: Color {
        adaptiveWash(ThemePalette.systemLight.shellOutputBackground, ThemePalette.neutralDark.shellOutputBackground)
    }

    /// Destructive hover / press feedback (over `systemRed`).
    static var destructiveBackground: Color {
        adaptiveWash(
            ThemePalette.systemLight.destructiveBackground,
            ThemePalette.neutralDark.destructiveBackground,
            baseColor: NSColor.systemRed
        )
    }

    /// Error banner fill (over `systemRed`).
    static var errorBannerBackground: Color {
        adaptiveWash(
            ThemePalette.systemLight.errorBannerBackground,
            ThemePalette.neutralDark.errorBannerBackground,
            baseColor: NSColor.systemRed
        )
    }

    /// Warning banner fill (over `systemOrange`).
    static var warningBannerBackground: Color {
        adaptiveWash(
            ThemePalette.systemLight.warningBannerBackground,
            ThemePalette.neutralDark.warningBannerBackground,
            baseColor: NSColor.systemOrange
        )
    }

    // MARK: Syntax highlighting

    /// Keywords: `local`, `function`, `return`, `if`
    static var syntaxKey: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.syntaxKey
                        : ThemePalette.systemLight.syntaxKey
                }))
    }

    /// Built-in functions & API members.
    static var syntaxBuiltin: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.syntaxBuiltin
                        : ThemePalette.systemLight.syntaxBuiltin
                }))
    }

    /// String literals.
    static var syntaxString: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.syntaxString
                        : ThemePalette.systemLight.syntaxString
                }))
    }

    /// Numeric literals.
    static var syntaxNumber: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.syntaxNumber
                        : ThemePalette.systemLight.syntaxNumber
                }))
    }

    /// Boolean literals & named constants.
    static var syntaxBool: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.syntaxBool
                        : ThemePalette.systemLight.syntaxBool
                }))
    }

    /// Type-like tokens & JSON object keys.
    static var syntaxType: Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? ThemePalette.neutralDark.syntaxType
                        : ThemePalette.systemLight.syntaxType
                }))
    }

    // MARK: Resolution helpers

    private static func adaptiveWash(_ lightAlpha: Double, _ darkAlpha: Double, baseColor: NSColor = .labelColor) -> Color {
        Color(
            nsColor: NSColor(
                name: nil,
                dynamicProvider: { appearance in
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    return baseColor.withAlphaComponent(CGFloat(isDark ? darkAlpha : lightAlpha))
                }))
    }
}
