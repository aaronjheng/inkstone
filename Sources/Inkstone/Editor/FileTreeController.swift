import AppKit
import Foundation
import SwiftUI

/// The "Files" panel docked to the window's left edge: the folder containing the
/// open document as an expandable tree, with `.md` files only.
///
/// A search field on top filters the tree by file name, Typora-style: matched
/// text highlights in place, a matched folder reveals everything under it, and
/// clearing the query restores the pre-search expansion state.
///
/// The original shows the whole folder tree and marks the current file. Directories are
/// included so the hierarchy is visible, and reading goes through
/// `NSFileCoordinator` so edits arriving from outside the app do not race the
/// refresh. Nothing watches the file system, so callers that create or delete
/// files by hand have to ask for `refresh()`.
/// One file-tree context-menu command, mirroring Typora's file-tree actions.
///
/// `reveal`, `copyPath`, `refresh`, `expandAll` and `collapseAll` need no
/// window, so `FileTreeController` runs them directly; the rest travel up
/// through `onAction` to the host (sheets, alerts) or the session layer.
enum FileTreeAction {
    case openInNewWindow(URL)
    case newFile(URL)
    case newFolder(URL)
    case duplicate(URL)
    case rename(URL, String)
    case trash(URL)
    case reveal(URL)
    case copyPath(URL)
    case refresh
    case expandAll
    case collapseAll
}

final class FileTreeController: NSViewController {
    var onSelect: ((URL) -> Void)?
    /// The toolbar's "+": creates a file in the tree's folder.
    var onCreateFile: (() -> Void)?
    /// Context-menu commands the host (or session) layer must run.
    var onAction: ((FileTreeAction) -> Void)?

    private let model = FileTreeModel()
    private var hosting: NSHostingView<FileTree>?
    private var root: URL?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The folder the tree is rooted at, for "new file here" affordances.
    var rootURL: URL? { root }

    /// Hidden files are skipped unless the preference asks for them; flipping
    /// the flag re-reads the tree.
    var showsHiddenFiles = false {
        didSet {
            guard oldValue != showsHiddenFiles else { return }
            reload()
        }
    }

    /// Eagerly realise the view.
    ///
    /// `NSViewController` only runs `loadView` when the view is first accessed,
    /// and the panel is shown on demand. Without this the panel would sit empty
    /// until something else triggered the next layout pass.
    func prepare() {
        _ = self.view
    }

    override func loadView() {
        let root = FileTree(
            model: model,
            onSelect: { [weak self] url in self?.onSelect?(url) },
            onCreateFile: { [weak self] in self?.onCreateFile?() },
            onAction: { [weak self] action in self?.run(action) }
        )
        let hosted = NSHostingView(rootView: root)
        hosting = hosted
        view = hosted
    }

    /// Runs the actions that need no window; the rest go up to the host.
    private func run(_ action: FileTreeAction) {
        switch action {
        case let .reveal(url): reveal(url)
        case let .copyPath(url): copyPath(url)
        case .refresh: refresh()
        case .expandAll: expandAll()
        case .collapseAll: collapseAll()
        default: onAction?(action)
        }
    }

    func apply(theme: EditorTheme) {
        model.apply(theme: theme)
    }

    func current(path: String?) {
        model.currentPath = path
        model.revealCurrent()
    }

    func current(url: URL?) {
        current(path: url?.path)
    }

    func setRoot(_ url: URL?, fallback: URL?) {
        let resolved = url ?? fallback
        guard resolved != root else { return }
        root = resolved
        reload()
    }

    /// Re-reads the current folder.
    func refresh() {
        reload()
    }

    /// Selects `url` in the Finder. Read-only, so no root check is needed.
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copies the absolute path, as Typora's "Copy File Path" does.
    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// Expands every folder so "Expand All" shows the whole tree.
    func expandAll() {
        model.expandAll()
    }

    /// Collapses back to the root's top level.
    func collapseAll() {
        model.collapseAll()
    }

    /// Makes sure `path` (a folder) is expanded, so newly created items show.
    func expand(_ path: String) {
        model.setExpanded(path, expanded: true)
    }

    /// Recursively reads the tree under `root`.
    ///
    /// Symlinks are skipped: a link back up the hierarchy would otherwise make
    /// the recursion visit the same directories forever. The depth cap is a
    /// second belt for the same braces.
    private func loadChildren(of folder: URL, depth: Int) -> [FileTreeModel.Entry] {
        guard depth < 16,
            let contents = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: showsHiddenFiles ? [] : [.skipsHiddenFiles]
            )
        else { return [] }
        var folders: [FileTreeModel.Entry] = []
        var files: [FileTreeModel.Entry] = []
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                folders.append(
                    FileTreeModel.Entry(
                        name: url.lastPathComponent,
                        url: url,
                        isDirectory: true,
                        children: loadChildren(of: url, depth: depth + 1)
                    )
                )
            } else if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                files.append(
                    FileTreeModel.Entry(name: url.lastPathComponent, url: url, isDirectory: false)
                )
            }
        }
        let byName = { (lhs: FileTreeModel.Entry, rhs: FileTreeModel.Entry) in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        folders.sort(by: byName)
        files.sort(by: byName)
        return folders + files
    }

    private func reload() {
        guard let root else {
            model.replace(entries: [], rootPath: nil, rootName: "", error: nil)
            return
        }
        // Coordinated read so an external write (a git checkout, a sync client)
        // cannot hand us a half-written tree.
        var entries: [FileTreeModel.Entry] = []
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(
            readingItemAt: root, options: [.withoutChanges], error: &coordinationError
        ) { url in
            entries = self.loadChildren(of: url, depth: 0)
        }
        model.replace(
            entries: entries,
            rootPath: root.path,
            rootName: root.lastPathComponent,
            error: coordinationError?.localizedDescription
        )
        model.revealCurrent()
    }
}

@MainActor
@Observable
final class FileTreeModel {
    /// One node of the tree.
    struct Entry: Equatable {
        var name: String
        var url: URL
        var isDirectory: Bool
        var children: [Entry] = []
    }

    /// One visible line: the tree flattened in display order, directories
    /// expanded per `expanded`.
    struct Row: Identifiable {
        var id: String { url.path }
        var name: String
        var url: URL
        var isDirectory: Bool
        var isExpanded: Bool
        var depth: Int
        /// Ancestor indent levels whose guide rail continues below this row -
        /// the vertical lines VSCode draws through an open branch.
        var guides: [Int] = []
    }

    private(set) var entries: [Entry] = []
    private(set) var rows: [Row] = []
    private(set) var rootPath: String?
    private(set) var rootName = ""
    /// The root as a URL, for "new file here" affordances in the panel menu.
    var rootURL: URL? { rootPath.map { URL(fileURLWithPath: $0) } }
    private(set) var errorText: String?
    var expanded: Set<String> = []
    var currentPath: String?
    /// The row under the pointer, for the hover highlight. One value rather
    /// than a set: only one row can be under the pointer at a time, and a set
    /// would go stale whenever the pointer leaves without a row clearing it.
    var hoveredPath: String?

    // MARK: File search (Typora's file-tree filter)

    /// The active query - trimmed, or `nil` while no search runs. The row
    /// filter and the label highlight both read this and both go through
    /// `matchRanges`, so what the tree filters by and what it highlights can
    /// never drift apart.
    private(set) var searchQuery: String?
    /// Expansion state captured when a search starts; put back when it ends,
    /// so poking around a filtered tree costs nothing after Esc.
    private var preSearchExpanded: Set<String>?
    /// Folders collapsed by hand during the current search. Results start
    /// fully expanded (matches would otherwise hide inside collapsed
    /// branches); this keeps manual collapses from being overwritten on every
    /// keystroke, and out of the expansion state restored when the search ends.
    private var searchCollapsed: Set<String> = []
    /// The row the arrow keys point at while the search field has focus; it
    /// gets the hover treatment and Return opens it.
    private(set) var activePath: String?
    /// Match-highlight colour, Typora's warm yellow. The original keeps this
    /// highlight theme-independent, so it is not a theme token either; dark
    /// appearances get a darkened gold so theme text stays readable on it.
    var searchHighlight: Color = Color(
        nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.55, green: 0.43, blue: 0.12, alpha: 1)
            }
            return NSColor(srgbRed: 1.0, green: 0.88, blue: 0.48, alpha: 1)
        })
    /// The selected row's leading bar (`--active-file-border-color`); `nil`
    /// draws no bar, which is every theme but Night.
    var accent: Color?
    var foreground: Color = .primary
    var secondary: Color = .secondary
    var background: Color = Color(
        nsColor: NSColor(
            name: nil,
            dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? ThemePalette.neutralDark.secondaryBackground
                    : ThemePalette.systemLight.secondaryBackground
            }))
    var sidebarBackground: Color = Color(
        nsColor: NSColor(
            name: nil,
            dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? ThemePalette.neutralDark.sidebarBackground
                    : ThemePalette.systemLight.sidebarBackground
            }))
    var selectionBackground: Color = Color(
        nsColor: NSColor(
            name: nil,
            dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? ThemePalette.neutralDark.secondaryBackground
                    : ThemePalette.systemLight.secondaryBackground
            }))
    /// Selected / hovered row text (`--active-file-text-color`,
    /// `--item-hover-text-color`); defaults to the normal row colour.
    var selectionText: Color = .primary
    var hoverText: Color = .primary
    /// Row font size; themes may scale it (pixyll's sidebar is `1rem`).
    var fontSize: CGFloat = 14
    /// Neutral hover wash: adaptive, using palette base.
    var hover: Color = Color(
        nsColor: NSColor(
            name: nil,
            dynamicProvider: { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor.labelColor.withAlphaComponent(isDark ? 0.08 : 0.06)
            }))
    /// Faint rail between nesting levels, using palette base.
    var guide: Color = Color(
        nsColor: NSColor(
            name: nil,
            dynamicProvider: { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor.secondaryLabelColor.withAlphaComponent(isDark ? 0.15 : 0.12)
            }))

    /// Theme tokens for the tree. `DynamicColor` is already appearance-dynamic,
    /// so a system-appearance switch still needs no re-render; only the
    /// alpha-washed hover and guide need an explicit light/dark branch.
    ///
    /// This used to resolve everything from the fixed system palette, which left
    /// the Files panel unthemed no matter which theme was active.
    func apply(theme: EditorTheme) {
        // Themes may override the sidebar's own colours (Typora's Night does);
        // falling back keeps every other theme on the editor tokens. The accent
        // is the one exception: Typora draws the selected row's leading bar
        // only when the theme declares `--active-file-border-color`, so `nil`
        // stays `nil` rather than borrowing the link colour.
        accent = theme.sidebarAccent.map { Color(nsColor: $0.nsColor) }
        foreground = Color(nsColor: (theme.sidebarForeground ?? theme.text).nsColor)
        secondary = Color(nsColor: (theme.sidebarSecondary ?? theme.syntax.comment).nsColor)
        background = Color(nsColor: theme.sidebarBackground.nsColor)
        sidebarBackground = Color(nsColor: theme.sidebarBackground.nsColor)
        selectionBackground = Color(nsColor: (theme.sidebarSelection ?? theme.selection).nsColor)
        selectionText = Color(
            nsColor: (theme.sidebarSelectionText ?? theme.sidebarForeground ?? theme.text).nsColor
        )
        hoverText = Color(
            nsColor: (theme.sidebarHoverText ?? theme.sidebarForeground ?? theme.text).nsColor)
        fontSize = theme.sidebarFontSize ?? 14
        hover = {
            if let hover = theme.sidebarHover {
                return Color(nsColor: hover.nsColor)
            }
            return Color(
                nsColor: NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    let text = isDark ? theme.text.dark : theme.text.light
                    return text.withAlphaComponent(isDark ? 0.08 : 0.06)
                })
        }()
        guide = Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let comment = isDark ? theme.syntax.comment.dark : theme.syntax.comment.light
                return comment.withAlphaComponent(isDark ? 0.15 : 0.12)
            })
    }

    func replace(entries: [Entry], rootPath: String?, rootName: String, error: String?) {
        self.rootPath = rootPath
        if self.entries != entries { self.entries = entries }
        if self.rootName != rootName { self.rootName = rootName }
        if self.errorText != error { self.errorText = error }
        // Expansion state survives a refresh, but paths that no longer exist
        // would linger forever, so prune against the directories we just read.
        var live: Set<String> = []
        func collect(_ list: [Entry]) {
            for entry in list where entry.isDirectory {
                live.insert(entry.url.path)
                collect(entry.children)
            }
        }
        collect(entries)
        expanded.formIntersection(live)
        // Same pruning for the search-mode bookkeeping: folders that vanished
        // from disk should not linger in the collapse set or come back out of
        // the pre-search snapshot when the search ends.
        searchCollapsed.formIntersection(live)
        preSearchExpanded?.formIntersection(live)
        rebuildRows()
    }

    /// Flips a folder's expansion. During a search the visible state lives in
    /// `searchCollapsed` (everything starts open), so the flip reads there -
    /// reading `expanded` instead would decide from the frozen pre-search
    /// snapshot and silently no-op on folders collapsed before the search.
    func toggle(_ path: String) {
        if searchQuery != nil {
            setExpanded(path, expanded: searchCollapsed.contains(path))
        } else {
            setExpanded(path, expanded: !expanded.contains(path))
        }
    }

    func setExpanded(_ path: String, expanded: Bool) {
        if searchQuery != nil {
            // During a search, visible expansion is owned by `searchCollapsed`
            // (everything starts open), so a toggle must not write into the
            // pre-search state that gets restored when the search ends.
            if expanded {
                searchCollapsed.remove(path)
            } else {
                searchCollapsed.insert(path)
            }
        } else {
            if expanded {
                self.expanded.insert(path)
            } else {
                self.expanded.remove(path)
            }
        }
        rebuildRows()
    }

    /// Expands every known folder, so the whole tree shows.
    func expandAll() {
        if searchQuery != nil {
            searchCollapsed.removeAll()
        } else {
            expanded.formUnion(allFolderPaths())
        }
        rebuildRows()
    }

    /// Collapses every folder back to the root's top level.
    func collapseAll() {
        if searchQuery != nil {
            searchCollapsed = allFolderPaths()
        } else {
            expanded.removeAll()
        }
        rebuildRows()
    }

    /// Every directory path currently in the tree.
    private func allFolderPaths() -> Set<String> {
        var all: Set<String> = []
        func collect(_ list: [Entry]) {
            for entry in list where entry.isDirectory {
                all.insert(entry.url.path)
                collect(entry.children)
            }
        }
        collect(entries)
        return all
    }

    /// Moves the hover highlight; `nil` clears it when the pointer leaves a row.
    func setHovered(_ path: String?) {
        guard hoveredPath != path else { return }
        hoveredPath = path
    }

    // MARK: Search

    /// Typora's matching semantics for the file-tree search, shared by the row
    /// filter and the label highlight: case-, diacritic- and width-insensitive
    /// (so `Ａ` finds `a` and full-width input matches half-width names), per
    /// the user's locale. Returns every non-overlapping occurrence.
    static func matchRanges(in name: String, query: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = [
            .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
        ]
        var ranges: [Range<String.Index>] = []
        var start = name.startIndex
        // A non-empty query always advances `upperBound`, so this terminates.
        while start < name.endIndex,
            let range = name.range(
                of: query, options: options, range: start..<name.endIndex, locale: .current)
        {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }

    private func matches(_ name: String, query: String) -> Bool {
        !Self.matchRanges(in: name, query: query).isEmpty
    }

    /// Enters or updates the search. A blank query ends it and restores the
    /// pre-search expansion state; a changed query re-filters and resets the
    /// keyboard selection to the first result.
    func setQuery(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            guard searchQuery != nil else { return }
            searchQuery = nil
            searchCollapsed.removeAll()
            activePath = nil
            if let snapshot = preSearchExpanded {
                expanded = snapshot
                preSearchExpanded = nil
            }
            // A file opened from the results may live in a branch that was
            // collapsed before the search; keep it visible after the restore.
            revealCurrent()
        } else {
            guard query != searchQuery else { return }
            if searchQuery == nil {
                preSearchExpanded = expanded
            }
            activePath = nil
            searchQuery = query
        }
        rebuildRows()
        // Start keyboard navigation on the first result, so Return does
        // something without an arrow key first (as Quick Open does).
        if activePath == nil, searchQuery != nil, let first = rows.first {
            activePath = first.url.path
        }
    }

    /// Steps the keyboard selection through the visible rows, clamped to the
    /// ends. Starts from the first row when nothing is active yet.
    func moveActive(by delta: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.url.path == activePath }
        let next = max(0, min((index ?? -1) + delta, rows.count - 1))
        activePath = rows[next].url.path
    }

    /// Re-anchors the keyboard selection on a row the pointer clicked, so the
    /// next arrow key resumes from where the mouse left off. Search-mode only:
    /// outside a search `activePath` stays `nil`, so no row keeps a highlight.
    func activate(_ path: String) {
        guard searchQuery != nil else { return }
        activePath = path
    }

    /// The active row, if it survived the latest rebuild.
    var activeRow: Row? {
        guard let activePath else { return nil }
        return rows.first { $0.url.path == activePath }
    }

    /// Expands every ancestor of the current file inside the root, so opening a
    /// document from the Finder shows it selected rather than buried.
    func revealCurrent() {
        guard let currentPath, let rootPath,
            currentPath.hasPrefix(rootPath + "/"), currentPath != rootPath
        else { return }
        var folder = (currentPath as NSString).deletingLastPathComponent
        while folder.hasPrefix(rootPath + "/") {
            expanded.insert(folder)
            folder = (folder as NSString).deletingLastPathComponent
        }
        rebuildRows()
    }

    private func rebuildRows() {
        var result: [Row] = []
        if let query = searchQuery {
            // Typora's file-tree filter. A file shows when its name contains
            // the query; a folder shows when its own name matches - in which
            // case everything below it shows, per Typora - or when something
            // below matches and it stays visible as structure. Everything
            // starts expanded so results are never buried; the user can
            // collapse branches by hand (tracked in `searchCollapsed`).
            func isVisible(_ entry: Entry) -> Bool {
                matches(entry.name, query: query)
                    || (entry.isDirectory && entry.children.contains(where: isVisible))
            }
            func emit(_ entry: Entry, depth: Int, subtreeMatched: Bool) {
                let selfMatched = matches(entry.name, query: query)
                guard subtreeMatched || selfMatched || isVisible(entry) else { return }
                let isExpanded = !searchCollapsed.contains(entry.url.path)
                result.append(
                    Row(
                        name: entry.name,
                        url: entry.url,
                        isDirectory: entry.isDirectory,
                        isExpanded: isExpanded,
                        depth: depth,
                        guides: Array(0..<depth)
                    )
                )
                guard entry.isDirectory, isExpanded else { return }
                if subtreeMatched || selfMatched {
                    for child in entry.children {
                        emit(child, depth: depth + 1, subtreeMatched: true)
                    }
                } else {
                    for child in entry.children where isVisible(child) {
                        emit(child, depth: depth + 1, subtreeMatched: false)
                    }
                }
            }
            for entry in entries {
                emit(entry, depth: 0, subtreeMatched: false)
            }
            // A refresh mid-search can remove the keyboard-selected row; fall
            // back to the first result so Return keeps doing something.
            if let active = activePath, !result.contains(where: { $0.url.path == active }) {
                activePath = result.first?.url.path
            }
        } else {
            func walk(_ list: [Entry], depth: Int) {
                for entry in list {
                    let isExpanded = expanded.contains(entry.url.path)
                    result.append(
                        Row(
                            name: entry.name,
                            url: entry.url,
                            isDirectory: entry.isDirectory,
                            isExpanded: isExpanded,
                            depth: depth,
                            // Every ancestor level: a rail spans the whole subtree
                            // under its folder, so each row inside draws it and the
                            // line naturally ends at the branch's last row.
                            guides: Array(0..<depth)
                        )
                    )
                    if entry.isDirectory, isExpanded {
                        walk(entry.children, depth: depth + 1)
                    }
                }
            }
            walk(entries, depth: 0)
        }
        rows = result
    }
}

private struct FileTree: View {
    let model: FileTreeModel
    let onSelect: (URL) -> Void
    let onCreateFile: (() -> Void)?
    let onAction: (FileTreeAction) -> Void

    /// The raw text in the search field; the model keeps the trimmed query.
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    /// Routes ↑/↓ from the field editor to search-result navigation while the
    /// field has focus.
    @State private var arrowRouter = ArrowKeyRouter()

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(model.secondary)
                    .padding(12)
                Spacer(minLength: 0)
            } else if model.entries.isEmpty {
                if !model.rootName.isEmpty { folderRow }
                if let query = model.searchQuery {
                    noMatchView(query)
                } else {
                    Text("No Markdown files here")
                        .font(.system(size: 12))
                        .foregroundStyle(model.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu { panelMenu(target: model.rootURL) }
                }
                Spacer(minLength: 0)
            } else if model.rows.isEmpty, let query = model.searchQuery {
                folderRow
                noMatchView(query)
                Spacer(minLength: 0)
            } else {
                folderRow
                ScrollView {
                    ScrollViewReader { proxy in
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.rows) { row($0) }
                        }
                        .onChange(of: model.activePath) { _, path in
                            // Keep the keyboard-navigated row on screen.
                            guard let path else { return }
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(path, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .background(model.sidebarBackground)
    }

    /// Typora-style header: the title is centred across the panel's width.
    /// The standalone "+" button is gone; "New File" stays reachable through the
    /// context menus (header, empty area, folder rows).
    private var header: some View {
        Text("Files")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(model.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
            // Typora pops the folder menu from the panel's empty spots too.
            .contextMenu { panelMenu(target: model.rootURL) }
    }

    /// Typora's file-tree search: a slim field pinned to the top of the panel.
    /// Typing filters the tree by file name; matches highlight in place.
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(model.secondary)
                .accessibilityHidden(true)
            TextField("Search Files", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .help("Filter files by name")
                .onSubmit(commitActive)
                .onExitCommand(perform: clearSearch)
            if !searchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(model.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(model.hover))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(
                    searchFocused ? (model.accent ?? model.secondary) : model.guide,
                    lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onChange(of: searchText) { _, newValue in
            model.setQuery(newValue)
        }
        .onChange(of: searchFocused) { _, focused in
            // Arrow-key navigation only matters while typing in the field;
            // every other responder keeps its own arrow handling.
            if focused {
                arrowRouter.start { [weak model] event in
                    model?.moveActive(by: event.specialKey == .upArrow ? -1 : 1)
                }
            } else {
                arrowRouter.stop()
            }
        }
        .onDisappear {
            arrowRouter.stop()
        }
    }

    /// Empty result state: quiet, and the panel menu still works here like on
    /// the rest of the panel's dead space.
    private func noMatchView(_ query: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .light))
                .accessibilityHidden(true)
            Text("No files match \u{201C}\(query)\u{201D}")
                .font(.system(size: 12))
        }
        .foregroundStyle(model.secondary)
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
        .contextMenu { panelMenu(target: model.rootURL) }
    }

    /// Esc or the clear button: drop the query. The model restores the
    /// pre-search expansion state; focus stays in the field for a retyped one.
    private func clearSearch() {
        searchText = ""
    }

    /// Return in the search field: open the active file, or toggle the
    /// active folder.
    private func commitActive() {
        guard let row = model.activeRow else { return }
        if row.isDirectory {
            model.toggle(row.url.path)
        } else {
            onSelect(row.url)
        }
    }

    private var folderRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
            Text(model.rootName)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .font(.system(size: model.fontSize))
        .foregroundStyle(model.foreground)
        // Lined up with the depth-0 chevron below, so the root folder sits in
        // the same column as the branches it contains.
        .padding(.leading, indentOffset(0))
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        // The root row acts as the folder itself.
        .contextMenu { panelMenu(target: model.rootURL) }
    }

    // MARK: Context menus (Typora's file-tree actions)

    /// Panel-level menu: create into the tree's folder, expand/collapse, refresh.
    @ViewBuilder
    private func panelMenu(target: URL?) -> some View {
        Button("New File") {
            if let target { onAction(.newFile(target)) } else { onCreateFile?() }
        }
        Button("New Folder") {
            guard let target else { return }
            onAction(.newFolder(target))
        }
        Divider()
        Button("Expand All") { onAction(.expandAll) }
        Button("Collapse All") { onAction(.collapseAll) }
        Divider()
        Button("Refresh") { onAction(.refresh) }
        if let target {
            Divider()
            Button("Copy File Path") { onAction(.copyPath(target)) }
            Button("Reveal in Finder") { onAction(.reveal(target)) }
        }
    }

    /// Menu for a `.md` row. Names follow Typora's `Menu.strings`.
    @ViewBuilder
    private func fileMenu(_ item: FileTreeModel.Row) -> some View {
        Button("Open in New Window") { onAction(.openInNewWindow(item.url)) }
        Divider()
        Button("New File") { onAction(.newFile(item.url.deletingLastPathComponent())) }
        Divider()
        Button("Duplicate") { onAction(.duplicate(item.url)) }
        Button("Rename…") { onAction(.rename(item.url, item.name)) }
        Button("Move to Trash") { onAction(.trash(item.url)) }
        Divider()
        Button("Copy File Path") { onAction(.copyPath(item.url)) }
        Button("Reveal in Finder") { onAction(.reveal(item.url)) }
    }

    /// Menu for a folder row: the file menu plus "New Folder" inside it.
    @ViewBuilder
    private func folderMenu(_ item: FileTreeModel.Row) -> some View {
        Button("New File") { onAction(.newFile(item.url)) }
        Button("New Folder") { onAction(.newFolder(item.url)) }
        Divider()
        Button("Expand All") { onAction(.expandAll) }
        Button("Collapse All") { onAction(.collapseAll) }
        Divider()
        Button("Duplicate") { onAction(.duplicate(item.url)) }
        Button("Rename…") { onAction(.rename(item.url, item.name)) }
        Button("Move to Trash") { onAction(.trash(item.url)) }
        Divider()
        Button("Copy File Path") { onAction(.copyPath(item.url)) }
        Button("Reveal in Finder") { onAction(.reveal(item.url)) }
    }

    private func row(_ item: FileTreeModel.Row) -> some View {
        let isCurrent = !item.isDirectory && model.currentPath == item.url.path
        return Button {
            // Re-anchor the keyboard navigation on the row the pointer chose,
            // so ↓/↑ resume from it instead of the last arrow-tracked row.
            model.activate(item.url.path)
            if item.isDirectory {
                model.toggle(item.url.path)
            } else {
                onSelect(item.url)
            }
        } label: {
            ZStack(alignment: .topLeading) {
                ForEach(item.guides, id: \.self) { level in
                    Rectangle()
                        .fill(model.guide)
                        .frame(width: 1)
                        .offset(x: guideOffset(level))
                }
                HStack(spacing: 4) {
                    Group {
                        if item.isDirectory {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(model.secondary)
                                .rotationEffect(.degrees(item.isExpanded ? 90 : 0))
                                .animation(.easeInOut(duration: 0.12), value: item.isExpanded)
                                .frame(width: chevronSlot)
                        } else {
                            Color.clear.frame(width: chevronSlot, height: 1)
                        }
                    }
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.text.fill")
                        .font(.system(size: 12))
                    highlightedName(item)
                        .font(.system(size: model.fontSize))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, indentOffset(item.depth))
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(rowForeground(isCurrent: isCurrent, path: item.url.path))
                .background(
                    rowBackground(isCurrent: isCurrent, path: item.url.path)
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { inside in
                model.setHovered(inside ? item.url.path : nil)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item.isDirectory {
                folderMenu(item)
            } else {
                fileMenu(item)
            }
        }
    }

    /// The label with query matches highlighted: each matched run sits on a
    /// yellow block (Typora's file-search highlight), the rest stays plain.
    /// Runs are assembled through `AttributedString` - `Text` has no per-run
    /// background - and the result still truncates like a single line.
    private func highlightedName(_ item: FileTreeModel.Row) -> Text {
        guard let query = model.searchQuery else { return Text(item.name) }
        let ranges = FileTreeModel.matchRanges(in: item.name, query: query)
        guard !ranges.isEmpty else { return Text(item.name) }
        var attributed = AttributedString()
        var cursor = item.name.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                attributed += AttributedString(item.name[cursor..<range.lowerBound])
            }
            var match = AttributedString(item.name[range])
            match.backgroundColor = model.searchHighlight
            attributed += match
            cursor = range.upperBound
        }
        if cursor < item.name.endIndex {
            attributed += AttributedString(item.name[cursor...])
        }
        return Text(attributed)
    }

    private func rowForeground(isCurrent: Bool, path: String) -> Color {
        if isCurrent { return model.selectionText }
        if model.hoveredPath == path || model.activePath == path { return model.hoverText }
        return model.foreground
    }

    @ViewBuilder
    private func rowBackground(isCurrent: Bool, path: String) -> some View {
        ZStack(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(model.selectionBackground)
                // Typora's `--active-file-border-color`: a short bar flush with
                // the sidebar's left edge (Night's is `#8d8df0`).
                if let accent = model.accent {
                    Rectangle().fill(accent).frame(width: 3)
                }
            } else if model.hoveredPath == path || model.activePath == path {
                Rectangle().fill(model.hover)
            }
        }
    }

    private func indentOffset(_ depth: Int) -> CGFloat {
        8 + CGFloat(depth) * indentStep
    }

    /// VS Code hangs each level's guide just left of that level's twistie
    /// column, so a subtree's rows read as hanging off their parent's chevron.
    private func guideOffset(_ level: Int) -> CGFloat {
        indentOffset(level) + 8
    }

    // VS Code's tree rhythm: a 16px twistie column and a 16px indent step per
    // level, chevron first, then the icon, then the label.
    private let indentStep: CGFloat = 16
    private let chevronSlot: CGFloat = 16
}

/// Routes up/down arrow key-downs to a handler while the search field has
/// keyboard focus.
///
/// A single-line `TextField`'s field editor deals with arrow keys inside the
/// responder chain, so SwiftUI's `onKeyPress` is not a dependable delivery
/// path for them; a local `NSEvent` monitor is - the same pattern
/// `EditorWindowController` and `EditorTabStripView` use. The monitor consumes
/// only the two arrows and passes every other event through untouched, and it
/// is removed the moment focus (or the panel) goes away, so it can never eat
/// arrows aimed at the editor.
@MainActor
private final class ArrowKeyRouter {
    private var monitor: Any?
    private var onArrow: ((NSEvent) -> Void)?

    /// Starts consuming arrow key-downs, handing them to `onArrow`.
    func start(_ onArrow: @escaping (NSEvent) -> Void) {
        stop()
        self.onArrow = onArrow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            // Bare arrows only: ⇧↑/⇧↓ (field selection), ⌘↑/⌘↓ and friends
            // must keep reaching the field editor. Keypad arrows carry
            // .numericPad and still count as bare.
            guard let self,
                event.modifierFlags.subtracting(.numericPad).isEmpty,
                let specialKey = event.specialKey,
                specialKey == .upArrow || specialKey == .downArrow
            else { return event }
            self.onArrow?(event)
            return nil
        }
    }

    /// Stops consuming; the router is inert until started again.
    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        onArrow = nil
    }
}
