import AppKit

/// One document's content: the editor with the outline docked to its right.
///
/// A document no longer owns a window - it is mounted as a tab in an
/// `EditorWindowController` - so this view is the whole of what a tab shows.
/// The Files panel is window-global and lives in the host's `ContentRootView`.
final class DocumentContentView: NSView {
    private let editor: NSView
    private let outline: NSView
    private let outlineDivider = PanelDivider()
    /// Live outline width, moved by dragging the divider it owns.
    private var outlineWidth: CGFloat = DocumentContentView.preferredWidth

    init(editor: NSView, outline: NSView) {
        self.editor = editor
        self.outline = outline
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        wantsLayer = true
        outline.isHidden = true
        outlineDivider.isHidden = true
        outlineDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.outlineWidth = min(
                max(self.outlineWidth - delta, Self.minimumPanelWidth),
                max(Self.minimumPanelWidth, self.bounds.width - Self.editorFloor - Self.dividerWidth)
            )
            self.needsLayout = true
        }
        addSubview(editor)
        addSubview(outlineDivider)
        addSubview(outline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var isOutlineVisible: Bool { !outline.isHidden }

    func setOutlineVisible(_ visible: Bool) {
        outline.isHidden = !visible
        outlineDivider.isHidden = !visible
        needsLayout = true
    }

    func apply(theme: EditorTheme) {
        outlineDivider.panelBackground = theme.background.nsColor
        outlineDivider.panelEdge = .maxX
        outlineDivider.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        if isOutlineVisible {
            let width = min(
                outlineWidth,
                max(Self.minimumPanelWidth, bounds.width - Self.editorFloor - Self.dividerWidth)
            )
            outline.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
            outlineDivider.frame = NSRect(
                x: bounds.width - width - Self.dividerWidth, y: 0,
                width: Self.dividerWidth, height: bounds.height
            )
            editor.frame = NSRect(
                x: 0, y: 0, width: max(0, bounds.width - width - Self.dividerWidth),
                height: bounds.height
            )
        } else {
            outlineDivider.isHidden = true
            editor.frame = bounds
        }
    }

    /// The original's sidebar is 220pt out of the box, and resizes by dragging the rule.
    private static let preferredWidth: CGFloat = 220
    private static let minimumPanelWidth: CGFloat = 150
    private static let editorFloor: CGFloat = 340
    /// The grab area: a one-point target is a coin toss with a trackpad, so the
    /// view is wider than the hairline it draws.
    private static let dividerWidth: CGFloat = 5
}

/// The hairline between a panel and the editor.
///
/// Dragging reports to the superview, which owns the widths; the line itself is
/// drawn a point wide over the wider grab area.
final class PanelDivider: NSView {
    /// The drag distance since the previous event, in points (mouse x).
    var onDrag: ((CGFloat) -> Void)?
    /// The panel's own background, painted over the grab area's panel-side half
    /// so the unpainted band beside the hairline matches the panel, not the window.
    var panelBackground: NSColor?
    /// Which half of the grab strip belongs to the panel.
    var panelEdge: NSRectEdge = .minX
    private var lastLocation: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        lastLocation = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let last = lastLocation else { return }
        let location = event.locationInWindow.x
        lastLocation = location
        onDrag?(location - last)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let panelBackground {
            panelBackground.setFill()
            NSRect(
                x: panelEdge == .minX ? 0 : bounds.midX,
                y: 0, width: bounds.width / 2, height: bounds.height
            ).fill()
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}
