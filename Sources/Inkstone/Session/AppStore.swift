import AppKit
import Foundation

/// Process-level state: which theme, which windows, which files are recent.
///
/// One coordinator rather than a store per concern, so the menu's enable state and
/// the windows can never disagree about "the current document".
///
/// A window (`EditorWindowController`) owns the Files panel and an `NSTabView` of
/// documents; a document (`DocumentWindowController`) is a tab's content. The
/// store holds the windows and derives the document list from them.
@MainActor
final class AppStore {
    static let shared = AppStore()

    /// Settings and theme ownership live here so the menu, the preferences window
    /// and the document windows can never disagree about which theme is active.
    let settings = SettingsStore.shared
    private(set) lazy var themeManager = ThemeManager(store: settings)
    private(set) lazy var drafts = DraftStore()
    private(set) var theme: EditorTheme = SettingsStore.shared.resolvedTheme()
    private(set) var hosts: [EditorWindowController] = []
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

    /// Every open document, across every window.
    var documents: [DocumentWindowController] { hosts.flatMap(\.documents) }

    /// The key window, or the most recently created one when none has focus.
    var focusedHost: EditorWindowController? {
        hosts.first { $0.window?.isKeyWindow == true } ?? hosts.last
    }

    /// The focused window's selected document - the menu's "current document".
    ///
    /// Still called `focusedWindow`: every call site means "the document the
    /// commands act on", which is now a tab, not a window.
    var focusedWindow: DocumentWindowController? { focusedHost?.selectedDocument }

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
        for host in hosts {
            host.apply(theme: theme)
        }
        onThemeChange?(theme)
    }

    func setCustomFontSize(_ size: Double) {
        themeManager.setCustomFontSize(size)
    }

    func useThemeFontSize() {
        themeManager.useThemeFontSize()
    }

    // MARK: - Windows and tabs

    /// A new window with the Files panel rooted where the caller asks.
    ///
    /// Single-window single-root: `sidebarFolder` pins the tree for that window
    /// for life; without it the preference decides, and without that the first
    /// document's folder is latched once. Tab switches never move the root.
    @discardableResult
    func newHost(sidebarFolder: URL? = nil) -> EditorWindowController {
        let settings = settings.settings
        let environment = EditorEnvironment(
            parseOptions: settings.parseOptions,
            sidebarFolder: sidebarFolder ?? settings.sidebarFolder,
            wordsPerMinute: settings.wordsPerMinute
        )
        let host = EditorWindowController(
            theme: theme, environment: environment, pinnedRoot: sidebarFolder
        )
        // Tree clicks land in the current tab rather than spawning new ones.
        host.onSelectFile = { [weak self, weak host] url in
            guard let self, let host else { return }
            self.openInCurrentTab(url, in: host)
        }
        host.onSelectionChange = { [weak self] in
            self?.onWindowsChange?()
        }
        host.onDocumentsChange = { [weak self] in
            self?.onWindowsChange?()
        }
        host.onClosed = { [weak self, weak host] in
            self?.remove(host)
        }
        host.onNewTab = { [weak self, weak host] in
            self?.newDocument(in: host)
        }
        host.onMoveToNewWindow = { [weak self, weak host] index in
            guard let self, let host else { return }
            self.moveTabToNewWindow(from: host, at: index, followCursor: false)
        }
        host.onTearOff = { [weak self, weak host] index in
            guard let self, let host else { return }
            self.moveTabToNewWindow(from: host, at: index, followCursor: true)
        }
        host.showHiddenFiles = self.settings.editorView.showHiddenFiles
        // A window built with a (0, 0) content rect lands wherever AppKit's
        // cascade happens to leave it, which can push the sidebar off-screen.
        // Centre the first window and step the rest down-right, TextEdit-style.
        if let window = host.window {
            if let previous = hosts.last?.window, previous.isVisible {
                window.setFrameTopLeftPoint(
                    NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24)
                )
            } else {
                window.center()
            }
        }
        hosts.append(host)
        host.setInitialRoot(preference: self.settings.settings.sidebarFolder)
        host.showWindow(nil)
        onWindowsChange?()
        return host
    }

    /// A new document tab, in the given window or the focused one.
    @discardableResult
    func newDocument(
        markdown: String = SampleDocument.text, url: URL? = nil,
        in host: EditorWindowController? = nil
    ) -> DocumentWindowController {
        let host = host ?? focusedHost ?? newHost()
        let document = host.addTab(markdown: markdown, url: url)
        attachSessionWiring(document)
        return document
    }

    /// A new window with one untitled scratch tab, as "New Window" asks for.
    @discardableResult
    func newWindow() -> DocumentWindowController {
        newDocument(in: newHost())
    }

    /// Reopens the last session's unsaved drafts, already dirty.
    ///
    /// No prompt on purpose: asking on every launch - clean quit included - trains the
    /// user to dismiss the alert blind. Drafts sharing a folder share a window, so
    /// each window keeps a single root; unrelated folders never land in one tree.
    ///
    /// A draft whose file is already open (the Finder handed it over on this
    /// launch) is restored *into* that tab rather than duplicated: the draft is
    /// the newer content, and a second tab for the same file would leave the
    /// user saving the wrong one.
    func recoverDrafts(_ drafts: [Draft]) {
        guard !drafts.isEmpty else { return }
        var pending: [(draft: Draft, folder: URL?)] = []
        for draft in drafts {
            if let existing = documents.first(where: { $0.fileURL == draft.sourceURL }) {
                existing.restoreDraft(markdown: draft.markdown)
            } else {
                pending.append((draft, draft.sourceURL?.deletingLastPathComponent()))
            }
        }
        guard !pending.isEmpty else { return }
        var groups: [[Draft]] = []
        var indexByKey: [String: Int] = [:]
        for entry in pending {
            let key = entry.folder?.path ?? "scratch"
            if let index = indexByKey[key] {
                groups[index].append(entry.draft)
            } else {
                indexByKey[key] = groups.count
                groups.append([entry.draft])
            }
        }
        for group in groups {
            let host = newHost()
            for draft in group {
                let document = newDocument(markdown: draft.markdown, url: draft.sourceURL, in: host)
                document.restoreDraft(markdown: draft.markdown)
            }
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

    /// Closes a document's tab, and its window when that was the last tab.
    func close(_ document: DocumentWindowController) {
        guard
            let host = hosts.first(where: { host in
                host.documents.contains { $0 === document }
            })
        else { return }
        host.removeDocument(document)
        if host.documents.isEmpty {
            host.close()
        }
    }

    /// ⌘W: the focused tab, or the window when the tab list is empty.
    func closeFocusedDocument() {
        guard let host = focusedHost else { return }
        host.closeSelectedTab()
    }

    /// Sends one tab to a fresh window: the context menu's Move to New Window
    /// and the drag-tear path. Follow-cursor puts the new window where the
    /// pointer let go; otherwise it cascades like any other window.
    private func moveTabToNewWindow(
        from host: EditorWindowController, at index: Int, followCursor: Bool
    ) {
        guard let document = host.detachTab(at: index) else { return }
        let destination = newHost()
        destination.window?.makeKeyAndOrderFront(nil)
        destination.attachTab(document)
        if followCursor {
            positionAtCursor(destination.window)
        }
        if host.documents.isEmpty {
            host.close()
        }
        onWindowsChange?()
    }

    /// Top-left of the new window at the cursor, clamped to that screen.
    private func positionAtCursor(_ window: NSWindow?) {
        guard let window else { return }
        let cursor = NSEvent.mouseLocation
        let screen =
            NSScreen.screens.first { NSMouseInRect(cursor, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        var origin = NSPoint(x: cursor.x, y: cursor.y - window.frame.height)
        origin.x = min(max(origin.x, screen.frame.minX), screen.frame.maxX - window.frame.width)
        origin.y = min(max(origin.y, screen.frame.minY), screen.frame.maxY - window.frame.height)
        window.setFrameOrigin(origin)
    }

    private func remove(_ host: EditorWindowController?) {
        guard let host, let index = hosts.firstIndex(where: { $0 === host }) else { return }
        hosts.remove(at: index)
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
        let host = focusedHost ?? newHost()
        open(url, in: host)
    }

    /// Opens a file in a window: focuses its tab when it is already open, reuses
    /// the lone empty scratch tab, and adds a tab otherwise. The window's root
    /// never moves: a file outside the root opens as a tab with no highlight.
    func open(_ url: URL, in host: EditorWindowController) {
        if focus(url) { return }
        do {
            let document = reuseScratchTab(in: host) ?? host.addTab(markdown: "", url: url)
            attachSessionWiring(document)
            try document.open(url)
            noteRecent(url)
            noteRecentFolder(url.deletingLastPathComponent())
        } catch {
            AppLogger.error("Failed to open \(url.lastPathComponent): \(error)", category: "File")
        }
    }

    /// Tree clicks reuse the selected tab instead of spawning tabs, so browsing
    /// the tree never explodes the tab bar. A dirty selected tab is left alone
    /// (a new tab opens instead) so unsaved work is never swapped out without
    /// a say; with no selected tab this is just `open`.
    func openInCurrentTab(_ url: URL, in host: EditorWindowController) {
        if focus(url) { return }
        if let current = host.selectedDocument, !current.hasUnsavedChanges {
            do {
                try current.open(url)
                noteRecent(url)
                noteRecentFolder(url.deletingLastPathComponent())
                return
            } catch {
                AppLogger.error(
                    "Current-tab open failed (falling back to new tab) for \(url.lastPathComponent): \(error)",
                    category: "File"
                )
                // The file must be visible somewhere: fall back to a new tab.
                open(url, in: host)
                return
            }
        }
        open(url, in: host)
    }

    /// Focuses the tab already showing `url`, wherever it lives. Returns whether
    /// there was one, so both open paths share the dedupe.
    @discardableResult
    func focus(_ url: URL) -> Bool {
        guard let existing = documents.first(where: { $0.fileURL == url }) else { return false }
        if let owner = hosts.first(where: { host in
            host.documents.contains { $0 === existing }
        }) {
            owner.window?.makeKeyAndOrderFront(nil)
            owner.select(document: existing)
        }
        return true
    }

    /// The window's single empty, clean tab, if that is all it holds: opening a
    /// file into it keeps a fresh window from leaving an empty Untitled behind.
    private func reuseScratchTab(in host: EditorWindowController) -> DocumentWindowController? {
        guard host.documents.count == 1, let scratch = host.documents.first,
            scratch.fileURL == nil, !scratch.hasUnsavedChanges
        else { return nil }
        return scratch
    }

    /// Autosave and crash-recovery wiring, shared by the new-document and
    /// file-open paths so neither can leave a tab unwired.
    private func attachSessionWiring(_ document: DocumentWindowController) {
        guard !document.hasSessionWiring else { return }
        document.autosaveInterval = autosaveInterval
        document.onWriteDraft = { [weak self] snapshot in
            guard let self else { return }
            self.drafts.write(self.draft(from: snapshot))
        }
        document.onSaveCommitted = { [weak self] url in
            self?.drafts.clear(for: url)
        }
        document.markSessionWired()
    }
}
