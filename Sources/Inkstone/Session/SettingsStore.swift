import AppKit
import Foundation
import Observation

/// What a launch with no files handed over by the Finder should do.
///
/// The original offers exactly these four; the strings are the settings-file
/// form, so the preference survives the enum being renamed.
enum LaunchOption: String, Codable, CaseIterable, Sendable {
    case openNewFile
    case reopenLastFolder
    case reopenLastFilesAndFolders
    case openSpecifiedFolder

    /// Menu label, in the original's wording.
    var displayName: String {
        switch self {
        case .openNewFile: return "New file"
        case .reopenLastFolder: return "Reopen last folder"
        case .reopenLastFilesAndFolders: return "Reopen last files and folders"
        case .openSpecifiedFolder: return "Open specified folder"
        }
    }
}

/// User preferences.
///
/// One value type, one store, atomically persisted. The surface mirrors the original's
/// `File.option` set closely enough that migrating a user between the two is
/// mechanical; the authoritative list of what is and is not implemented is
/// `Docs/option-inventory.md`.
///
/// Kept free of AppKit types so it can be exercised from the self-check.
struct EditorSettings: Codable, Equatable, Sendable {
    // Appearance
    var themeIdentifier = "github"
    var useCustomFontSize = false
    var customFontSize: Double = 16
    var alwaysShowWordCount = true
    var wordsPerMinute = 382
    /// Folder shown in the sidebar's Files column; `nil` means "the document's
    /// own folder".
    var sidebarFolderPath: String?
    var showStatusBar = true
    var showToolbar = false

    // Editor
    var autoPairBrackets = true
    var autoPairMarkdownSyntax = true
    var emojiAutocomplete = true
    var autoExpandBlockOnFocus = false
    var copyMarkdownByDefault = true
    var lineWiseCopyCut = false
    var keepCaretInMiddle = false
    var indentSize = 2
    var codeIndentSize = 4
    var prettyIndent = false
    var shiftTabAutoIndent = false
    var spellCheckEnabled = true
    /// Seconds between autosaves; `0` disables it, which is the original's default.
    var autoSaveInterval: Double = 0
    var showInvisibleCharacters = false

    // Markdown
    var strictMarkdown = false
    var headingStyle = 0  // 0 = setext-and-atx, 1 = atx only, 3 = setext only
    var ulStyle = 0  // 0 = "-", 1 = "*", 2 = "+"
    var olStyle = 0  // 0 = "1.", 1 = "1)"
    var enableInlineMath = true
    var enableSubscript = false
    var enableSuperscript = false
    var enableHighlight = false
    var enableAlert = true
    var enableStrike = true
    var noAutoLink = false
    var smartQuotes = false
    var smartDashes = false
    var remapUnicodePunctuation = false
    var twoHyphensToEm = false
    var ignoreLineBreak = false
    var hideBrAndLineBreak = false
    var indentFirstLine = false
    var showLineNumbersForFence = false
    var noLineWrapping = false
    var insertFinalNewLineOnSave = false
    var preferCRLF = false
    var defaultCodeLanguage = ""
    var enableLegacyInlineMath = false

    // Files
    var autoSave = false
    var saveOnSwitch = false
    var recordRecentFiles = true
    var showHiddenFiles = false
    var revealOutlineOnStart = false

    // Launch
    /// What the app does when it starts with nothing handed to it by the
    /// Finder: the original's "启动选项" (launch options).
    var launchOption: LaunchOption = .openNewFile
    /// The folder `openSpecifiedFolder` opens, if one is chosen.
    var launchFolderPath: String?

    // Math
    var autoNumberMath = false
    var applyLineBreakAtBackslash = false
    var mathSourceInsteadOfSVG = false

    // Zoom
    var zoomFactor: Double = 1

    /// Font scale the theme is rendered at.
    var fontScale: CGFloat {
        useCustomFontSize
            ? CGFloat(max(customFontSize, 9) / 16)
            : 1
    }

    /// The parse options implied by the current settings.
    /// Resolved folder for the file tree, preferring the remembered one.
    var sidebarFolder: URL? {
        sidebarFolderPath.map { URL(fileURLWithPath: $0) }
    }

    /// The folder the specified-folder launch option opens.
    var launchFolder: URL? {
        launchFolderPath.map { URL(fileURLWithPath: $0) }
    }

    var parseOptions: BlockParser.Options {
        var options = BlockParser.Options.standard
        options.strictMarkdown = strictMarkdown
        options.enableInlineMath = enableInlineMath
        options.enableMathBlock = true
        options.enableSubscript = enableSubscript
        options.enableSuperscript = enableSuperscript
        options.enableHighlight = enableHighlight
        options.enableAlert = enableAlert
        options.enableStrike = enableStrike
        options.enableAutoLink = !noAutoLink
        options.enableEmoji = emojiAutocomplete
        options.ignoreLineBreak = ignoreLineBreak
        return options
    }

    var inlineOptions: InlineLexer.Options {
        var options = parseOptions.inline
        options.legacyInlineMath = enableLegacyInlineMath
        return options
    }

    /// Ordered list marker for a given 1-based position, honouring `olStyle`.
    func orderedMarker(for position: Int) -> String {
        olStyle == 1 ? "\(position))" : "\(position)."
    }

    /// Unordered list marker, honouring `ulStyle`.
    var unorderedMarker: String {
        switch ulStyle {
        case 1: return "* "
        case 2: return "+ "
        default: return "- "
        }
    }
}

/// Persists `EditorSettings` to `Application Support/<bundle id>/settings.json`.
///
/// Atomic writes and sorted keys, matching the rest of the app's persistence: a
/// crash mid-save must never leave a half-written settings file, and stable key
/// order keeps diffs and merges meaningful.
@MainActor
@Observable
final class SettingsStore {
    private(set) var settings: EditorSettings

    /// Application Support, resolved rather than hard-coded: the directory is
    /// named after the bundle identifier, which is the macOS convention.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let root = base.first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = root.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.inkstone")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static var settingsURL: URL { supportDirectory.appendingPathComponent("settings.json") }
    /// Themes live in their own folder, matching the original's user-theme directory.
    static var themesDirectory: URL {
        let directory = supportDirectory.appendingPathComponent("themes")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private init() {
        settings = Self.load()
    }

    static let shared = SettingsStore()

    private static func load() -> EditorSettings {
        migrateLegacySettings()
        guard let data = try? Data(contentsOf: Self.settingsURL),
            let decoded = try? JSONDecoder().decode(EditorSettings.self, from: data)
        else { return EditorSettings() }
        return decoded
    }

    /// The app was renamed before its first release; carry the settings from the
    /// old `app.inkstone` folder over, so the theme and editor preferences
    /// survive the identity change.
    private static func migrateLegacySettings() {
        let legacy =
            supportDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("app.inkstone/settings.json")
        guard !FileManager.default.fileExists(atPath: settingsURL.path),
            FileManager.default.fileExists(atPath: legacy.path)
        else { return }
        try? FileManager.default.copyItem(at: legacy, to: settingsURL)
    }

    /// Fired after every change, so open windows can re-read the preferences they
    /// mirror. `@Observable` alone does not do it: the editor holds copies of a few
    /// flags for TextKit to query cheaply, and those copies have to be pushed.
    @ObservationIgnored var onChange: (() -> Void)?

    func update(_ body: (inout EditorSettings) -> Void) {
        var copy = settings
        body(&copy)
        settings = copy
        persist()
        onChange?()
    }

    func reset() {
        settings = EditorSettings()
        persist()
        onChange?()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        do {
            try data.write(to: Self.settingsURL, options: .atomic)
        } catch {
            AppLogger.error("Failed to save settings: \(error)", category: "Settings")
        }
    }

    /// The editor-facing mirror of the current preferences.
    ///
    /// `Editor/` may not import `Session/`, so the mapping lives here, on the side that
    /// is allowed to know about both.
    var editorView: EditorSettingsView {
        EditorSettingsView(
            autoPairBrackets: settings.autoPairBrackets,
            autoPairMarkdownSyntax: settings.autoPairMarkdownSyntax,
            smartQuotes: settings.smartQuotes,
            indentSize: settings.indentSize,
            codeIndentSize: settings.codeIndentSize,
            typewriter: settings.keepCaretInMiddle,
            focus: false,
            readonly: false,
            showInvisibleCharacters: settings.showInvisibleCharacters,
            showHiddenFiles: settings.showHiddenFiles
        )
    }

    /// The theme named by the current settings, scaled by the font-size preference.
    func resolvedTheme() -> EditorTheme {
        let base = BuiltInTheme.theme(named: settings.themeIdentifier) ?? BuiltInTheme.github
        return base.scaled(by: settings.fontScale)
    }
}

/// Owns the theme and the appearance, and keeps the windows in step.
@MainActor
@Observable
final class ThemeManager {
    private(set) var theme: EditorTheme
    private let store: SettingsStore

    /// Called on every change so the preferences window can reflect it.
    var onChange: ((EditorTheme) -> Void)?

    init(store: SettingsStore = .shared) {
        self.store = store
        theme = store.resolvedTheme()
    }

    /// The six built-ins plus any user themes found on disk.
    var available: [EditorTheme] {
        BuiltInTheme.all + userThemes()
    }

    func select(identifier: String) {
        store.update { $0.themeIdentifier = identifier }
        apply()
    }

    func setCustomFontSize(_ size: Double) {
        store.update {
            $0.useCustomFontSize = true
            $0.customFontSize = size
        }
        apply()
    }

    func useThemeFontSize() {
        store.update { $0.useCustomFontSize = false }
        apply()
    }

    func apply() {
        theme = store.resolvedTheme()
        onChange?(theme)
    }

    /// Themes the user added to the themes folder, as JSON.
    ///
    /// A user theme is a partial override: anything it omits falls back to the
    /// built-in theme with the same identifier, so a two-line CSS-equivalent file
    /// is enough to change one colour.
    private func userThemes() -> [EditorTheme] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: SettingsStore.themesDirectory, includingPropertiesForKeys: nil
            )) ?? []
        var result: [EditorTheme] = []
        for url in contents where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                let override = try? JSONDecoder().decode(ThemeOverride.self, from: data)
            else {
                AppLogger.warn("Ignoring unreadable theme \(url.lastPathComponent)", category: "Theme")
                continue
            }
            let theme = override.applied()
            if !result.contains(where: { $0.identifier == theme.identifier }) {
                result.append(theme)
            }
        }
        return result
    }
}
