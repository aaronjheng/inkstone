import AppKit
import Foundation

/// The find bar the original slides down from the top of the editor.
///
/// ## Why results come from the node tree
///
/// Searching the buffer would hit syntax the user cannot see - the `**` around a
/// bold run, the pipes between table cells - and the original would then have to reveal
/// the syntax of any match to keep the highlight honest. `NodeSearch` matches only
/// the visible text of each inline node, so a hit is by construction somewhere the
/// caret can legitimately land. That also means the find panel has to translate a
/// node-relative offset into a buffer offset, which is what `select(hit:)` does.
@MainActor
final class FindReplaceController: NSViewController {
    /// The original's find bar is 40pt tall with 8pt of padding around a 24pt control.
    private static let barHeight: CGFloat = 40

    private let bar = NSVisualEffectView()
    private let queryField = SearchField()
    private let replaceField = NSTextField()
    private let counter = NSTextField(labelWithString: "")
    private let caseButton = ToggleButton(title: "Aa", tooltip: "Match Case")
    private let wholeWordButton = ToggleButton(title: "[a]", tooltip: "Match Whole Word")
    private let regexButton = ToggleButton(title: ".*", tooltip: "Use Regular Expression")
    private let replaceButton = NSButton(title: "Replace All", target: nil, action: nil)
    private let closeButton = NSButton(symbol: "xmark.circle.fill", tooltip: "Close")
    private let previousButton = NSButton(symbol: "chevron.up", tooltip: "Previous Match")
    private let nextButton = NSButton(symbol: "chevron.down", tooltip: "Next Match")

    private var results = NodeSearch.Results()
    private var selectedIndex: Int?
    private weak var editor: MarkdownTextView?

    /// Reported so the caller can refresh anything derived from the text.
    var onReplace: (() -> Void)?
    /// Reported when the bar's own close button hides it, so the owner can drop
    /// its toggle state instead of going stale.
    var onClose: (() -> Void)?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: Self.barHeight))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        bar.material = .headerView
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false

        queryField.placeholderString = "Find"
        queryField.setAccessibilityLabel("Find — Search text in the document")
        queryField.target = self
        queryField.action = #selector(queryChanged)
        queryField.sendsWholeSearchString = false
        queryField.sendsSearchStringImmediately = false
        queryField.focusRingType = .none

        replaceField.placeholderString = "Replace"
        replaceField.setAccessibilityLabel("Replace text in the document")
        replaceField.target = self
        replaceField.action = #selector(replaceCurrent)

        caseButton.target = self
        caseButton.action = #selector(optionsChanged)
        wholeWordButton.target = self
        wholeWordButton.action = #selector(optionsChanged)
        regexButton.target = self
        regexButton.action = #selector(optionsChanged)
        for button in [caseButton, wholeWordButton, regexButton] {
            button.bezelStyle = .texturedRounded
            button.font = .systemFont(ofSize: 11)
        }

        for button in [previousButton, nextButton, closeButton] {
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.target = self
            button.imagePosition = .imageOnly
        }
        previousButton.action = #selector(selectPrevious)
        nextButton.action = #selector(selectNext)
        closeButton.action = #selector(close)

        replaceButton.target = self
        replaceButton.action = #selector(replaceAll)
        replaceButton.bezelStyle = .rounded
        replaceButton.font = .systemFont(ofSize: 12)
        replaceButton.controlSize = .small

        counter.font = .systemFont(ofSize: 11)
        counter.textColor = .secondaryLabelColor
        counter.alignment = .right

        for subview in [
            queryField, previousButton, nextButton, caseButton, wholeWordButton,
            regexButton, counter, replaceField, replaceButton, closeButton,
        ] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            queryField.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            queryField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            queryField.heightAnchor.constraint(equalToConstant: 22),

            previousButton.leadingAnchor.constraint(equalTo: queryField.trailingAnchor, constant: 4),
            previousButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 22),

            nextButton.leadingAnchor.constraint(equalTo: previousButton.trailingAnchor),
            nextButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 22),

            caseButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 6),
            caseButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            wholeWordButton.leadingAnchor.constraint(equalTo: caseButton.trailingAnchor, constant: 2),
            wholeWordButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            regexButton.leadingAnchor.constraint(equalTo: wholeWordButton.trailingAnchor, constant: 2),
            regexButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            counter.leadingAnchor.constraint(greaterThanOrEqualTo: regexButton.trailingAnchor, constant: 8),
            counter.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            counter.trailingAnchor.constraint(equalTo: replaceField.leadingAnchor, constant: -8),
            counter.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),

            replaceField.trailingAnchor.constraint(equalTo: replaceButton.leadingAnchor, constant: -6),
            replaceField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            replaceField.widthAnchor.constraint(equalToConstant: 160),
            replaceField.heightAnchor.constraint(equalToConstant: 22),

            replaceButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            replaceButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - Use

    func attach(editor: MarkdownTextView) {
        self.editor = editor
    }

    /// Shows the bar without moving focus or re-running the search. Tab switches
    /// use this to restore the selected tab's bar as it was, without yanking
    /// focus out of its editor or jumping the caret to the first match.
    func show(in window: NSWindow) {
        insert(into: window)
        view.isHidden = false
    }

    /// The bar is inserted above the editor scroll view inside the window's content
    /// view, so it overlays the document exactly as the original's does.
    func present(in window: NSWindow) {
        insert(into: window)
        view.isHidden = false
        let editor = self.editor
        view.window?.makeFirstResponder(queryField)
        if editor != nil {
            // The original seeds the field with the current selection.
            let selected = editor?.selectedText ?? ""
            if !selected.contains("\n"), !selected.isEmpty, selected.count <= 200 {
                queryField.stringValue = selected
            }
            queryChanged()
        }
    }

    private func insert(into window: NSWindow) {
        guard let content = window.contentView else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        if view.superview == nil {
            content.addSubview(view, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: content.topAnchor),
                view.heightAnchor.constraint(equalToConstant: Self.barHeight),
            ])
        }
    }

    /// Hides the bar without touching first responder. Tab switches use this so
    /// one document's bar never leaks into another tab. Must not trigger
    /// `loadView()` before the bar has been presented at least once.
    func hide() {
        guard isViewLoaded else { return }
        view.isHidden = true
    }

    func dismiss() {
        hide()
        editor?.window?.makeFirstResponder(editor)
    }

    var isVisible: Bool { !view.isHidden }

    // MARK: - Searching

    @objc private func queryChanged() {
        guard let editor else { return }
        var options = NodeSearch.Options()
        options.caseSensitive = caseButton.state == .on
        options.wholeWord = wholeWordButton.state == .on
        options.useRegularExpression = regexButton.state == .on
        let query = queryField.stringValue
        if !NodeSearch(options: options).hasValidExpression(for: query) {
            results = NodeSearch.Results()
            selectedIndex = nil
            counter.textColor = .systemRed
            counter.stringValue = "Invalid regular expression"
            return
        }
        counter.textColor = .secondaryLabelColor
        results = NodeSearch(options: options).find(in: editor.document, query: query)
        counter.stringValue = counterText()
        // Land on the match at or after the caret, which is what makes repeated
        // Cmd-F feel like stepping forward rather than restarting - and what lets
        // Replace walk forward: restarting at hit 0 re-replaced the first match in
        // the document every time.
        let caret = editor.selectedRange().location
        selectedIndex =
            results.hits.indices.first { index in
                guard let range = bufferRange(for: results.hits[index], in: editor) else {
                    return false
                }
                return NSMaxRange(range) > caret
            } ?? (results.hits.isEmpty ? nil : 0)
        if let selectedIndex {
            select(index: selectedIndex, reveal: true)
        }
    }

    @objc private func optionsChanged() {
        queryChanged()
    }

    private func counterText() -> String {
        guard !results.hits.isEmpty else {
            return queryField.stringValue.isEmpty ? "" : "No results"
        }
        let current = (selectedIndex ?? 0) + 1
        var text = "\(current) of \(results.count)"
        if results.isTruncated { text += "+" }
        return text
    }

    @objc private func selectNext() {
        guard !results.hits.isEmpty else { return }
        select(index: ((selectedIndex ?? -1) + 1) % results.count, reveal: true)
    }

    @objc private func selectPrevious() {
        guard !results.hits.isEmpty else { return }
        let next = (selectedIndex ?? 1) - 1
        select(index: (next + results.count) % results.count, reveal: true)
    }

    private func select(index: Int, reveal: Bool) {
        guard results.hits.indices.contains(index), let editor else { return }
        selectedIndex = index
        let hit = results.hits[index]
        counter.stringValue = counterText()
        guard let range = bufferRange(for: hit, in: editor) else {
            // A hit inside an attachment-rendered block has no buffer range; skip
            // to the next one rather than pretending the highlight is somewhere
            // else. At most one full lap: when every hit is unmappable, stop
            // instead of recursing around the ring until the stack blows.
            guard skippedRanges < results.count else {
                skippedRanges = 0
                return
            }
            skippedRanges += 1
            select(index: (index + 1) % results.count, reveal: reveal)
            return
        }
        skippedRanges = 0
        editor.setSelectedRange(range)
        if reveal { editor.scrollRangeToVisible(range) }
    }

    /// Consecutive unmappable hits, so a find full of attachment-only matches
    /// cannot turn the skip-to-next fallback into infinite recursion.
    private var skippedRanges = 0

    /// Node-relative offset to buffer range.
    ///
    /// The layout pass records where each inline element's *plain text* sits in
    /// the buffer, so a hit offset translates directly. The old heuristic added
    /// the offset to the first recorded element's start, which landed every hit
    /// past the first element in the wrong place (headings missed by their own
    /// marker width, paragraphs after bold text drifted by the syntax).
    private func bufferRange(for hit: NodeSearch.Hit, in editor: MarkdownTextView) -> NSRange? {
        let inlines = editor.layout.inlineNodes.filter { $0.blockID == hit.blockID }
        for inline in inlines where NSLocationInRange(hit.offset, inline.plainRange) {
            let delta = hit.offset - inline.plainRange.location
            guard delta >= 0, delta + hit.length <= inline.contentRange.length else { continue }
            return NSRange(
                location: inline.contentRange.location + delta,
                length: hit.length
            )
        }
        // Fallback for blocks whose plain text maps cleanly (no markers, no
        // inline syntax between the block start and the hit).
        guard let blockRange = editor.bufferRange(forBlock: hit.blockID) else { return nil }
        let hasMarkers = editor.layout.markers.contains { $0.blockID == hit.blockID }
        let hasSyntax = inlines.contains { $0.contentRange.length > 0 }
        if hasMarkers || hasSyntax { return nil }
        guard hit.offset + hit.length <= blockRange.length else { return nil }
        return NSRange(location: blockRange.location + hit.offset, length: hit.length)
    }

    // MARK: - Replacing

    /// The original replaces the current match only, and leaves the caret on the
    /// replacement so consecutive Replace presses walk forward through the document.
    @objc private func replaceCurrent() {
        guard let index = selectedIndex, let editor,
            results.hits.indices.contains(index),
            let range = bufferRange(for: results.hits[index], in: editor)
        else { return }
        // Through the editor's editing path: a direct storage write never entered
        // the undo stack, and the node tree stayed stale until the next keystroke.
        editor.apply(
            FormatController.Edit(
                range: range,
                text: replaceField.stringValue,
                selection: NSRange(
                    location: range.location + replaceField.stringValue.utf16.count, length: 0
                )
            )
        )
        onReplace?()
        queryChanged()
    }

    @objc private func replaceAll() {
        guard let editor else { return }
        let query = queryField.stringValue
        guard !query.isEmpty else { return }
        var options = NodeSearch.Options()
        options.caseSensitive = caseButton.state == .on
        options.wholeWord = wholeWordButton.state == .on
        options.useRegularExpression = regexButton.state == .on
        let search = NodeSearch(options: options)
        guard search.hasValidExpression(for: query) else {
            counter.textColor = .systemRed
            counter.stringValue = "Invalid regular expression"
            return
        }
        let replaced = search.replace(in: editor.document.blocks, query: query, with: replaceField.stringValue)
        // Replace-all goes through the tree and then reloads, because rewriting the
        // buffer text directly would leave the node tree and the buffer describing
        // different documents. The reload is applied as one whole-buffer edit so it
        // lands on the undo stack - the old path rewrote the storage behind the
        // text view's back, and ⌘Z afterwards applied stale ranges into the new
        // buffer, corrupting text at best.
        var document = editor.document
        document.blocks = replaced
        document.rebuildIndexes()
        let next = document.source
        guard let storage = editor.textStorage, next != storage.string else {
            queryChanged()
            return
        }
        editor.apply(
            FormatController.Edit(
                range: NSRange(location: 0, length: storage.length),
                text: next,
                selection: NSRange(location: 0, length: 0)
            )
        )
        onReplace?()
        queryChanged()
    }

    @objc private func close() {
        dismiss()
        onClose?()
    }

    // MARK: - Actions

    @objc func findNext(_ sender: Any?) { selectNext() }
    @objc func findPrevious(_ sender: Any?) { selectPrevious() }
}

/// `NSSearchField` without the rounded bezel the original's find field has.
private final class SearchField: NSSearchField {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
    }
}

extension NSButton {
    /// SF Symbol button; `systemSymbolName` returns nil for a name that no longer
    /// exists, so the fallback keeps the bar usable instead of crashing.
    fileprivate convenience init(symbol: String, tooltip: String) {
        let image =
            NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            ?? NSImage(size: NSSize(width: 12, height: 12))
        self.init(image: image, target: nil, action: nil)
        self.toolTip = tooltip
    }
}

private final class ToggleButton: NSButton {
    init(title: String, tooltip: String) {
        super.init(frame: .zero)
        self.title = title
        self.toolTip = tooltip
        self.setButtonType(.toggle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
