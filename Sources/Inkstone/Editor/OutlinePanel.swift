import AppKit
import Foundation
import SwiftUI

/// The outline panel docked to the window's right edge.
///
/// SwiftUI, because the indentation tree is genuinely declarative; hosted in an
/// `NSHostingView` because the surrounding panels are AppKit. The rebuild lives
/// in the model rather than the view body so that typing does not re-evaluate
/// the whole list on every keystroke.
final class OutlineViewController: NSViewController {
    var onSelect: ((MarkdownDocument.Heading) -> Void)?

    private let model = OutlineModel()
    private var hosting: NSHostingView<Outline>?

    override func loadView() {
        let hosted = NSHostingView(
            rootView: Outline(
                model: model,
                onSelect: { [weak self] heading in
                    self?.onSelect?(heading)
                },
                onToggleCollapse: { [weak self] blockID in
                    self?.model.toggleCollapsed(blockID)
                }
            )
        )
        hosting = hosted
        view = hosted
    }

    func apply(theme: EditorTheme) {
        model.apply(theme: theme)
    }

    func update(
        headings: [MarkdownDocument.Heading],
        counts: Counter.Count,
        selectionWords: Int?,
        scrollTo current: MarkdownDocument.Heading?
    ) {
        model.update(headings: headings, counts: counts, selectionWords: selectionWords, current: current)
    }
}

@MainActor
@Observable
final class OutlineModel {
    /// Typora's two outline views: a flat list, or one whose sections collapse.
    enum Mode {
        case flat
        case collapsible
    }

    struct Entry: Identifiable, Equatable {
        var id: Int { blockID }
        var level: Int
        var text: String
        var blockID: Int
        var depth: Int
        /// Whether a shallower heading follows, so a chevron applies.
        var hasChildren = false
    }

    private(set) var entries: [Entry] = []
    private(set) var words = 0
    private(set) var characters = 0
    private(set) var charactersNoSpaces = 0
    private(set) var lines = 0
    private(set) var readingMinutes = 0
    private(set) var selectionWords: Int?
    private(set) var activeID: Int?
    /// Collapsed section heads, keyed by block. Only meaningful in
    /// `.collapsible` mode.
    private var collapsedIDs: Set<Int> = []
    /// Bumped by "Highlight Current Header"; the view watches it to scroll the
    /// active row into view.
    private(set) var revealToken = 0
    /// The outline style persists across launches, like Typora's preference.
    var mode: Mode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode == .collapsible, forKey: Self.modeKey)
        }
    }
    private static let modeKey = "outlineCollapsible"

    var accent: Color = .accentColor
    var foreground: Color = .primary
    var secondary: Color = .secondary
    var background: Color = Color(nsColor: .textBackgroundColor)

    init() {
        mode = UserDefaults.standard.bool(forKey: Self.modeKey) ? .collapsible : .flat
    }

    func apply(theme: EditorTheme) {
        accent = Color(nsColor: theme.link.nsColor)
        foreground = Color(nsColor: theme.text.nsColor)
        secondary = Color(nsColor: theme.syntax.comment.nsColor)
        background = Color(nsColor: theme.background.nsColor)
    }

    /// The original nests by heading level rather than by source order: a level-3 under a
    /// level-1 is a child of that level-1 even if a level-2 sits between them.
    func update(
        headings: [MarkdownDocument.Heading],
        counts: Counter.Count,
        selectionWords: Int?,
        current: MarkdownDocument.Heading?
    ) {
        words = counts.words
        characters = counts.characters
        charactersNoSpaces = counts.charactersNoSpaces
        lines = counts.lines
        readingMinutes = counts.readingMinutes
        self.selectionWords = selectionWords
        var openLevels: [Int] = []
        var result: [Entry] = []
        for heading in headings {
            while let last = openLevels.last, last >= heading.level {
                openLevels.removeLast()
            }
            openLevels.append(heading.level)
            result.append(
                Entry(
                    level: heading.level,
                    text: heading.text.isEmpty ? "(untitled)" : heading.text,
                    blockID: heading.blockID,
                    depth: max(openLevels.count - 1, 0)
                )
            )
        }
        // A heading has children exactly when the next one nests deeper; the
        // collapsed set can only ever hold these, so stale keys prune for free.
        for index in result.indices {
            let next = result.index(after: index)
            if next < result.endIndex, result[next].depth > result[index].depth {
                result[index].hasChildren = true
            }
        }
        if entries != result { entries = result }
        let next = current?.blockID
        if activeID != next { activeID = next }
    }

    /// The rows on screen: everything in flat mode, or the sections outside a
    /// collapsed subtree in collapsible mode.
    var visibleEntries: [Entry] {
        guard mode == .collapsible else { return entries }
        var collapsedDepths: [Int] = []
        var result: [Entry] = []
        for entry in entries {
            while let deepest = collapsedDepths.last, deepest >= entry.depth {
                collapsedDepths.removeLast()
            }
            guard collapsedDepths.isEmpty else { continue }
            result.append(entry)
            if entry.hasChildren, collapsedIDs.contains(entry.blockID) {
                collapsedDepths.append(entry.depth)
            }
        }
        return result
    }

    func toggleCollapsed(_ blockID: Int) {
        if collapsedIDs.contains(blockID) {
            collapsedIDs.remove(blockID)
        } else {
            collapsedIDs.insert(blockID)
        }
    }

    /// Whether a section head is currently collapsed; the row reads this for
    /// its chevron direction.
    func isCollapsed(_ blockID: Int) -> Bool {
        collapsedIDs.contains(blockID)
    }

    func expandAll() {
        collapsedIDs.removeAll()
    }

    func collapseAll() {
        collapsedIDs.formUnion(entries.filter(\.hasChildren).map(\.blockID))
    }

    /// Asks the view to scroll the active heading into view.
    func revealCurrent() {
        revealToken += 1
    }
}

private struct Outline: View {
    let model: OutlineModel
    let onSelect: (MarkdownDocument.Heading) -> Void
    let onToggleCollapse: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.entries.isEmpty {
                Text("No headings")
                    .font(.system(size: 13))
                    .foregroundStyle(model.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .contextMenu { outlinePanelMenu(model) }
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // `LazyVStack` keeps a 5,000-heading document cheap, which
                        // matters because the outline is rebuilt on every keystroke.
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.visibleEntries) { entry in
                                OutlineRow(
                                    model: model,
                                    entry: entry,
                                    isActive: model.activeID == entry.blockID,
                                    isCollapsible: model.mode == .collapsible,
                                    foreground: model.foreground,
                                    onSelect: onSelect,
                                    onToggleCollapse: onToggleCollapse
                                )
                                .id(entry.blockID)
                            }
                        }
                    }
                    .onChange(of: model.revealToken) { _, _ in
                        guard let active = model.activeID else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(active, anchor: .center)
                        }
                    }
                }
            }
            footer
        }
        .background(model.background)
    }

    /// Word count pinned to the bottom: a SwiftUI root view without an
    /// expanding child (the `Spacer` above when empty, the `ScrollView` when
    /// not) gets centred in its hosting view, which left the whole panel
    /// floating in a void of background.
    ///
    /// Clicking it pops the full counts; the footer itself stays one line.
    @State private var showCounts = false

    private var footer: some View {
        HStack(spacing: 4) {
            Text("\(model.words) words")
            Text("·")
            Text("\(model.characters) characters")
        }
        .font(.system(size: 11))
        .foregroundStyle(model.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { showCounts = true }
        .popover(isPresented: $showCounts) {
            WordCountDetails(model: model)
        }
        .contextMenu { outlinePanelMenu(model) }
    }

    /// Matches the reference design: airy rows, indented per nesting depth, the
    /// active heading marked by weight rather than a background fill, and extra
    /// head-room before every level-1 section.
    private struct OutlineRow: View {
        let model: OutlineModel
        let entry: OutlineModel.Entry
        let isActive: Bool
        let isCollapsible: Bool
        let foreground: Color
        let onSelect: (MarkdownDocument.Heading) -> Void
        let onToggleCollapse: (Int) -> Void

        @State private var isHovered = false

        /// A row is a plain view with tap gestures rather than a `Button`:
        /// the chevron needs its own tap target, and a gesture nested in a
        /// button's label fires both.
        var body: some View {
            HStack(spacing: 4) {
                chevron
                Text(entry.text)
                    .font(
                        .system(
                            size: entry.level == 1 ? 15 : 14,
                            weight: isActive ? .semibold : .regular
                        )
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, 20 + CGFloat(entry.depth) * 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .padding(.top, entry.level == 1 ? 8 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hoverTint)
            .contentShape(Rectangle())
            .foregroundStyle(foreground)
            .onTapGesture {
                onSelect(
                    MarkdownDocument.Heading(
                        level: entry.level, text: entry.text, blockID: entry.blockID
                    )
                )
            }
            .contextMenu { outlinePanelMenu(model) }
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(entry.text)
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .accessibilityAction {
                onSelect(
                    MarkdownDocument.Heading(
                        level: entry.level, text: entry.text, blockID: entry.blockID
                    )
                )
            }
        }

        /// Collapsible mode reserves the chevron column on every row, so files
        /// and childless heads line up with expandable ones; flat mode keeps
        /// the original text-only layout.
        @ViewBuilder
        private var chevron: some View {
            if isCollapsible {
                Group {
                    if entry.hasChildren {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(model.isCollapsed(entry.blockID) ? 0 : 90))
                            .contentShape(Rectangle())
                            .onTapGesture { onToggleCollapse(entry.blockID) }
                            .accessibilityHidden(true)
                    } else {
                        Color.clear.frame(width: 10, height: 1)
                    }
                }
                .frame(width: 10)
            }
        }

        /// The active row is already marked by weight; the hover tint tracks the
        /// theme's text colour at low opacity so it works on light and dark
        /// backgrounds alike.
        private var hoverTint: Color {
            guard !isActive else { return .clear }
            return isHovered ? foreground.opacity(0.06) : .clear
        }
    }
}

/// The full counts behind the outline footer's one line.
private struct WordCountDetails: View {
    let model: OutlineModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            row("Words", "\(model.words)")
            row("Characters", "\(model.characters)")
            row("Without spaces", "\(model.charactersNoSpaces)")
            row("Lines", "\(model.lines)")
            row("Reading time", readingTime)
            if let selected = model.selectionWords {
                Divider()
                row("Selected", "\(selected) words")
            }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(minWidth: 200)
    }

    private var readingTime: String {
        guard model.words > 0 else { return "–" }
        return model.readingMinutes > 0 ? "~\(model.readingMinutes) min" : "Less than a minute"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(model.secondary)
            Text(value).gridColumnAlignment(.trailing)
        }
    }
}
/// Typora's outline context menu, shared by the rows, the footer and the
/// empty state so it works anywhere in the panel.
@MainActor
@ViewBuilder
private func outlinePanelMenu(_ model: OutlineModel) -> some View {
    Button("Highlight Current Header") { model.revealCurrent() }
        .disabled(model.activeID == nil)
    Divider()
    Button("Expand All") { model.expandAll() }
    Button("Collapse All") { model.collapseAll() }
        .disabled(model.mode != .collapsible)
    Divider()
    Button {
        model.mode = .flat
    } label: {
        if model.mode == .flat {
            Label("Flat Outline", systemImage: "checkmark")
        } else {
            Text("Flat Outline")
        }
    }
    Button {
        model.mode = .collapsible
    } label: {
        if model.mode == .collapsible {
            Label("Collapsible Outline", systemImage: "checkmark")
        } else {
            Text("Collapsible Outline")
        }
    }
}
