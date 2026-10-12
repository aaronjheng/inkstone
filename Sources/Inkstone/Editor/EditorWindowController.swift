import AppKit
import SwiftUI

/// One window: the global Files panel on the left and an `NSTabView` of
/// documents on the right, VSCode-style.
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
    private var theme: EditorTheme
    private var environment: EditorEnvironment

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

    init(theme: EditorTheme, environment: EditorEnvironment) {
        self.theme = theme
        self.environment = environment
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
        window.delegate = self
        tabView.delegate = self
        filesPanel.prepare()
        filesPanel.onSelect = { [weak self] url in self?.onSelectFile?(url) }
        filesPanel.onCreateFile = { [weak self] in self?.createFileInFolder() }
        tabStripModel.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabStripModel.onClose = { [weak self] index in self?.closeTab(at: index) }
        tabStripModel.onNewTab = { [weak self] in self?.onNewTab?() }
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
        syncTabStrip()
        syncSidebar()
        onDocumentsChange?()
        return document
    }

    private func syncTabStrip() {
        tabStripModel.items = documents.map {
            EditorTabStripModel.Item(id: ObjectIdentifier($0), title: $0.titleText)
        }
        if let document = selectedDocument {
            tabStripModel.selectedIndex = documents.firstIndex(where: { $0 === document })
        } else {
            tabStripModel.selectedIndex = nil
        }
    }

    func select(document: DocumentWindowController) {
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        selectTab(at: index)
    }

    private func selectTab(at index: Int) {
        guard tabView.tabViewItems.indices.contains(index) else { return }
        tabView.selectTabViewItem(at: index)
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
            syncSidebar()
        }
    }

    /// Closes one tab's document; the window survives unless it was the last one.
    func removeDocument(_ document: DocumentWindowController) {
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        documents.remove(at: index)
        tabView.removeTabViewItem(tabView.tabViewItem(at: index))
        document.close()
        syncTabStrip()
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
        }
        guard document === selectedDocument else { return }
        window?.title = document.titleText
        window?.isDocumentEdited = document.hasUnsavedChanges
        contentRoot?.setTitleText(document.titleText)
        syncSidebar()
    }

    /// The tree follows the focused tab: its folder is the root, its file is
    /// marked. The preference's folder wins over the document's own, exactly
    /// as it did when each window owned its tree.
    func syncSidebar() {
        let document = selectedDocument
        filesPanel.setRoot(
            environment.sidebarFolder ?? document?.fileURL?.deletingLastPathComponent(),
            fallback: nil
        )
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
    }

    // MARK: - NSTabViewDelegate

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        // A fresh tab moves first responder into its editor; AppKit leaves it
        // wherever the previous tab had it.
        if let document = selectedDocument {
            window?.makeFirstResponder(document.editor)
        }
        syncTabStrip()
        syncSidebar()
        onSelectionChange?()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        onSelectionChange?()
    }

    func windowWillClose(_ notification: Notification) {
        for document in documents {
            document.close()
        }
        documents.removeAll()
        onDocumentsChange?()
        onClosed?()
    }
}
