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
        counts: (words: Int, characters: Int),
        scrollTo current: MarkdownDocument.Heading?
    ) {
        model.update(headings: headings, counts: counts, current: current)
    }
}

@MainActor
@Observable
final class OutlineModel {
    struct Entry: Identifiable, Equatable {
        var id: Int { blockID }
        var level: Int
        var text: String
        var blockID: Int
        var depth: Int
    }

    private(set) var entries: [Entry] = []
    private(set) var words = 0
    private(set) var characters = 0
    private(set) var activeID: Int?
    var accent: Color = .accentColor
    var foreground: Color = .primary
    var secondary: Color = .secondary
    var background: Color = Color(nsColor: .textBackgroundColor)

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
        counts: (words: Int, characters: Int),
        current: MarkdownDocument.Heading?
    ) {
        words = counts.words
        characters = counts.characters
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
        if entries != result { entries = result }
        let next = current?.blockID
        if activeID != next { activeID = next }
    }
}

private struct Outline: View {
    let model: OutlineModel
    let onSelect: (MarkdownDocument.Heading) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.entries.isEmpty {
                Text("No headings")
                    .font(.system(size: 13))
                    .foregroundStyle(model.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    // `LazyVStack` keeps a 5,000-heading document cheap, which
                    // matters because the outline is rebuilt on every keystroke.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.entries) { entry in
                            OutlineRow(
                                entry: entry,
                                isActive: model.activeID == entry.blockID,
                                foreground: model.foreground,
                                onSelect: onSelect
                            )
                        }
                    }
                }
            }
            footer
        }
        .background(model.background)
    }

    /// Header pinned to the top, word count pinned to the bottom: a SwiftUI
    /// root view without a `Spacer` gets centred in its hosting view, which
    /// left the whole panel floating in a void of background.
    private var header: some View {
        Text("Outline")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(model.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text("\(model.words) words")
            Text("·")
            Text("\(model.characters) characters")
        }
        .font(.system(size: 11))
        .foregroundStyle(model.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Matches the reference design: airy rows, indented per nesting depth, the
    /// active heading marked by weight rather than a background fill, and extra
    /// head-room before every level-1 section.
    private struct OutlineRow: View {
        let entry: OutlineModel.Entry
        let isActive: Bool
        let foreground: Color
        let onSelect: (MarkdownDocument.Heading) -> Void

        @State private var isHovered = false

        var body: some View {
            Button {
                onSelect(
                    MarkdownDocument.Heading(
                        level: entry.level, text: entry.text, blockID: entry.blockID
                    )
                )
            } label: {
                Text(entry.text)
                    .font(
                        .system(
                            size: entry.level == 1 ? 15 : 14,
                            weight: isActive ? .semibold : .regular
                        )
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(foreground)
                    .padding(.leading, 20 + CGFloat(entry.depth) * 14)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                    .padding(.top, entry.level == 1 ? 8 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(hoverTint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
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
