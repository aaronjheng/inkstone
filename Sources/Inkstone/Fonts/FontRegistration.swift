import AppKit
import CoreText

/// Registers the bundled Open Sans faces for the process.
///
/// Typora's github theme names `Open Sans` for body text and headings and ships
/// the four faces inside the app bundle; macOS does not install the family by
/// default, so without this `NSFont(name: "Open Sans")` silently falls back to
/// the system face and the rendering drifts from the reference. Process-scoped
/// registration makes the family resolve without touching system-wide state.
///
/// The TTFs and their licence (`OFL.txt`) live in `Sources/Inkstone/Fonts/`;
/// the synchronized root group copies them into the bundle as resources.
enum FontRegistration {
    private static let faces = [
        "OpenSans-Regular", "OpenSans-Italic", "OpenSans-Bold", "OpenSans-BoldItalic",
    ]

    /// Registers every bundled face. Safe to call more than once: a duplicate
    /// registration is reported as an error by CoreText and ignored here.
    static func registerBundledFonts() {
        for face in faces {
            guard let url = Bundle.main.url(forResource: face, withExtension: "ttf") else {
                AppLogger.warn("bundled font missing: \(face)", category: "Theme")
                continue
            }
            var error: Unmanaged<CFError>?
            let status = CTFontManagerRegisterFontsForURL(
                url as CFURL, .process, &error
            )
            if !status, let error {
                AppLogger.warn(
                    "font registration failed for \(face): \(error.takeRetainedValue())",
                    category: "Theme"
                )
            }
        }
    }
}
