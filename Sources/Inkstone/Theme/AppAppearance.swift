import AppKit

/// The appearance axis: follow the system (aqua / darkAqua), or force a
/// specific side. Appearance picks *which palette side* is active; the theme
/// registry (not yet implemented) picks *which palette* provides it.
enum ThemeAppearance: Int, CaseIterable {
    case system = 0
    case light = 1
    case dark = 2

    var name: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
