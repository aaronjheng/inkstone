import AppKit

/// The list that appears under the caret while a completion is available.
///
/// Deliberately not an `NSTableView`: a completion list is a transient popover with
/// single-column rows, and a table view brings selection, scrolling and a data source
/// along for a dozen items. This draws its rows itself and takes the keyboard.
///
/// It positions itself against the caret's glyph rect rather than the caret's character
/// index: the popover has to sit where the text *is*, and for a wrapped line only the
/// layout manager knows that.
@MainActor
final class CompletionController: NSObject {
    private static let rowHeight: CGFloat = 22
    private static let maxVisibleRows = 8

    private let panel: NSPanel
    private let table = TableView()
    private var items: [Completion] = []
    private var selected = 0
    /// The buffer range a chosen candidate replaces.
    private var replaceRange: NSRange = NSRange(location: 0, length: 0)
    private weak var host: NSTextView?

    /// Called with the accepted candidate. The controller does not edit the text itself.
    var onAccept: ((Completion, NSRange) -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: Self.rowHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = table
        table.wantsLayer = true
    }

    // MARK: - Presenting

    /// Shows candidates, or hides the panel when there are none.
    func update(
        items: [Completion], for range: NSRange, in textView: NSTextView, theme: EditorTheme
    ) {
        self.items = items
        replaceRange = range
        host = textView
        guard !items.isEmpty else {
            hide()
            return
        }
        selected = 0
        rebuild(theme: theme)
        position(under: textView)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
        items = []
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - Keyboard

    /// Returns whether the key was consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard !items.isEmpty else { return false }
        func moved() -> Bool {
            // The rows are painted by hand, so a selection index change is invisible
            // until the next repaint is asked for.
            table.needsDisplay = true
            return true
        }
        switch event.keyCode {
        case 125:  // down
            selected = min(selected + 1, items.count - 1)
            return moved()
        case 126:  // up
            selected = max(selected - 1, 0)
            return moved()
        case 36, 76:  // return, enter
            accept()
            return true
        case 27:  // escape
            hide()
            return true
        case 9:  // tab
            accept()
            return true
        default:
            return false
        }
    }

    private func accept() {
        guard items.indices.contains(selected) else { return }
        onAccept?(items[selected], replaceRange)
        hide()
    }

    /// Places the panel just under the caret's glyph, in screen coordinates.
    private func position(under textView: NSTextView) {
        // The layout manager owns where a character is; the text view has no API for it.
        let caret: NSPoint
        if let layoutManager = textView.layoutManager {
            let glyph = layoutManager.glyphRange(
                forCharacterRange: textView.selectedRange(), actualCharacterRange: nil
            )
            var rect = NSRect.zero
            layoutManager.enumerateLineFragments(forGlyphRange: glyph) { line, _, _, _, stop in
                rect = line
                stop.pointee = true
            }
            // Line-fragment rects are in text-container coordinates; the view adds
            // `textContainerInset` on top. Skipping the origin put the panel one
            // content-padding off, the same offset `BlockDecorator` had to learn.
            caret = NSPoint(
                x: rect.origin.x + textView.textContainerOrigin.x,
                y: rect.origin.y + textView.textContainerOrigin.y
            )
        } else {
            caret = textView.bounds.origin
        }
        let inWindow = textView.convert(caret, to: nil)
        guard let window = textView.window else { return }
        var origin = window.convertPoint(toScreen: inWindow)
        origin.y -= panel.frame.height + 4
        // Flip above the caret when there is no room below, the way every autocomplete
        // does: the bottom of the screen is where the cursor usually is. The downward
        // shift is cancelled and the panel's bottom lands a few points above the line.
        let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 0, height: 0)
        if origin.y < screen.minY + 8 {
            origin.y += panel.frame.height + 8
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Drawing

    private func rebuild(theme: EditorTheme) {
        let visible = min(items.count, Self.maxVisibleRows)
        let width: CGFloat = 260
        let height = Self.rowHeight * CGFloat(visible) + 8
        table.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.setContentSize(NSSize(width: width, height: height))
        table.layer?.backgroundColor = theme.background.nsColor.cgColor
        table.layer?.cornerRadius = 6
        table.layer?.borderWidth = 1
        table.layer?.borderColor = theme.tableBorder.nsColor.cgColor
        table.onDraw = { [weak self] in
            guard let self else { return }
            RowPainter.draw(
                self.items, selected: self.selected, in: self.table, theme: theme
            )
        }
        table.onMouseDown = { [weak self] point in
            guard let self, let row = self.table.row(at: point), row < self.items.count else {
                return
            }
            self.selected = row
            self.accept()
        }
        table.needsDisplay = true
    }

    override var description: String {
        MainActor.assumeIsolated {
            "CompletionController(\(items.count) items, selected \(selected))"
        }
    }

    /// A host view that only knows how to paint the rows.
    private final class TableView: NSView {
        var onDraw: (() -> Void)?
        var onMouseDown: ((NSPoint) -> Void)?
        var rowHeight: CGFloat { 22 }

        override func draw(_ dirtyRect: NSRect) {
            onDraw?()
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onMouseDown?(point)
        }

        /// Which row a click landed on, or `nil` for the padding.
        func row(at point: NSPoint) -> Int? {
            let index = Int((point.y - 4) / rowHeight)
            return index >= 0 ? index : nil
        }
    }
}

extension CompletionController {
    /// Row drawing, kept apart so the panel above stays about behaviour.
    @MainActor
    enum RowPainter {
        static func draw(
            _ items: [Completion], selected: Int, in view: NSView, theme: EditorTheme
        ) {
            let rows = min(items.count, 8)
            for index in 0..<rows {
                let item = items[index]
                let rect = NSRect(
                    x: 1, y: 4 + CGFloat(index) * 22, width: view.bounds.width - 2, height: 21
                )
                // The selection background goes down first: filling it after the text
                // painted the highlighted row's candidate out of existence.
                if index == selected {
                    NSColor.selectedContentBackgroundColor.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .left
                let label = NSAttributedString(
                    string: item.label,
                    attributes: [
                        .font: EditorFont.nsSystem(size: 12),
                        .foregroundColor: theme.text.nsColor,
                        .paragraphStyle: paragraph,
                    ]
                )
                label.draw(in: rect.insetBy(dx: 8, dy: 3))
                if !item.detail.isEmpty {
                    let detail = NSAttributedString(
                        string: item.detail,
                        attributes: [
                            .font: EditorFont.nsSystem(size: 12),
                            .foregroundColor: theme.marker.nsColor,
                            .paragraphStyle: paragraph,
                        ]
                    )
                    let size = detail.size()
                    detail.draw(at: NSPoint(x: view.bounds.width - size.width - 8, y: rect.minY + 3))
                }
            }
        }
    }
}
