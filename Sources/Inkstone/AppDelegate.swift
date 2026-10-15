import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Application delegate: menu bar, window lifecycle, and file handling.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let store = AppStore.shared
    private var isTerminating = false
    /// Set once `prepareUI` has run. `applicationDidFinishLaunching` is posted
    /// more than once in a normal launch (`run()` posts it, and the app can be
    /// re-launched into an existing instance), and each pass would otherwise
    /// open another window.
    private var didPrepareUI = false
    /// Files delivered by `application(_:open:)` before `prepareUI` ran, flushed
    /// by it. A Finder "Open With" delivers its file as an Apple Event that can
    /// land before the launch is prepared.
    private var earlyOpenURLs: [URL] = []

    override public init() { super.init() }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Re-apply the stored theme once the windows exist, so a launch always
        // starts on the user's theme rather than the build default.
        store.themeManager.apply()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Deferred by a turn: `InkstoneApp.main` calls `applicationWillFinishLaunching`
        // by hand before `run()`, and a document handed over by LaunchServices can
        // arrive as an Apple Event in between. One turn is enough for it to land in
        // `earlyOpenURLs`, after which the handed files take precedence over the
        // launch option.
        DispatchQueue.main.async { [self] in
            prepareUI()
        }
    }

    /// LaunchServices delivery: "Open With", drag-to-dock and `open -a` arrive here
    /// rather than on the command line once the app is already running. The reply is
    /// what stops the Finder showing a spinning beachball.
    public func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            // LaunchServices can deliver the Open event before the launch option
            // has run; holding those URLs keeps them from being lost in a window
            // that does not exist yet.
            if !didPrepareUI {
                earlyOpenURLs.append(contentsOf: urls)
            } else {
                open(urls)
            }
            NSApp.reply(toOpenOrPrint: .success)
        }
    }

    /// Builds the menu and opens the launch's documents.
    ///
    /// Deferred to the first run-loop turn by `applicationDidFinishLaunching`:
    /// a Finder "Open With" delivers its files as an Apple Event that can land
    /// before this passes, and running the launch option first would open the
    /// tree's first document over the file the user actually asked for.
    func prepareUI() {
        guard !didPrepareUI else { return }
        didPrepareUI = true
        NSApp.mainMenu = MenuBuilder.build(store: store, responder: self)
        restoreRecentFiles()
        restoreRecentFolders()
        store.settings.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.pushSettingsToWindows() }
        }
        pushSettingsToWindows()
        // The menu checkmarks are rebuilt on demand (see `menuNeedsUpdate`); this
        // event is what makes a window/tab switch re-read the focused document's
        // panel state. It used to have no subscriber at all, so the notifications
        // were fired into the void.
        store.onWindowsChange = { [weak self] in
            MainActor.assumeIsolated { self?.refreshViewCheckmarks() }
        }
        // Open whatever the Finder, `open -a` or the command line handed us *before*
        // creating a scratch window: opening a file that then leaves an empty Untitled
        // window behind is what made the tab bar read "Untitled" three times over.
        // Deduplicate: LaunchServices can deliver the same file multiple times
        // (cold-launch replay plus the queued Apple Event), and opening
        // duplicates creates extra windows.
        let allFiles = launchFileURLs() + earlyOpenURLs
        earlyOpenURLs.removeAll()
        var seenPaths = Set<String>()
        var launched: [URL] = []
        for file in allFiles where !seenPaths.contains(file.path) {
            seenPaths.insert(file.path)
            launched.append(file)
        }
        let recovered = recoverableDrafts()
        if !launched.isEmpty {
            // Handed files by the Finder: they win, drafts ride along.
            let files = open(launched)
            store.recoverDrafts(recovered)
            // Draft tabs are appended after the handed files, so end with the
            // handed files selected instead of a stale draft.
            for file in files { _ = store.focus(file) }
        } else if store.settings.settings.launchOption == .openNewFile {
            // The default option has no folder of its own to open, so the
            // recovered documents are the launch.
            store.recoverDrafts(recovered)
            if recovered.isEmpty { store.newWindow() }
        } else {
            // A chosen launch option is the session-restore choice, so it runs
            // *instead of* the drafts: a stale untitled draft used to shadow the
            // option, opening an untitled window and leaving the tree empty.
            // The drafts stay on disk and come back when the option is
            // switched back to the default.
            if !applyLaunchOption() {
                store.newWindow()
            }
        }
    }

    /// What the "启动选项" (launch option) preference asks for, when the launch
    /// handed over no files. Returns whether a window was opened.
    private func applyLaunchOption() -> Bool {
        switch store.settings.settings.launchOption {
        case .openNewFile:
            store.newWindow()
            return true
        case .reopenLastFolder:
            let folder = store.recentFolders.first
            if !reopenFolder(folder) {
                AppLogger.warn("No usable folder in the recent list", category: "Document")
                return false
            }
            return true
        case .reopenLastFilesAndFolders:
            var opened = false
            for folder in store.recentFolders
            where FileManager.default.fileExists(atPath: folder.path) {
                if reopenFolder(folder) { opened = true }
            }
            for url in store.recentFiles
            where FileManager.default.fileExists(atPath: url.path) {
                store.open(url)
                opened = true
            }
            if !opened {
                AppLogger.warn("Nothing recent to reopen", category: "Document")
            }
            return opened
        case .openSpecifiedFolder:
            guard let folder = store.settings.settings.launchFolder else {
                AppLogger.warn("Launch option is a folder, none is chosen", category: "Document")
                return false
            }
            if !reopenFolder(folder) {
                AppLogger.warn("Launch folder missing: \(folder.path)", category: "Document")
                return false
            }
            return true
        }
    }

    /// Opens a folder: its first document in a window whose file tree is rooted
    /// there and shown. Returns whether a window was actually opened.
    @discardableResult
    private func reopenFolder(_ url: URL?) -> Bool {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return false }
        let files = markdownFiles(in: url)
        guard let first = files.first else { return false }
        let host = store.newHost(sidebarFolder: url)
        let document = store.newDocument(markdown: "", url: first, in: host)
        do {
            try document.open(first)
            store.noteRecentFolder(url)
            host.showFilesPanel()
            return true
        } catch {
            present(error, for: document)
            return false
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        defer { isTerminating = false }
        let dirty = store.documents.filter(\.hasUnsavedChanges)
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText =
            dirty.count == 1
            ? "Save changes to “\(dirty[0].fileURL?.lastPathComponent ?? "Untitled")”?"
            : "Save changes to \(dirty.count) documents?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for document in dirty {
                do {
                    // An untitled document has nowhere to save until the user
                    // picks a path; the old path fell through `save()`'s guard and
                    // destroyed the content on quit even though Save was chosen.
                    if try promptSave(document) { continue }
                    return .terminateCancel
                } catch {
                    present(error, for: document)
                    return .terminateCancel
                }
            }
            return .terminateNow
        case .alertSecondButtonReturn:
            // The user explicitly declined: the drafts must not come back as a
            // recovery prompt on the next launch.
            store.discardDrafts(for: dirty)
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Saves `document`, asking for a path first when it has none. Returns false
    /// when the user cancelled the panel.
    private func promptSave(_ document: DocumentWindowController) throws -> Bool {
        guard document.fileURL == nil else {
            try document.save()
            return true
        }
        guard document.hostWindow != nil else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .markdown]
        panel.nameFieldStringValue = "Untitled.md"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try document.saveAs(url)
        store.noteRecent(url)
        return true
    }

    // MARK: - Launch arguments

    /// `open -a the original file.md` and the shell-integration form the original supports
    /// both land here as plain paths.
    /// Files named on the command line.
    ///
    /// `-psn_0_12345` is what the Finder passes to identify the process, and it is not
    /// a path - which is why the arguments are filtered rather than taken wholesale.
    private func launchFileURLs() -> [URL] {
        CommandLine.arguments.dropFirst()
            .filter { argument in
                guard !argument.hasPrefix("-") else { return false }
                return ["md", "markdown", "mdown", "txt"]
                    .contains((argument as NSString).pathExtension.lowercased())
            }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private func restoreRecentFiles() {
        let paths = UserDefaults.standard.stringArray(forKey: "recentFiles") ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser
        store.restoreRecentFiles(
            paths.map {
                URL(fileURLWithPath: $0.replacingOccurrences(of: "~", with: home.path))
            }
        )
    }

    private func restoreRecentFolders() {
        let paths = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        let home = FileManager.default.homeDirectoryForCurrentUser
        store.restoreRecentFolders(
            paths.map {
                URL(fileURLWithPath: $0.replacingOccurrences(of: "~", with: home.path))
            }
        )
    }

    // Recent files and folders persist themselves inside `AppStore`; the
    // restore hooks below are the only launch-time work left here.

    // MARK: - File actions

    @objc func newDocument(_ sender: Any?) {
        store.newDocument()
    }

    /// A tab in the focused window, as `⌘T` in every tabbed app: the system
    /// reserves `⌘Tab` for the application switcher and never delivers it.
    @objc func newTab(_ sender: Any?) {
        store.newDocument()
    }

    /// A whole new window with one scratch tab - `⌘⌥N`, for when the Files
    /// panel should start over on another folder.
    @objc func newWindow(_ sender: Any?) {
        store.newWindow()
    }

    @objc func showPreviousTab(_ sender: Any?) {
        store.focusedHost?.selectPreviousTab()
    }

    @objc func showNextTab(_ sender: Any?) {
        store.focusedHost?.selectNextTab()
    }

    @objc func showTab(_ sender: Any?) {
        guard let number = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        store.focusedHost?.selectTabNumber(number)
    }

    @objc func openDocument(_ sender: Any?) {
        // Open Recent routes through here with the URL in the item's
        // representedObject; ignoring it made every recent-files row open the
        // file panel instead of the file.
        if let item = sender as? NSMenuItem, let url = item.representedObject as? URL {
            open([url])
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, .markdown]
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let files = markdownFiles(in: url)
        // Opening a folder opens its first document, and shows the file tree
        // rooted at the folder itself. The folder is not a window in this app;
        // the hierarchy on the left *is* the folder, so leaving the panel hidden
        // would make an open folder indistinguishable from opening one file.
        guard let first = files.first else {
            AppLogger.info("No Markdown files in \(url.lastPathComponent)", category: "Document")
            return
        }
        if files.count > 1 {
            AppLogger.info(
                "Opened \(first.lastPathComponent); \(files.count - 1) more in the sidebar",
                category: "Document"
            )
        }
        reopenFolder(url)
    }

    @discardableResult
    func open(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                files.append(contentsOf: markdownFiles(in: url))
            } else {
                files.append(url)
            }
        }
        guard !files.isEmpty else { return [] }
        // The store reuses the focused window's empty scratch tab, so an app
        // launched on one file never leaves an empty Untitled behind.
        for file in files { store.open(file) }
        // A directory handed to `open` is a folder open: remember it so the
        // reopen-last-folder launch option has something to reopen.
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            {
                store.noteRecentFolder(url)
            }
        }
        return files
    }

    /// Markdown files inside a folder, recursively, in path order.
    func markdownFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard ["md", "markdown", "mdown", "txt"].contains(url.pathExtension.lowercased())
            else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let window = store.focusedWindow else { return }
        do {
            // ⌘S on an untitled document has to ask where, exactly like TextEdit -
            // the old path hit `save()`'s nil-URL guard and silently did nothing.
            _ = try promptSave(window)
        } catch {
            present(error, for: window)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let window = store.focusedWindow else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = window.fileURL?.lastPathComponent ?? "Untitled.md"
        panel.allowedContentTypes = [.plainText, .markdown]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try window.saveAs(url)
            store.noteRecent(url)
        } catch {
            present(error, for: window)
        }
    }

    /// The formats offered by Export.
    private enum ExportFormat: CaseIterable {
        case html
        case opml
        case markdown
        case pdf

        var title: String {
            switch self {
            case .html: return "HTML (styled)"
            case .opml: return "OPML (outline)"
            case .markdown: return "Markdown (GitHub)"
            case .pdf: return "PDF"
            }
        }

        var fileExtension: String {
            switch self {
            case .html: return "html"
            case .opml: return "opml"
            case .markdown: return "md"
            case .pdf: return "pdf"
            }
        }

        var contentType: UTType {
            switch self {
            case .html: return .html
            case .opml: return UTType(filenameExtension: "opml") ?? .xml
            case .markdown: return .plainText
            case .pdf: return .pdf
            }
        }
    }

    @objc func exportDocument(_ sender: Any?) {
        guard let window = store.focusedWindow else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            (window.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".html"
        panel.allowedContentTypes = ExportFormat.allCases.map(\.contentType)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let format =
            ExportFormat.allCases.first { $0.fileExtension == url.pathExtension.lowercased() }
            ?? .html
        let title = window.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        if format == .pdf {
            do {
                try PrintService.writePDF(
                    of: window.editor,
                    title: title,
                    to: url
                )
            } catch {
                present(error, for: window)
            }
            return
        }
        let text: String
        switch format {
        case .html:
            text = HTMLWriter.write(
                document: window.markdown,
                title: title,
                css: ExportCSS.styleSheet(for: store.themeManager.theme)
            )
        case .opml:
            text = OPMLWriter.write(document: window.markdown, title: title)
        case .markdown:
            // The buffer *is* the Markdown, so this variant is a copy rather than a
            // re-serialisation - which is the whole point of the source invariant.
            text = window.editor.markdown
        case .pdf:
            return
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            present(error, for: window)
        }
    }

    /// Prints the focused document through the system print panel.
    @objc func printDocument(_ sender: Any?) {
        guard let window = store.focusedWindow else { return }
        let operation = PrintService.operation(
            for: window.editor,
            title: window.fileURL?.lastPathComponent ?? "Untitled"
        )
        guard let sheet = window.hostWindow else { return }
        operation.runModal(for: sheet, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Image actions: the image path resolves against the document's folder and the
    /// operation is performed by the file manager rather than by rewriting the node.
    /// The node is rebuilt from the result (new name or moved file), which is the same
    /// principle as `tryResetTable` - the source is always the authority.

    /// An `![alt](path)` syntax found in the buffer, addressed in buffer coordinates so
    /// the action can edit exactly the path (or the whole syntax) and nothing else.
    private struct ImageRef {
        let path: String
        let pathRange: NSRange
        let syntaxRange: NSRange
    }

    /// The `![alt](path)` under the caret, falling back to the block's first image.
    private func imageRef(in window: DocumentWindowController) -> ImageRef? {
        guard let storage = window.editor.textStorage else { return nil }
        let caret = window.editor.selectedRange().location
        guard let blockRange = window.editor.layout.block(containing: caret)?.range else { return nil }
        let full = storage.string as NSString
        let block = full.substring(with: blockRange) as NSString
        var found: ImageRef?
        var cursor = 0
        while cursor < block.length {
            let bang = block.range(of: "![", options: [], range: NSRange(location: cursor, length: block.length - cursor))
            guard bang.location != NSNotFound else { break }
            let open = block.range(
                of: "](", options: [], range: NSRange(location: bang.upperBound, length: block.length - bang.upperBound)
            )
            guard open.location != NSNotFound else {
                cursor = bang.upperBound
                continue
            }
            let close = block.range(
                of: ")", options: [], range: NSRange(location: open.upperBound, length: block.length - open.upperBound)
            )
            guard close.location != NSNotFound else {
                cursor = open.upperBound
                continue
            }
            let pathRange = NSRange(
                location: blockRange.location + open.upperBound, length: close.location - open.upperBound
            )
            let ref = ImageRef(
                path: full.substring(with: pathRange),
                pathRange: pathRange,
                syntaxRange: NSRange(
                    location: blockRange.location + bang.location, length: close.upperBound - bang.location
                )
            )
            if NSLocationInRange(caret, ref.syntaxRange) { return ref }
            if found == nil { found = ref }
            cursor = close.upperBound
        }
        return found
    }

    /// Resolves the Markdown path the same way the painter does, so every image action
    /// touches the file the editor is actually drawing.
    private func imageURL(_ path: String, in window: DocumentWindowController) -> URL? {
        window.editor.imagePainter.resolve(path)
            ?? window.fileURL?.deletingLastPathComponent().appendingPathComponent(path)
    }

    /// Keeps the path in the buffer relative whenever the file stays under the document
    /// folder, because that is what survives moving the document to another machine.
    private func pathText(for url: URL, in window: DocumentWindowController) -> String {
        let base = window.editor.imagePainter.baseDirectory ?? window.fileURL?.deletingLastPathComponent()
        guard let base else { return url.path }
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(basePath + "/") { return String(path.dropFirst(basePath.count + 1)) }
        return url.path
    }

    private func replaceImagePath(_ url: URL, in window: DocumentWindowController, ref: ImageRef) {
        let text = pathText(for: url, in: window)
        // Through the editor's editing path: the old direct-storage write bypassed
        // undo, `load(markdown:)` threw the whole undo stack away, and neither
        // marked the document dirty, so a renamed image silently vanished from the
        // edited state and could be lost on close.
        window.editor.apply(
            FormatController.Edit(
                range: ref.pathRange,
                text: text,
                selection: NSRange(
                    location: ref.pathRange.location + text.utf16.count, length: 0
                )
            )
        )
    }

    private func bitmapFileType(for url: URL) -> NSBitmapImageRep.FileType? {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "gif": return .gif
        case "bmp": return .bmp
        case "tif", "tiff": return .tiff
        default: return nil
        }
    }

    @objc func imageDelete(_ sender: Any?) {
        guard let window = store.focusedWindow, let ref = imageRef(in: window) else { return }
        let url = imageURL(ref.path, in: window)
        let exists = url.flatMap({ FileManager.default.fileExists(atPath: $0.path) }) == true
        if exists, let url {
            // One menu item used to unlink a file from disk with no warning - a file
            // other documents may reference. The syntax is recoverable by undo, the
            // file is not.
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Delete “\(url.lastPathComponent)”?"
            alert.informativeText =
                "The image file moves to the Trash and the reference is removed from the document."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if exists, let url {
            var trashed: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            } catch {
                present(error, for: window)
                return
            }
        }
        window.editor.imagePainter.invalidate()
        window.editor.apply(
            FormatController.Edit(
                range: ref.syntaxRange,
                text: "",
                selection: NSRange(location: ref.syntaxRange.location, length: 0)
            )
        )
    }

    @objc func imageRename(_ sender: Any?) {
        guard let window = store.focusedWindow, let ref = imageRef(in: window), !ref.path.isEmpty else { return }
        guard let url = imageURL(ref.path, in: window), let sheet = window.hostWindow else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.beginSheetModal(for: sheet) { result in
            guard result == .OK, let saveURL = panel.url else { return }
            if saveURL.standardizedFileURL.path == url.standardizedFileURL.path { return }
            do {
                if FileManager.default.fileExists(atPath: saveURL.path) {
                    _ = try FileManager.default.replaceItemAt(
                        saveURL, withItemAt: url, backupItemName: nil, options: []
                    )
                } else {
                    try FileManager.default.moveItem(at: url, to: saveURL)
                }
            } catch {
                self.present(error, for: window)
                return
            }
            window.editor.imagePainter.invalidate()
            self.replaceImagePath(saveURL, in: window, ref: ref)
        }
    }

    @objc func imageMove(_ sender: Any?) {
        guard let window = store.focusedWindow, let ref = imageRef(in: window), !ref.path.isEmpty else { return }
        guard let url = imageURL(ref.path, in: window), let sheet = window.hostWindow else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move"
        panel.beginSheetModal(for: sheet) { result in
            guard result == .OK, let folder = panel.url else { return }
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            if destination.standardizedFileURL.path == url.standardizedFileURL.path {
                return
            }
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Replace “\(destination.lastPathComponent)”?"
                    alert.informativeText =
                        "An image with this name already exists in the destination folder."
                    alert.addButton(withTitle: "Replace")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    _ = try FileManager.default.replaceItemAt(
                        destination, withItemAt: url, backupItemName: nil, options: []
                    )
                } else {
                    try FileManager.default.moveItem(at: url, to: destination)
                }
            } catch {
                self.present(error, for: window)
                return
            }
            window.editor.imagePainter.invalidate()
            self.replaceImagePath(destination, in: window, ref: ref)
        }
    }

    @objc func imageScaleHalf(_ sender: Any?) {
        guard let window = store.focusedWindow, let ref = imageRef(in: window), !ref.path.isEmpty else { return }
        guard let url = imageURL(ref.path, in: window), let image = NSImage(contentsOf: url) else { return }
        guard let fileType = bitmapFileType(for: url) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Cannot scale “\(url.lastPathComponent)”."
            alert.informativeText = "Scaling in place supports PNG, JPEG, GIF, BMP and TIFF files."
            alert.runModal()
            return
        }
        // The rewrite is destructive: the original pixels are gone after it.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Scale “\(url.lastPathComponent)” to 50%?"
        alert.informativeText = "The file on disk is rewritten at half its pixel size."
        alert.addButton(withTitle: "Scale")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let tiff = image.tiffRepresentation, let source = NSBitmapImageRep(data: tiff) else { return }
        // Halve the pixels rather than the point size, so the file really gets smaller
        // instead of shipping a half-size image at double density.
        let wide = max(Int((Double(source.pixelsWide) / 2).rounded()), 1)
        let high = max(Int((Double(source.pixelsHigh) / 2).rounded()), 1)
        guard
            let canvas = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            )
        else { return }
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: canvas) {
            NSGraphicsContext.current = context
        }
        image.draw(in: NSRect(x: 0, y: 0, width: wide, height: high))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = canvas.representation(using: fileType, properties: [:]) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            present(error, for: window)
            return
        }
        window.editor.imagePainter.invalidate()
        window.editor.markDirty()
    }

    @objc func revertDocument(_ sender: Any?) {
        guard let window = store.focusedWindow, let url = window.fileURL else { return }
        do {
            try window.open(url)
        } catch {
            present(error, for: window)
        }
    }

    /// Table operations enable only on a table: elsewhere they would be a
    /// silent no-op, and a menu must not offer those. Everything else stays
    /// enabled; validation here covers only the items this target owns.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let raw = menuItem.representedObject as? String,
            let action = FormatAction(rawValue: raw)
        else { return true }
        switch action {
        case .tableRowAbove, .tableRowBelow, .tableDeleteRow,
            .tableColumnLeft, .tableColumnRight, .tableDeleteColumn,
            .tableAlignLeft, .tableAlignCenter, .tableAlignRight:
            guard let editor = store.focusedWindow?.editor,
                let text = editor.textStorage?.string
            else { return false }
            return FormatController.containsTable(at: editor.selectedRange().location, in: text)
        default:
            return true
        }
    }

    /// One action for every Format-menu entry.
    ///
    /// The command rides on the item's `representedObject` rather than needing a
    /// selector per row: adding a command is then a `MenuBuilder` line and a
    /// `FormatController` case, not three files.
    @objc func applyFormatting(_ sender: Any?) {        guard let item = sender as? NSMenuItem,
            let raw = item.representedObject as? String,
            let action = FormatAction(rawValue: raw)
        else { return }
        store.focusedWindow?.format(action)
    }

    /// Copy puts the styled text AppKit builds from the buffer; this puts the
    /// Markdown source itself, which is what the menu item promises.
    @objc func copyAsMarkdown(_ sender: Any?) {
        guard let window = store.focusedWindow else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(window.editor.markdown, forType: .string)
    }

    /// ⌘W: the focused tab; the window closes when it was the last tab.
    @objc func closeDocument(_ sender: Any?) {
        store.closeFocusedDocument()
    }

    private func present(_ error: Error, for window: DocumentWindowController?) {
        AppLogger.error("\(error)", category: "File")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The operation could not be completed."
        alert.informativeText = error.localizedDescription
        if let sheet = window?.hostWindow {
            alert.beginSheetModal(for: sheet, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - View actions

    /// Menu checkmarks are read live: the View and Themes menus rebuild their
    /// state every time they open, so a mode flipped by one window is reflected
    /// everywhere. Static state computed at build time used to contradict the
    /// app after the first toggle.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "View" {
            refreshViewCheckmarks()
        } else if menu.title == "Themes" {
            refreshThemesMenu()
        }
    }

    /// Flips the checkmarks in the View menu to match the focused window.
    ///
    /// Files is the window's panel and Outline is the document's, so "Sidebar"
    /// - which drives both - is on when either is showing.
    private func refreshViewCheckmarks() {
        guard
            let viewMenu = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?
                .submenu
        else { return }
        let host = store.focusedHost
        let document = host?.selectedDocument
        let states: [String: Bool] = [
            "Source Code Mode": document?.isSourceModeActive ?? store.sourceMode,
            "Sidebar": (host?.areFilesVisible ?? false) || (document?.isOutlineVisible ?? false),
            "Files": host?.areFilesVisible ?? false,
            "Outline": document?.isOutlineVisible ?? false,
            "Focus Mode": store.focusMode,
            "Typewriter Mode": store.typeWriterMode,
            "Readonly Mode": store.readonlyMode,
        ]
        for item in viewMenu.items where states[item.title] != nil {
            item.state = states[item.title] == true ? .on : .off
        }
    }

    @objc func openSettings(_ sender: Any?) {
        PreferencesController.shared.show()
    }

    // MARK: - About & License panels

    /// Small panels whose content is pure SwiftUI (About, License): one window
    /// per panel, brought forward when already open and disposed on close by
    /// `windowWillClose` so no hidden zombie survives.
    private enum UtilityPanel: Hashable {
        case about
        case license
        case reference
    }

    private var utilityWindows: [UtilityPanel: NSWindow] = [:]

    @objc func openAbout(_ sender: Any?) {
        openUtilityWindow(
            .about,
            title: "About \(MenuBuilder.applicationName)",
            contentSize: AboutMetrics.panelSize,
            resizable: false
        ) {
            AboutView { [weak self] in self?.openLicense() }
        }
    }

    private func openLicense() {
        openUtilityWindow(
            .license,
            title: "\(MenuBuilder.applicationName) License",
            contentSize: AboutMetrics.licenseMinSize,
            resizable: true
        ) {
            LicenseView()
        }
    }

    /// The Help menu's reference: the syntax this editor parses, in a
    /// window rather than a dead menu item.
    @objc func openReference(_ sender: Any?) {
        openUtilityWindow(
            .reference,
            title: "Markdown Reference",
            contentSize: NSSize(width: 560, height: 520),
            resizable: true
        ) {
            MarkdownReferenceView()
        }
    }

    private func openUtilityWindow<Content: View>(
        _ panel: UtilityPanel,
        title: String,
        contentSize: NSSize,
        resizable: Bool,
        @ViewBuilder content: () -> Content
    ) {
        if let window = utilityWindows[panel] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable {
            styleMask.insert([.miniaturizable, .resizable])
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.backgroundColor = .controlBackgroundColor
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: content())
        window.tabbingMode = .disallowed
        // ARC owns the window (see windowWillClose).
        window.isReleasedWhenClosed = false
        window.minSize = contentSize
        window.center()
        window.delegate = self
        utilityWindows[panel] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Releases a closed About/License panel instead of holding a hidden
    /// zombie: reopening builds a fresh window.
    ///
    /// The release is deferred past the close call: `windowWillClose` runs
    /// inside `-[NSWindow close]`, so dropping ARC's last reference there
    /// can deallocate the window mid-close while AppKit still holds its own
    /// close-time reference.
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let panel = utilityWindows.first(where: { $0.value === window })?.key
        else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, !window.isVisible else { return }
            // Identity: a reopen could have replaced the state already.
            if self.utilityWindows[panel] === window {
                self.utilityWindows[panel] = nil
            }
        }
    }

    @objc func quickOpen(_ sender: Any?) {
        let remembered = store.settings.settings.sidebarFolder.map { [$0] } ?? []
        // Single-root: search the windows' fixed roots, not each tab's folder.
        let open = store.hosts.compactMap { $0.rootURL }
        QuickOpenController.shared.setRoots(remembered + open)
        QuickOpenController.shared.onOpen = { [weak self] url in
            self?.openInFocusedWindow(url)
        }
        QuickOpenController.shared.show()
    }

    /// Quick open lands as a tab in the focused window, the same as ⌘O.
    private func openInFocusedWindow(_ url: URL) {
        guard let host = store.focusedHost else { return }
        store.open(url, in: host)
    }

    /// Sidebar is the window's Files panel plus the document's outline; each
    /// toggle still drives its own half so the two can be shown independently.
    @objc func toggleSidebar(_ sender: Any?) {
        guard let host = store.focusedHost else { return }
        let document = host.selectedDocument
        let show = !(host.areFilesVisible || (document?.isOutlineVisible ?? false))
        host.setFilesVisible(show)
        document?.setOutlineVisible(show)
        refreshViewCheckmarks()
    }

    @objc func toggleOutline(_ sender: Any?) {
        guard let document = store.focusedWindow else { return }
        document.toggleOutline(sender)
        refreshViewCheckmarks()
    }

    @objc func toggleFiles(_ sender: Any?) {
        guard let host = store.focusedHost else { return }
        host.toggleFiles(sender)
        refreshViewCheckmarks()
    }

    @objc func toggleFind(_ sender: Any?) {
        guard let window = store.focusedWindow else { return }
        window.toggleFind(sender)
    }

    @objc func findNext(_ sender: Any?) {
        guard let window = store.focusedWindow else { return }
        window.findNext(sender)
    }

    @objc func findPrevious(_ sender: Any?) {
        guard let window = store.focusedWindow else { return }
        window.findPrevious(sender)
    }

    @objc func toggleSourceMode(_ sender: Any?) {
        guard let window = store.focusedWindow else { return }
        window.toggleSourceMode(sender)
        store.sourceMode = window.isSourceModeActive
        refreshViewCheckmarks()
    }

    /// Flips the checkmark on View -> Source Code Mode.
    private func refreshSourceModeItem() {
        guard
            let viewMenu = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?
                .submenu,
            let item = viewMenu.items.first(where: { $0.title == "Source Code Mode" })
        else { return }
        item.state = store.sourceMode ? .on : .off
    }

    /// Drafts worth handing back at launch, each openable as its own window.
    ///
    /// Only drafts newer than the file they mirror are offered: the file on disk is
    /// the last manual save and the draft holds everything typed since, so anything
    /// older is content the user already saved elsewhere.
    private func recoverableDrafts() -> [Draft] {
        store.drafts.recoverable.filter { draft in
            guard let url = draft.sourceURL else { return true }
            return store.drafts.isNewer(draft, thanFileAt: url)
        }
    }

    /// Pushes the preferences every open document tab and window panel mirrors.
    ///
    /// Focus, typewriter and readonly live on `AppStore` rather than in the settings
    /// file - they are view state a user flips for the session - so they are merged
    /// with the stored preferences here rather than in either place.
    private func pushSettingsToWindows() {
        let view = mergedEditorSettings()
        for document in store.documents {
            document.applyEditorSettings(view)
            document.applyParseOptions(store.settings.settings.parseOptions)
            document.autosaveInterval = store.autosaveInterval
        }
        // Single-root: a preference change re-resolves each window's fixed root
        // (pinned folders stay put) and refreshes the environment new tabs copy.
        let environment = EditorEnvironment(
            parseOptions: store.settings.settings.parseOptions,
            sidebarFolder: store.settings.settings.sidebarFolder,
            wordsPerMinute: store.settings.settings.wordsPerMinute
        )
        for host in store.hosts {
            host.showHiddenFiles = view.showHiddenFiles
            host.refreshForPreferences(
                preference: store.settings.settings.sidebarFolder,
                environment: environment
            )
        }
    }

    private func mergedEditorSettings() -> EditorSettingsView {
        var view = store.settings.editorView
        view.focus = store.focusMode
        view.typewriter = store.typeWriterMode
        view.readonly = store.readonlyMode
        return view
    }

    @objc func toggleFocusMode(_ sender: Any?) {
        store.focusMode.toggle()
        pushSettingsToWindows()
        refreshViewCheckmarks()
    }

    @objc func toggleTypewriterMode(_ sender: Any?) {
        store.typeWriterMode.toggle()
        pushSettingsToWindows()
        for document in store.documents { document.editor.centerCaretIfNeeded() }
        refreshViewCheckmarks()
    }

    @objc func toggleReadonlyMode(_ sender: Any?) {
        store.readonlyMode.toggle()
        pushSettingsToWindows()
        refreshViewCheckmarks()
    }

    @objc func zoomIn(_ sender: Any?) {
        applyZoom(1.1)
    }

    @objc func zoomOut(_ sender: Any?) {
        applyZoom(1 / 1.1)
    }

    /// Zoom is expressed as a font scale so it composes with the theme's own font
    /// size instead of fighting it.
    private var zoomFactor: CGFloat { CGFloat(store.settings.settings.zoomFactor) }

    private func applyZoom(_ factor: CGFloat) {
        let next = max(0.5, min(zoomFactor * factor, 3))
        store.settings.update { settings in
            settings.zoomFactor = Double(next)
            settings.useCustomFontSize = true
            settings.customFontSize = 16 * Double(next)
        }
        store.themeManager.apply()
    }

    @objc func actualSize(_ sender: Any?) {
        store.settings.update { $0.zoomFactor = 1 }
        store.useThemeFontSize()
    }

    @objc func useThemeFontSize(_ sender: Any?) {
        store.useThemeFontSize()
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        store.setTheme(identifier: identifier)
        refreshThemesMenu()
    }

    /// Syncs the Themes menu's checkmarks with the active theme and font size.
    private func refreshThemesMenu() {
        guard
            let themesMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Themes" })?
                .submenu
        else { return }
        for item in themesMenu.items {
            if let identifier = item.representedObject as? String {
                item.state = identifier == store.theme.identifier ? .on : .off
            } else if item.title == "Use Theme Font Size" {
                item.state = store.settings.settings.useCustomFontSize ? .off : .on
            }
        }
    }
}
