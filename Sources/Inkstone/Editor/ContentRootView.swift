import AppKit

/// The window chrome: the Files panel docked to the window's left edge - global
/// to the window, like VSCode's sidebar - and the tab area on the right.
///
/// The sidebar runs the full window height, under the transparent titlebar, so
/// the traffic lights sit on it; the tab area stops below the titlebar so the
/// tab strip never hides underneath it.
final class ContentRootView: NSView {
    private let files: NSView
    /// The custom TablePro-style tab strip band under the titlebar.
    private let tabStrip: NSView
    /// The documents, border-less - the strip above draws the tabs.
    private let tabArea: NSView
    private let filesDivider = PanelDivider()
    /// The document name, drawn centred in the title strip like the original's.
    private let titleLabel = NSTextField(labelWithString: "")
    /// Live sidebar width, moved by dragging the divider it owns.
    private var filesWidth: CGFloat = ContentRootView.preferredWidth

    init(files: NSView, tabStrip: NSView, tabArea: NSView) {
        self.files = files
        self.tabStrip = tabStrip
        self.tabArea = tabArea
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        wantsLayer = true
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)
        filesDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.filesWidth = min(
                max(self.filesWidth + delta, Self.minimumPanelWidth),
                max(Self.minimumPanelWidth, self.bounds.width - Self.editorFloor - Self.dividerWidth)
            )
            self.needsLayout = true
        }
        addSubview(files)
        addSubview(filesDivider)
        addSubview(tabStrip)
        addSubview(tabArea)
        files.isHidden = true
        filesDivider.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var isFilesVisible: Bool { !files.isHidden }

    func setFilesVisible(_ visible: Bool) {
        files.isHidden = !visible
        filesDivider.isHidden = !visible
        needsLayout = true
    }

    func apply(theme: EditorTheme) {
        filesDivider.panelBackground = theme.sidebarBackground.nsColor
        filesDivider.panelEdge = .minX
        filesDivider.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        // The sidebar is a full-height column: it runs under the titlebar the
        // way the original's does, and the traffic lights sit on it. The tab
        // area clears the titlebar (and the tab bar never shows above it).
        var left = CGFloat(0)
        if isFilesVisible {
            let width = min(
                filesWidth,
                max(Self.minimumPanelWidth, bounds.width - Self.editorFloor - Self.dividerWidth)
            )
            files.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            filesDivider.frame = NSRect(
                x: width, y: 0, width: Self.dividerWidth, height: bounds.height
            )
            left = width + Self.dividerWidth
        }
        let bodyTop = bounds.height - safeAreaInsets.top
        let stripHeight: CGFloat = 36
        tabStrip.frame = NSRect(
            x: left, y: bodyTop - stripHeight, width: max(0, bounds.width - left), height: stripHeight
        )
        tabArea.frame = NSRect(
            x: left, y: 0, width: max(0, bounds.width - left), height: bodyTop - stripHeight
        )
        // Centred in the title strip over the tab area - the editor's span,
        // since the sidebar docks to the edge and never the middle.
        titleLabel.frame = NSRect(
            x: left, y: bounds.height - 30, width: max(0, bounds.width - left), height: 22
        )
    }

    func setTitleText(_ text: String) {
        titleLabel.stringValue = text
    }

    /// The original's sidebar is 220pt out of the box, and resizes by dragging the rule.
    private static let preferredWidth: CGFloat = 220
    private static let minimumPanelWidth: CGFloat = 150
    private static let editorFloor: CGFloat = 340
    /// The grab area: a one-point target is a coin toss with a trackpad, so the
    /// view is wider than the hairline it draws.
    private static let dividerWidth: CGFloat = 5
}
