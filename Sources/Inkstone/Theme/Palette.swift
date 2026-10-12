import AppKit
import SwiftUI

/// One side (light or dark) of a theme palette: surfaces, washes, and syntax
/// hues. The two sides (`systemLight` / `neutralDark`) stay independent — a
/// future selectable theme introduces additional pairs without changing any
/// token call site.
///
/// Washes stay alpha strengths rather than resolved colors, because their
/// bases (`labelColor`, `systemRed`, `systemOrange`) must keep re-resolving
/// per appearance. `AppColor` applies the alpha at resolution time.
struct ThemePalette: Equatable {
    // MARK: Surfaces

    /// Main window / content background.
    let windowBackground: NSColor
    /// Secondary surfaces: sidebars, headers, tables.
    let secondaryBackground: NSColor
    /// Raised pill / control surfaces.
    let pillBackground: NSColor
    /// Code surfaces.
    let codeBackground: NSColor
    /// Input hover fill.
    let fieldHoverBackground: NSColor
    /// Input focus fill.
    let fieldFocusBackground: NSColor
    /// Sidebar base.
    let sidebarBackground: NSColor

    // MARK: Washes (alpha strengths over shared bases)

    /// Light fill for badges and secondary chrome (over `labelColor`).
    let subtleBackground: Double
    /// Track background for meters (over `labelColor`).
    let trackBackground: Double
    /// Hairline stroke / border (over `labelColor`).
    let subtleBorder: Double
    /// Sidebar tint over the opaque base (over `labelColor`).
    let sidebarTint: Double
    /// Row hover wash (over `labelColor`).
    let hoverBackground: Double
    /// Icon button hover wash (over `labelColor`).
    let iconHoverBackground: Double
    /// Pressed / selected fill (over `labelColor`).
    let controlFillBackground: Double
    /// Shell output block background (over `labelColor`).
    let shellOutputBackground: Double
    /// Destructive hover / press (over `systemRed`).
    let destructiveBackground: Double
    /// Error banner fill (over `systemRed`).
    let errorBannerBackground: Double
    /// Warning banner fill (over `systemOrange`).
    let warningBannerBackground: Double

    // MARK: Syntax highlighting

    let syntaxKey: NSColor
    let syntaxBuiltin: NSColor
    let syntaxString: NSColor
    let syntaxNumber: NSColor
    let syntaxBool: NSColor
    let syntaxType: NSColor
}

extension ThemePalette {
    /// Light palette: soft #F9F9F9 frame with white raised surfaces and airy
    /// washes, matching the reference runlet theme.
    static let systemLight = ThemePalette(
        windowBackground: NSColor(srgbRed: 249.0 / 255.0, green: 249.0 / 255.0, blue: 249.0 / 255.0, alpha: 1),
        secondaryBackground: NSColor(srgbRed: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),
        pillBackground: NSColor(srgbRed: 239.0 / 255.0, green: 239.0 / 255.0, blue: 239.0 / 255.0, alpha: 1),
        codeBackground: NSColor(srgbRed: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),
        fieldHoverBackground: NSColor(srgbRed: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),
        fieldFocusBackground: NSColor(srgbRed: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0, alpha: 1),
        sidebarBackground: NSColor(srgbRed: 249.0 / 255.0, green: 249.0 / 255.0, blue: 249.0 / 255.0, alpha: 1),
        subtleBackground: 0.08,
        trackBackground: 0.12,
        subtleBorder: 0.12,
        sidebarTint: 0.05,
        hoverBackground: 0.06,
        iconHoverBackground: 0.08,
        controlFillBackground: 0.12,
        shellOutputBackground: 0.08,
        destructiveBackground: 0.12,
        errorBannerBackground: 0.12,
        warningBannerBackground: 0.12,
        syntaxKey: hsb(0.750, 0.50, 0.55),
        syntaxBuiltin: hsb(0.514, 0.65, 0.45),
        syntaxString: hsb(0.375, 0.55, 0.42),
        syntaxNumber: hsb(0.078, 0.70, 0.65),
        syntaxBool: hsb(0.931, 0.50, 0.60),
        syntaxType: hsb(0.597, 0.60, 0.55)
    )

    /// Dark palette: flat neutral set — #262626 main, #212121 secondary,
    /// #2E2E2E pills — with stronger washes and lifted syntax hues.
    static let neutralDark = ThemePalette(
        windowBackground: NSColor(srgbRed: 38.0 / 255.0, green: 38.0 / 255.0, blue: 38.0 / 255.0, alpha: 1),
        secondaryBackground: NSColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
        pillBackground: NSColor(srgbRed: 46.0 / 255.0, green: 46.0 / 255.0, blue: 46.0 / 255.0, alpha: 1),
        codeBackground: NSColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
        fieldHoverBackground: NSColor(srgbRed: 46.0 / 255.0, green: 46.0 / 255.0, blue: 46.0 / 255.0, alpha: 1),
        fieldFocusBackground: NSColor(srgbRed: 48.0 / 255.0, green: 48.0 / 255.0, blue: 48.0 / 255.0, alpha: 1),
        sidebarBackground: NSColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
        subtleBackground: 0.12,
        trackBackground: 0.18,
        subtleBorder: 0.18,
        sidebarTint: 0.05,
        hoverBackground: 0.10,
        iconHoverBackground: 0.13,
        controlFillBackground: 0.16,
        shellOutputBackground: 0.12,
        destructiveBackground: 0.20,
        errorBannerBackground: 0.18,
        warningBannerBackground: 0.18,
        syntaxKey: hsb(0.750, 0.40, 0.82),
        syntaxBuiltin: hsb(0.514, 0.50, 0.78),
        syntaxString: hsb(0.375, 0.42, 0.75),
        syntaxNumber: hsb(0.078, 0.58, 0.88),
        syntaxBool: hsb(0.931, 0.38, 0.82),
        syntaxType: hsb(0.597, 0.48, 0.82)
    )

    private static func hsb(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> NSColor {
        NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
    }
}
