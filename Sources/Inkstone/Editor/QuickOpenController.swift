import AppKit
import Foundation

/// Quick Open: Cmd-P, type a fragment of a path, Enter.
///
/// ## Why it lists paths rather than document titles
///
/// The original's quick open is a fuzzy match over the *file path* of everything under the
/// workspace root, with the last component weighted highest. Matching on titles
/// would be nicer but would mean parsing every file up front, which on a large tree
/// costs more than the keystroke budget allows. Listing is therefore lazy: the root
/// is scanned on first use and cached, then filtered in memory.
///
/// The matcher is a subsequence match with a scoring bonus for consecutive runs and
/// for matches at the start of a path component. That is enough to put
/// `doc/foo.md` above `docs/other/foo.md` for the query `foo`, which is the
/// distinction users actually notice.
@MainActor
final class QuickOpenController: NSObject {
    private static let scorer = QuickOpenScorer()

    private struct Entry: Identifiable {
        var id: Int
        var url: URL
        var display: String
    }

    private var entries: [Entry] = []
    private var roots: [URL] = []
    private var snapshotAt: Date?

    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var filtered: [Entry] = []

    /// Called with the chosen file.
    var onOpen: ((URL) -> Void)?

    /// Quick Open has one instance for the app, mirroring the original's single panel.
    static let shared = QuickOpenController()

    private override init() {
        super.init()
        panel.title = "Quick Open"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let content = NSView(frame: panel.contentLayoutRect)
        panel.contentView = content

        field.placeholderString = "Type a file name…"
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 18)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.title = "Path"
        column.width = 520
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.rowHeight = 20
        table.backgroundColor = .textBackgroundColor
        table.style = .inset
        table.target = self
        table.doubleAction = #selector(commit)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(field)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - Use

    /// Roots to search: the open documents' folders plus the remembered workspace.
    func setRoots(_ roots: [URL]) {
        let normalised =
            roots
            .map { $0.standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard normalised != self.roots else { return }
        self.roots = normalised
        snapshotAt = nil
    }

    func show() {
        rebuildIfStale()
        field.stringValue = ""
        filtered = entries
        table.reloadData()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func rebuildIfStale() {
        guard
            entries.isEmpty || snapshotAt == nil
                || Date().timeIntervalSince(snapshotAt ?? .distantPast) > 30
        else { return }
        var found: [Entry] = []
        var seen = Set<String>()
        for root in roots {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                guard seen.insert(url.path).inserted else { continue }
                let relative =
                    url.path.hasPrefix(root.path)
                    ? String(url.path.dropFirst(root.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    : url.lastPathComponent
                found.append(Entry(id: found.count, url: url, display: relative))
            }
        }
        entries = found.sorted { $0.display < $1.display }
        snapshotAt = Date()
    }

    private func applyFilter() {
        let query = field.stringValue
        if query.isEmpty {
            filtered = Array(entries.prefix(200))
        } else {
            filtered =
                entries
                .compactMap { entry -> (Entry, Int)? in
                    guard let score = Self.scorer.score(query: query, candidate: entry.display)
                    else { return nil }
                    return (entry, score)
                }
                .sorted {
                    $0.1 == $1.1 ? $0.0.display < $1.0.display : $0.1 > $1.1
                }
                .prefix(200)
                .map(\.0)
        }
        table.reloadData()
        if !filtered.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func commit() {
        let row = table.selectedRow
        guard filtered.indices.contains(row) else { return }
        let url = filtered[row].url
        hide()
        onOpen?(url)
    }
}

extension QuickOpenController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector)
        -> Bool
    {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        let next = max(0, min(table.selectedRow + delta, filtered.count - 1))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }
}

extension QuickOpenController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int)
        -> Any?
    {
        filtered.indices.contains(row) ? filtered[row].display : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if filtered.indices.contains(row) {
            field.stringValue = filtered[row].display
            field.selectText(nil)
        }
    }
}

/// Fuzzy subsequence scorer: returns `nil` when the query is not a subsequence.
///
/// Bonuses, largest first: a run of consecutive characters, the start of the path,
/// the start of a component after a `/`, and a match right before an extension.
struct QuickOpenScorer {
    func score(query: String, candidate: String) -> Int? {
        let needle = Array(query.lowercased())
        let haystack = Array(candidate.lowercased())
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }

        var total = 0
        var haystackIndex = 0
        var previousMatch: Int?
        for character in needle {
            var found: Int?
            var probe = haystackIndex
            while probe < haystack.count {
                if haystack[probe] == character {
                    found = probe
                    break
                }
                probe += 1
            }
            guard let found else { return nil }
            if found == previousMatch.map({ $0 + 1 }) { total += 8 }
            if found == 0 { total += 16 }
            if found > 0, haystack[found - 1] == "/" { total += 12 }
            if found + 1 < haystack.count, haystack[found + 1] == "." { total += 6 }
            previousMatch = found
            haystackIndex = found + 1
        }
        // Prefer the shorter path: for equal quality, `a/b.md` beats `a/b/c/d.md`.
        return total * 100 / max(haystack.count, 1)
    }
}
