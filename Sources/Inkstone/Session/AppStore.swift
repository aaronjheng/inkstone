import AppKit
import Foundation

/// Process-level state: which theme, which windows, which files are recent.
///
/// One coordinator rather than a store per concern, so the menu's enable state and
/// the windows can never disagree about "the current document".
@MainActor
final class AppStore {
    static let shared = AppStore()

    /// Settings and theme ownership live here so the menu, the preferences window
    /// and the document windows can never disagree about which theme is active.
    let settings = SettingsStore.shared
    private(set) lazy var themeManager = ThemeManager(store: settings)
    private(set) lazy var drafts = DraftStore()
    private(set) var theme: EditorTheme = SettingsStore.shared.resolvedTheme()
    private(set) var windows: [DocumentWindowController] = []
    private(set) var recentFiles: [URL] = []
    /// Folders the user opened, newest first; the reopen-last-folder launch
    /// option reads the head. Persisted through the app delegate like the files.
    private(set) var recentFolders: [URL] = []

    var focusMode = false
    var typeWriterMode = false
    var readonlyMode = false
    var sourceMode = false

    /// Events the menu and the preferences window subscribe to.
    var onThemeChange: ((EditorTheme) -> Void)?
    var onWindowsChange: (() -> Void)?

    private init() {
        themeManager.onChange = { [weak self] next in
            self?.apply(theme: next)
        }
    }

    var focusedWindow: DocumentWindowController? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.last
    }

    // MARK: - Theme

    /// Themes offered in the menu: the six built-ins plus any user overrides found
    /// in the themes folder.
    var availableThemes: [EditorTheme] { themeManager.available }

    func setTheme(identifier: String) {
        themeManager.select(identifier: identifier)
    }

    /// Called by `ThemeManager`; fans the change out to every open window.
    func apply(theme: EditorTheme) {
        self.theme = theme
        for window in windows {
            window.apply(theme: theme)
        }
        onThemeChange?(theme)
    }

    func setCustomFontSize(_ size: Double) {
        themeManager.setCustomFontSize(size)
    }

    func useThemeFontSize() {
        themeManager.useThemeFontSize()
    }

    // MARK: - Windows

    @discardableResult
    func newWindow(
        markdown: String = SampleDocument.text, url: URL? = nil, sidebarFolder: URL? = nil
    )
        -> DocumentWindowController
    {
        let settings = settings.settings
        let environment = EditorEnvironment(
            parseOptions: settings.parseOptions,
            sidebarFolder: sidebarFolder ?? settings.sidebarFolder,
            wordsPerMinute: settings.wordsPerMinute
        )
        let controller = DocumentWindowController(
            theme: theme, markdown: markdown, url: url, environment: environment
        )
        // Autosave and the crash-recovery draft both live here, so the window only has
        // to report what changed and let the store decide what to do about it.
        controller.autosaveInterval = autosaveInterval
        controller.onWriteDraft = { [weak self] snapshot in
            guard let self else { return }
            self.drafts.write(self.draft(from: snapshot))
        }
        controller.onSaveCommitted = { [weak self] url in
            self?.drafts.clear(for: url)
        }
        // A window built with a (0, 0) content rect lands wherever AppKit's
        // cascade happens to leave it, which can push the sidebar off-screen.
        // Centre the first window and step the rest down-right, TextEdit-style.
        if let window = controller.window {
            if let previous = windows.last?.window, previous.isVisible {
                window.setFrameTopLeftPoint(
                    NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24)
                )
            } else {
                window.center()
            }
        }
        controller.showWindow(nil)
        windows.append(controller)
        onWindowsChange?()
        return controller
    }

    /// Reopens the last session's unsaved drafts, each in its own window, already dirty.
    ///
    /// No prompt on purpose: asking on every launch - clean quit included - trains the
    /// user to dismiss the alert blind. A draft arrives as an unsaved window instead,
    /// so the content is one glance away and quitting asks about it the usual way.
    func recoverDrafts(_ drafts: [Draft]) {
        for draft in drafts {
            let controller = newWindow(markdown: draft.markdown, url: draft.sourceURL)
            controller.restoreDraft(markdown: draft.markdown)
        }
    }

    /// Autosave period in seconds; `0` turns it off.
    var autosaveInterval: TimeInterval {
        Double(settings.settings.autoSaveInterval) > 0
            ? Double(settings.settings.autoSaveInterval) : 0
    }

    private func draft(from snapshot: DraftSnapshot) -> Draft {
        Draft(
            sourceURL: snapshot.sourceURL,
            title: snapshot.title,
            markdown: snapshot.markdown,
            savedAt: snapshot.savedAt
        )
    }

    func close(_ controller: DocumentWindowController) {
        windows.removeAll { $0 === controller }
        onWindowsChange?()
    }

    // MARK: - Files

    /// Replaces the recent list, used when restoring from `UserDefaults`.
    func restoreRecentFiles(_ urls: [URL]) {
        recentFiles = urls
    }

    func restoreRecentFolders(_ urls: [URL]) {
        recentFolders = urls
    }

    func noteRecent(_ url: URL) {
        guard settings.settings.recordRecentFiles else { return }
        recentFiles.removeAll { $0 == url }
        recentFiles.insert(url, at: 0)
        if recentFiles.count > 20 { recentFiles.removeLast(recentFiles.count - 20) }
        UserDefaults.standard.set(recentFiles.map(\.path), forKey: "recentFiles")
    }

    /// Remembers a folder the way the recent-file list remembers files: the
    /// reopen-last-folder launch option reads the head of this list.
    func noteRecentFolder(_ url: URL) {
        guard settings.settings.recordRecentFiles else { return }
        recentFolders.removeAll { $0 == url }
        recentFolders.insert(url, at: 0)
        if recentFolders.count > 10 { recentFolders.removeLast(recentFolders.count - 10) }
        UserDefaults.standard.set(recentFolders.map(\.path), forKey: "recentFolders")
    }

    func open(_ url: URL) {
        // A file already open in another window focuses that window instead of
        // opening a second copy - the behaviour a tabbed-window user expects.
        if let existing = windows.first(where: { $0.fileURL == url }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let controller = newWindow(markdown: "", url: url)
            try controller.open(url)
            noteRecent(url)
            noteRecentFolder(url.deletingLastPathComponent())
        } catch {
            AppLogger.error("Failed to open \(url.lastPathComponent): \(error)", category: "File")
        }
    }
}
