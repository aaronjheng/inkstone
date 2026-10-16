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
/// Every field is decoded with `decodeIfPresent` and a default: the synthesized
/// decoder required every key to be present, so the first release that added a
/// preference made every existing `settings.json` undecodable and silently reset
/// Where the document's palette comes from: the system appearance picks
/// between the light theme (GitHub) and the dark one (Night), or one is forced.
enum ThemeStyle: Int, CaseIterable, Codable {
    case system = 0
    case light = 1
    case dark = 2

    var name: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// the theme, launch option and autosave to factory defaults.
struct EditorSettings: Codable, Equatable, Sendable {
    // Appearance
    /// Which palette the document renders in: the system appearance picks
    /// between the light theme (GitHub) and the dark one (Night).
    var themeStyle: ThemeStyle = .system
    var customFontSize: Double = 16
    var wordsPerMinute = 382
    /// Folder shown in the sidebar's Files column; `nil` means "the document's
    /// own folder".
    var sidebarFolderPath: String?

    // Editor
    var autoPairBrackets = true
    var autoPairMarkdownSyntax = true
    var emojiAutocomplete = true
    var keepCaretInMiddle = false
    var indentSize = 2
    var codeIndentSize = 4
    var spellCheckEnabled = true
    /// Seconds between autosaves; `0` disables it, which is the original's default.
    var autoSaveInterval: Double = 0
    var showInvisibleCharacters = false

    // Markdown
    var strictMarkdown = false
    var enableInlineMath = true
    var enableSubscript = true
    var enableSuperscript = true
    var enableHighlight = true
    var enableAlert = true
    var enableStrike = true
    var noAutoLink = false
    var smartQuotes = false
    var ignoreLineBreak = false
    var enableLegacyInlineMath = false

    // Files
    var recordRecentFiles = true
    var showHiddenFiles = false

    // Launch
    /// What the app does when it starts with nothing handed to it by the
    /// Finder: the original's "启动选项" (launch options).
    var launchOption: LaunchOption = .openNewFile
    /// The folder `openSpecifiedFolder` opens, if one is chosen.
    var launchFolderPath: String?

    // Zoom
    var zoomFactor: Double = 1

    init() {}

    private enum CodingKeys: String, CodingKey {
        case themeStyle, customFontSize, wordsPerMinute
        case sidebarFolderPath, autoPairBrackets, autoPairMarkdownSyntax
        case emojiAutocomplete, keepCaretInMiddle, indentSize, codeIndentSize
        case spellCheckEnabled, autoSaveInterval, showInvisibleCharacters
        case strictMarkdown, enableInlineMath, enableSubscript, enableSuperscript
        case enableHighlight, enableAlert, enableStrike, noAutoLink, smartQuotes
        case ignoreLineBreak, enableLegacyInlineMath, recordRecentFiles
        case showHiddenFiles, launchOption, launchFolderPath, zoomFactor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        themeStyle =
            try container.decodeIfPresent(Int.self, forKey: .themeStyle)
            .flatMap(ThemeStyle.init(rawValue:)) ?? .system
        customFontSize = try container.decodeIfPresent(Double.self, forKey: .customFontSize) ?? 16
        wordsPerMinute = try container.decodeIfPresent(Int.self, forKey: .wordsPerMinute) ?? 382
        sidebarFolderPath = try container.decodeIfPresent(String.self, forKey: .sidebarFolderPath)
        autoPairBrackets = try container.decodeIfPresent(Bool.self, forKey: .autoPairBrackets) ?? true
        autoPairMarkdownSyntax = try container.decodeIfPresent(Bool.self, forKey: .autoPairMarkdownSyntax) ?? true
        emojiAutocomplete = try container.decodeIfPresent(Bool.self, forKey: .emojiAutocomplete) ?? true
        keepCaretInMiddle = try container.decodeIfPresent(Bool.self, forKey: .keepCaretInMiddle) ?? false
        indentSize = try container.decodeIfPresent(Int.self, forKey: .indentSize) ?? 2
        codeIndentSize = try container.decodeIfPresent(Int.self, forKey: .codeIndentSize) ?? 4
        spellCheckEnabled = try container.decodeIfPresent(Bool.self, forKey: .spellCheckEnabled) ?? true
        autoSaveInterval = try container.decodeIfPresent(Double.self, forKey: .autoSaveInterval) ?? 0
        showInvisibleCharacters = try container.decodeIfPresent(Bool.self, forKey: .showInvisibleCharacters) ?? false
        strictMarkdown = try container.decodeIfPresent(Bool.self, forKey: .strictMarkdown) ?? false
        enableInlineMath = try container.decodeIfPresent(Bool.self, forKey: .enableInlineMath) ?? true
        enableSubscript = try container.decodeIfPresent(Bool.self, forKey: .enableSubscript) ?? true
        enableSuperscript =
            try container.decodeIfPresent(Bool.self, forKey: .enableSuperscript) ?? true
        enableHighlight = try container.decodeIfPresent(Bool.self, forKey: .enableHighlight) ?? true
        enableAlert = try container.decodeIfPresent(Bool.self, forKey: .enableAlert) ?? true
        enableStrike = try container.decodeIfPresent(Bool.self, forKey: .enableStrike) ?? true
        noAutoLink = try container.decodeIfPresent(Bool.self, forKey: .noAutoLink) ?? false
        smartQuotes = try container.decodeIfPresent(Bool.self, forKey: .smartQuotes) ?? false
        ignoreLineBreak = try container.decodeIfPresent(Bool.self, forKey: .ignoreLineBreak) ?? false
        enableLegacyInlineMath = try container.decodeIfPresent(Bool.self, forKey: .enableLegacyInlineMath) ?? false
        recordRecentFiles = try container.decodeIfPresent(Bool.self, forKey: .recordRecentFiles) ?? true
        showHiddenFiles = try container.decodeIfPresent(Bool.self, forKey: .showHiddenFiles) ?? false
        launchOption = try container.decodeIfPresent(LaunchOption.self, forKey: .launchOption) ?? .openNewFile
        launchFolderPath = try container.decodeIfPresent(String.self, forKey: .launchFolderPath)
        zoomFactor = try container.decodeIfPresent(Double.self, forKey: .zoomFactor) ?? 1
    }

    /// Font scale the document renders at: the user's font size over the 16pt
    /// reference.
    var fontScale: CGFloat {
        CGFloat(max(customFontSize, 9) / 16)
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
            showHiddenFiles: settings.showHiddenFiles,
            spellCheck: settings.spellCheckEnabled
        )
    }

    /// The theme named by the current settings, scaled by the font-size preference.
    func resolvedTheme() -> EditorTheme {
        resolvedTheme(isDark: false)
    }

    /// The theme an appearance should show: GitHub in light mode, Night in dark
    /// mode; `.system` follows the effective appearance.
    func resolvedTheme(isDark: Bool) -> EditorTheme {
        let useDark =
            settings.themeStyle == .dark
            || (settings.themeStyle == .system && isDark)
        let base = useDark ? BuiltInTheme.night : BuiltInTheme.github
        return base.scaled(by: settings.fontScale)
    }
}

/// Owns the theme and the appearance, and keeps the windows in step.
@MainActor
@Observable
final class ThemeManager {
    private(set) var theme: EditorTheme
    private let store: SettingsStore
    /// Watches `NSApp.effectiveAppearance` so a system light/dark switch swaps
    /// in the dark theme without waiting for a restart.
    private var appearanceObservation: NSKeyValueObservation?

    /// Called on every change so the preferences window can reflect it.
    var onChange: ((EditorTheme) -> Void)?

    init(store: SettingsStore = .shared) {
        self.store = store
        theme = store.resolvedTheme(isDark: Self.isDarkAppearance)
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.appearanceDidChange() }
        }
    }

    /// Whether the system (or a forced `NSApp.appearance`) is showing the dark
    /// side of the palettes.
    private static var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func appearanceDidChange() {
        let next = store.resolvedTheme(isDark: Self.isDarkAppearance)
        // A same-theme flip needs no re-render: the dynamic `NSColor`s have
        // already followed the appearance on their own.
        guard next != theme else { return }
        apply()
    }

    func setCustomFontSize(_ size: Double) {
        store.update { $0.customFontSize = size }
        apply()
    }

    func apply() {
        theme = store.resolvedTheme(isDark: Self.isDarkAppearance)
        onChange?(theme)
    }

}
