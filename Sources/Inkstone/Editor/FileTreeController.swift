import AppKit
import Foundation
import SwiftUI

/// The "Files" panel docked to the window's left edge: the folder containing the
/// open document as an expandable tree, with `.md` files only.
///
/// The original shows the whole folder tree and marks the current file. Directories are
/// included so the hierarchy is visible, and reading goes through
/// `NSFileCoordinator` so edits arriving from outside the app do not race the
/// refresh. Nothing watches the file system, so callers that create or delete
/// files by hand have to ask for `refresh()`.
final class FileTreeController: NSViewController {
    var onSelect: ((URL) -> Void)?
    /// The toolbar's "+": creates a file in the tree's folder.
    var onCreateFile: (() -> Void)?

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
            onCreateFile: { [weak self] in self?.onCreateFile?() }
        )
        let hosted = NSHostingView(rootView: root)
        hosting = hosted
        view = hosted
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
    private(set) var errorText: String?
    var expanded: Set<String> = []
    var currentPath: String?
    /// The row under the pointer, for the hover highlight. One value rather
    /// than a set: only one row can be under the pointer at a time, and a set
    /// would go stale whenever the pointer leaves without a row clearing it.
    var hoveredPath: String?
    var accent: Color = .accentColor
    var foreground: Color = .primary
    var secondary: Color = .secondary
    var background: Color = Color(
        nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? ThemePalette.neutralDark.secondaryBackground
                : ThemePalette.systemLight.secondaryBackground
        }))
    var sidebarBackground: Color = Color(
        nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? ThemePalette.neutralDark.sidebarBackground
                : ThemePalette.systemLight.sidebarBackground
        }))
    var selectionBackground: Color = Color(
        nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? ThemePalette.neutralDark.secondaryBackground
                : ThemePalette.systemLight.secondaryBackground
        }))
    /// Neutral hover wash: adaptive, using palette base.
    var hover: Color = Color(
        nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor.labelColor.withAlphaComponent(isDark ? 0.08 : 0.06)
        }))
    /// Faint rail between nesting levels, using palette base.
    var guide: Color = Color(
        nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor.secondaryLabelColor.withAlphaComponent(isDark ? 0.15 : 0.12)
        }))

    func apply(theme: EditorTheme) {
        accent = Color(
            nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? ThemePalette.neutralDark.syntaxKey
                    : ThemePalette.systemLight.syntaxKey
            }))
        foreground = Color(
            nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.labelColor
                    : NSColor.labelColor
            }))
        secondary = Color(
            nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? ThemePalette.neutralDark.syntaxBool
                    : ThemePalette.systemLight.syntaxBool
            }))
        background = Color(
            nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? ThemePalette.neutralDark.sidebarBackground
                    : ThemePalette.systemLight.sidebarBackground
            }))
        sidebarBackground = Color(
            nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? ThemePalette.neutralDark.sidebarBackground
                    : ThemePalette.systemLight.sidebarBackground
            }))
        selectionBackground = Color(
            nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? ThemePalette.neutralDark.secondaryBackground.withAlphaComponent(0.25)
                    : ThemePalette.systemLight.secondaryBackground.withAlphaComponent(0.30)
            }))
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
        rebuildRows()
    }

    func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
        }
        rebuildRows()
    }

    /// Moves the hover highlight; `nil` clears it when the pointer leaves a row.
    func setHovered(_ path: String?) {
        guard hoveredPath != path else { return }
        hoveredPath = path
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
        rows = result
    }
}

private struct FileTree: View {
    let model: FileTreeModel
    let onSelect: (URL) -> Void
    let onCreateFile: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(model.secondary)
                    .padding(12)
                Spacer(minLength: 0)
            } else if model.entries.isEmpty {
                if !model.rootName.isEmpty { folderRow }
                Text("No Markdown files here")
                    .font(.system(size: 12))
                    .foregroundStyle(model.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                folderRow
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows) { row($0) }
                    }
                }
            }
        }
        .background(model.sidebarBackground)
    }

    /// The title sits centred above the tree, the way the original's sidebar
    /// header does.
    private var header: some View {
        Text("Files")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(model.secondary)
            .padding(.vertical, 6)
    }

    private var folderRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 11))
            Text(model.rootName)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(model.secondary)
        // Lined up with the depth-0 chevron below, so the root folder sits in
        // the same column as the branches it contains.
        .padding(.leading, indentOffset(0))
        .padding(.trailing, 10)
        .padding(.vertical, 7)
    }

    private func row(_ item: FileTreeModel.Row) -> some View {
        let isCurrent = !item.isDirectory && model.currentPath == item.url.path
        return Button {
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
                HStack(spacing: 6) {
                    Group {
                        if item.isDirectory {
                            Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(model.secondary)
                                .frame(width: 11)
                        } else {
                            Color.clear.frame(width: 11, height: 1)
                        }
                    }
                    Image(systemName: item.isDirectory ? "folder" : "doc.text")
                        .font(.system(size: 12))
                    Text(item.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.leading, indentOffset(item.depth))
                .padding(.trailing, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(model.foreground)
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
    }

    @ViewBuilder
    private func rowBackground(isCurrent: Bool, path: String) -> some View {
        ZStack(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(model.selectionBackground)
            } else if model.hoveredPath == path {
                Rectangle().fill(model.hover)
            }
        }
    }

    private func indentOffset(_ depth: Int) -> CGFloat {
        8 + CGFloat(depth) * indentStep
    }

    private func guideOffset(_ level: Int) -> CGFloat {
        indentOffset(level) + chevronSlot / 2
    }

    private let indentStep: CGFloat = 16
    private let chevronSlot: CGFloat = 11

    /// A "New File" button that creates a file in the current folder.
    private var toolbar: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                onCreateFile?()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New File")
            .accessibilityLabel("New File")
            .accessibilityHint("Creates a new Markdown file in the current folder")
        }
        .padding(.top, 4)
        .padding(.horizontal, 10)
    }

}
