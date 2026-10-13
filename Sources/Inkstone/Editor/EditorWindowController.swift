import AppKit
import SwiftUI

/// One window: the global Files panel on the left and an `NSTabView` of
/// documents on the right, VSCode-style.
///
/// Single-window single-root: the tree's root is fixed when the window is
/// created (explicit folder, else the preference, else latched once from the
/// first document with a path) and never follows tab switches. A tab whose
/// file lives outside the root still opens - it just shows no highlight.
///
/// Native window tabbing is deliberately off (`tabbingMode = .disallowed`):
/// it merges whole windows, which would drag the sidebar into the tab strip.
/// Documents are `DocumentWindowController`s whose own windows are never
/// shown - their content is mounted as tab views here.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    private let filesPanel = FileTreeController()
    /// Documents as tabs. The strip above draws them; the tab view is a
    /// border-less pane stack driven by the strip, TablePro-style.
    private let tabView = NSTabView()
    private let tabStripModel = EditorTabStripModel()
    private var contentRoot: ContentRootView?
    private var tabStripHost: NSHostingView<EditorTabStripView>?
    private var middlePressedTabID: ObjectIdentifier?
    private var middleClickMonitor: Any?
    private var theme: EditorTheme
    private var environment: EditorEnvironment
    /// Explicit folder this window was opened on (Open Folder / relaunch).
    /// Never changes for the life of the window.
    private let pinnedRoot: URL?
    /// Adopted once from the first document with a path when there is neither
    /// a pinned folder nor a preference. After that it is fixed like a pin.
    private var latchedRoot: URL?

    private(set) var documents: [DocumentWindowController] = []

    /// Routed upward: opening a file is a session decision (focus an existing
    /// tab elsewhere, reuse the scratch tab, add a tab).
    var onSelectFile: ((URL) -> Void)?
    /// Fired when the selected tab changes, so the session layer can refresh
    /// anything that tracks the focused document.
    var onSelectionChange: (() -> Void)?
    /// Fired when tabs come or go, or the window closes.
    var onDocumentsChange: (() -> Void)?
    /// Fired when the strip's "+" is pressed, so the session layer can build
    /// the tab with its autosave wiring.
    var onNewTab: (() -> Void)?
    /// Fired when the window closes, so the session layer can drop the host.
    var onClosed: (() -> Void)?
    /// Fired when the context menu sends a tab to a fresh window.
    var onMoveToNewWindow: ((Int) -> Void)?
    /// Fired when a drag leaves the strip and the tab should become a window.
    var onTearOff: ((Int) -> Void)?

    init(theme: EditorTheme, environment: EditorEnvironment, pinnedRoot: URL? = nil) {
        self.theme = theme
        self.environment = environment
        self.pinnedRoot = pinnedRoot
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = theme.background.nsColor
        // The tab strip is ours (EditorTabStripView); the tab view is only the
        // pane stack, so it gets no bezel and no tabs of its own.
        tabView.tabViewType = .noTabsNoBorder
        let tabStripHost = NSHostingView(rootView: EditorTabStripView(model: tabStripModel))
        tabStripHost.translatesAutoresizingMaskIntoConstraints = true
        contentRoot = ContentRootView(files: filesPanel.view, tabStrip: tabStripHost, tabArea: tabView)
        contentRoot?.apply(theme: theme)
        window.contentView = contentRoot
        // Never merged into a native tab group: the sidebar must stay put.
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 520, height: 380)
        super.init(window: window)
        self.tabStripHost = tabStripHost
        window.delegate = self
        tabView.delegate = self
        filesPanel.prepare()
        filesPanel.onSelect = { [weak self] url in self?.onSelectFile?(url) }
        filesPanel.onCreateFile = { [weak self] in self?.createFileInFolder() }
        tabStripModel.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabStripModel.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabStripModel.onNewTab = { [weak self] in self?.onNewTab?() }
        tabStripModel.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        tabStripModel.onCloseOthers = { [weak self] index in self?.closeOtherTabs(at: index) }
        tabStripModel.onCloseAll = { [weak self] in self?.closeAllTabs() }
        tabStripModel.onMoveLeft = { [weak self] index in self?.moveTabLeft(at: index) }
        tabStripModel.onMoveRight = { [weak self] index in self?.moveTabRight(at: index) }
        tabStripModel.onMoveToNewWindow = { [weak self] index in self?.onMoveToNewWindow?(index) }
        tabStripModel.onTearOff = { [weak self] index in self?.onTearOff?(index) }
        installMiddleClickMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorWindowController is created in code")
    }

    // MARK: - Tabs

    var selectedDocument: DocumentWindowController? {
        guard let item = tabView.selectedTabViewItem,
            let index = tabView.tabViewItems.firstIndex(where: { $0 === item }),
            index < documents.count
        else { return nil }
        return documents[index]
    }

    @discardableResult
    func addTab(markdown: String, url: URL?) -> DocumentWindowController {
        let document = DocumentWindowController(
            theme: theme, markdown: markdown, url: url, environment: environment
        )
        document.hostWindow = window
        document.onContentChange = { [weak self, weak document] in
            self?.documentDidChange(document)
        }
        documents.append(document)
        let item = NSTabViewItem(identifier: document.titleText)
        item.view = document.documentContent
        item.label = document.titleText
        item.toolTip = document.fileURL?.path
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        latchRootIfNeeded(for: document)
        syncTabStrip()
        refreshTitleAndHighlight()
        onDocumentsChange?()
        return document
    }

    private func syncTabStrip() {
        tabStripModel.items = documents.map {
            EditorTabStripModel.Item(
                id: ObjectIdentifier($0), title: $0.titleText,
                isEdited: $0.hasUnsavedChanges, toolTip: $0.fileURL?.path
            )
        }
        if let document = selectedDocument {
            tabStripModel.selectedIndex = documents.firstIndex(where: { $0 === document })
        } else {
            tabStripModel.selectedIndex = nil
        }
        contentRoot?.setTabStripVisible(documents.count > 1)
    }

    func select(document: DocumentWindowController) {
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        selectTab(at: index)
    }

    private func selectTab(at index: Int, reveal: Bool = false) {
        guard tabView.tabViewItems.indices.contains(index) else { return }
        tabView.selectTabViewItem(at: index)
        if reveal, documents.indices.contains(index) {
            tabStripModel.requestReveal(id: ObjectIdentifier(documents[index]))
        }
    }

    private var selectedTabIndex: Int? {
        guard let selected = selectedDocument else { return nil }
        return documents.firstIndex(where: { $0 === selected })
    }

    func selectPreviousTab() {
        guard let current = selectedTabIndex, documents.count > 1 else { return }
        let count = documents.count
        selectTab(at: (current - 1 + count) % count, reveal: true)
    }

    func selectNextTab() {
        guard let current = selectedTabIndex, documents.count > 1 else { return }
        let count = documents.count
        selectTab(at: (current + 1) % count, reveal: true)
    }

    func selectTabNumber(_ number: Int) {
        guard !documents.isEmpty else { return }
        if number == 9 {
            selectTab(at: documents.count - 1, reveal: true)
        } else if number >= 1, number <= 8, number <= documents.count {
            selectTab(at: number - 1, reveal: true)
        }
    }

    private var isReorderingTabs = false

    private func moveTab(from: Int, to: Int) {
        guard from != to,
            documents.indices.contains(from),
            documents.indices.contains(to),
            tabView.tabViewItems.indices.contains(from)
        else { return }
        let previouslySelected = selectedDocument
        let document = documents.remove(at: from)
        documents.insert(document, at: to)
        let item = tabView.tabViewItems[from]
        isReorderingTabs = true
        defer { isReorderingTabs = false }
        tabView.removeTabViewItem(item)
        tabView.insertTabViewItem(item, at: to)
        if let previouslySelected,
            let index = documents.firstIndex(where: { $0 === previouslySelected }),
            tabView.tabViewItems.indices.contains(index)
        {
            tabView.selectTabViewItem(at: index)
        }
        syncTabStrip()
        refreshTitleAndHighlight()
    }

    private func moveTabLeft(at index: Int) {
        guard index > 0 else { return }
        moveTab(from: index, to: index - 1)
        revealTab(at: index - 1)
    }

    private func moveTabRight(at index: Int) {
        guard documents.indices.contains(index), index < documents.count - 1 else { return }
        moveTab(from: index, to: index + 1)
        revealTab(at: index + 1)
    }

    private func revealTab(at index: Int) {
        guard documents.indices.contains(index) else { return }
        tabStripModel.requestReveal(id: ObjectIdentifier(documents[index]))
    }

    private func closeOtherTabs(at index: Int) {
        guard documents.indices.contains(index) else { return }
        let keep = documents[index]
        for document in documents where document !== keep {
            removeDocument(document)
        }
        select(document: keep)
    }

    private func closeAllTabs() {
        while let document = documents.first {
            removeDocument(document)
        }
        close()
    }

    /// Closes the selected tab, or the window when it was the last one.
    func closeSelectedTab() {
        guard let index = tabView.tabViewItems.firstIndex(where: { $0 === tabView.selectedTabViewItem })
        else {
            close()
            return
        }
        closeTab(at: index)
    }

    private func closeTab(at index: Int) {
        guard documents.indices.contains(index) else { return }
        removeDocument(documents[index])
        if documents.isEmpty {
            close()
        } else {
            tabView.selectTabViewItem(at: min(index, documents.count - 1))
            syncTabStrip()
            refreshTitleAndHighlight()
        }
    }

    /// Closes one tab's document; the window survives unless it was the last one.
    func removeDocument(_ document: DocumentWindowController) {
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        documents.remove(at: index)
        tabView.removeTabViewItem(tabView.tabViewItem(at: index))
        document.close()
        syncTabStrip()
        refreshTitleAndHighlight()
        onDocumentsChange?()
    }

    /// Removes a tab without closing its document, for a move to another window.
    func detachTab(at index: Int) -> DocumentWindowController? {
        guard documents.indices.contains(index),
            tabView.tabViewItems.indices.contains(index)
        else { return nil }
        let document = documents.remove(at: index)
        tabView.removeTabViewItem(tabView.tabViewItem(at: index))
        document.suspendFindBar()
        document.onContentChange = nil
        document.hostWindow = nil
        syncTabStrip()
        refreshTitleAndHighlight()
        onDocumentsChange?()
        return document
    }

    /// Mounts a detached document as this window's newest tab.
    func attachTab(_ document: DocumentWindowController) {
        document.hostWindow = window
        document.onContentChange = { [weak self, weak document] in
            self?.documentDidChange(document)
        }
        documents.append(document)
        let item = NSTabViewItem(identifier: document.titleText)
        item.view = document.documentContent
        item.label = document.titleText
        item.toolTip = document.fileURL?.path
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        latchRootIfNeeded(for: document)
        syncTabStrip()
        refreshTitleAndHighlight()
        onDocumentsChange?()
    }

    private func documentDidChange(_ document: DocumentWindowController?) {
        guard let document, let index = documents.firstIndex(where: { $0 === document }) else {
            return
        }
        let item = tabView.tabViewItem(at: index)
        item.label = document.titleText
        item.toolTip = document.fileURL?.path
        if tabStripModel.items.indices.contains(index) {
            tabStripModel.items[index].title = document.titleText
            tabStripModel.items[index].isEdited = document.hasUnsavedChanges
            tabStripModel.items[index].toolTip = document.fileURL?.path
        }
        // Opening or saving into a path can establish the latched root, but it
        // never moves an existing root.
        latchRootIfNeeded(for: document)
        guard document === selectedDocument else { return }
        refreshTitleAndHighlight()
    }

    // MARK: - Single-root sidebar

    /// The tree's fixed root. Only explicit window actions and preference
    /// changes move it - never a tab switch.
    var rootURL: URL? { filesPanel.rootURL }

    private func effectiveRoot(preference: URL?) -> URL? {
        pinnedRoot ?? preference ?? latchedRoot
    }

    /// Sets the initial root once, right after the host is created.
    func setInitialRoot(preference: URL?) {
        filesPanel.setRoot(effectiveRoot(preference: preference), fallback: nil)
        refreshTitleAndHighlight()
    }

    /// Re-resolves the root after a preference change. A set root only reloads
    /// on this path (or the one-time latch below), so switching tabs never
    /// makes the tree jump.
    func refreshForPreferences(preference: URL?, environment: EditorEnvironment) {
        self.environment = environment
        filesPanel.setRoot(effectiveRoot(preference: preference), fallback: nil)
        refreshTitleAndHighlight()
    }

    /// Adopts the first document's folder when the window has no root yet. One
    /// way: once set it never follows later tabs.
    private func latchRootIfNeeded(for document: DocumentWindowController) {
        guard filesPanel.rootURL == nil else { return }
        guard pinnedRoot == nil else { return }
        guard let folder = document.fileURL?.deletingLastPathComponent() else { return }
        latchedRoot = folder
        filesPanel.setRoot(folder, fallback: nil)
    }

    /// Highlights the selected document and updates the window title.
    /// Deliberately never touches the root: a file outside the root simply
    /// shows no highlight.
    func refreshTitleAndHighlight() {
        let document = selectedDocument
        filesPanel.current(url: document?.fileURL)
        if let document {
            window?.title = document.titleText
            window?.isDocumentEdited = document.hasUnsavedChanges
            contentRoot?.setTitleText(document.titleText)
        }
    }

    // MARK: - Panels

    var areFilesVisible: Bool { contentRoot?.isFilesVisible ?? false }

    func setFilesVisible(_ visible: Bool) {
        contentRoot?.setFilesVisible(visible)
    }

    func toggleFiles(_ sender: Any?) {
        setFilesVisible(!areFilesVisible)
    }

    /// Shows the file tree without toggling it away when it is already up.
    func showFilesPanel() {
        guard !areFilesVisible else { return }
        setFilesVisible(true)
    }

    var showHiddenFiles: Bool {
        get { filesPanel.showsHiddenFiles }
        set { filesPanel.showsHiddenFiles = newValue }
    }

    /// The "+": a new Markdown file in the tree's folder, opened once it
    /// exists on disk.
    private func createFileInFolder() {
        guard let window, let folder = filesPanel.rootURL else { return }
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.allowedContentTypes = [.plainText, .markdown]
        panel.nameFieldStringValue = "Untitled.md"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data().write(to: url)
            }
            self.onSelectFile?(url)
            self.filesPanel.refresh()
        }
    }

    // MARK: - Theme

    func apply(theme: EditorTheme) {
        self.theme = theme
        window?.backgroundColor = theme.background.nsColor
        filesPanel.apply(theme: theme)
        contentRoot?.apply(theme: theme)
        for document in documents {
            document.apply(theme: theme)
        }
    }

    // MARK: - Middle click

    private func installMiddleClickMonitor() {
        middleClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.otherMouseDown, .otherMouseUp]
        ) { [weak self] event in
            guard let self, event.buttonNumber == 2, event.window === self.window else {
                return event
            }
            switch event.type {
            case .otherMouseDown:
                self.middlePressedTabID = self.tabID(at: event)
                return self.middlePressedTabID == nil ? event : nil
            case .otherMouseUp:
                guard let pressed = self.middlePressedTabID else { return event }
                self.middlePressedTabID = nil
                if let id = self.tabID(at: event), id == pressed,
                    let index = self.tabStripModel.items.firstIndex(where: { $0.id == id })
                {
                    self.closeTab(at: index)
                }
                return nil
            default:
                return event
            }
        }
    }

    /// The tab under an event, in strip coordinates. Geometry mirrors
    /// `EditorTabStripLayout`: viewport minus strip inset, then track offset.
    private func tabID(at event: NSEvent) -> ObjectIdentifier? {
        guard let host = tabStripHost, let window else { return nil }
        let local = host.convert(event.locationInWindow, from: nil)
        guard host.bounds.contains(local) else { return nil }
        let trackWidth = EditorTabStripLayout.viewportWidth(containerWidth: host.bounds.width)
        guard trackWidth > 0 else { return nil }
        let viewportX = local.x - EditorTabStripLayout.stripInset
        guard viewportX >= 0, viewportX <= trackWidth else { return nil }
        let count = tabStripModel.items.count
        guard count > 0 else { return nil }
        let width = EditorTabStripLayout.tabWidth(containerWidth: trackWidth, count: count)
        let contentX = viewportX - tabStripModel.trackContentOffset
        guard contentX >= 0, contentX < CGFloat(count) * width else { return nil }
        return tabStripModel.items[Int(contentX / width)].id
    }

    // MARK: - NSTabViewDelegate

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard !isReorderingTabs else { return }
        let selected = selectedDocument
        // A fresh tab moves first responder into its editor; AppKit leaves it
        // wherever the previous tab had it. Only for the key window and never
        // out of source mode, so background opens and mode switches keep focus.
        if let selected, window?.isKeyWindow == true,
            !selected.isSourceModeActive
        {
            window?.makeFirstResponder(selected.editor)
        }
        // Each tab owns its find bar: park the others, restore this one's.
        for document in documents where document !== selected {
            document.suspendFindBar()
        }
        selected?.restoreFindBarIfNeeded()
        syncTabStrip()
        refreshTitleAndHighlight()
        onSelectionChange?()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        onSelectionChange?()
    }

    func windowWillClose(_ notification: Notification) {
        if let middleClickMonitor {
            NSEvent.removeMonitor(middleClickMonitor)
            self.middleClickMonitor = nil
        }
        for document in documents {
            document.close()
        }
        documents.removeAll()
        onDocumentsChange?()
        onClosed?()
    }
}
