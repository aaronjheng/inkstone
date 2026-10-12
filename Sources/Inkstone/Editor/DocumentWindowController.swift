import AppKit
import Foundation
import UniformTypeIdentifiers

/// The preferences a document window mirrors.
///
/// `Editor/` may not read `Session/`, and passing eight separate booleans through
/// every call site is how one of them ends up unset. This is the whole contract, in
/// the editor's own vocabulary, mapped from `EditorSettings` at the boundary.
struct EditorSettingsView {
    var autoPairBrackets = true
    var autoPairMarkdownSyntax = true
    var smartQuotes = true
    var indentSize = 2
    var codeIndentSize = 4
    var typewriter = false
    var focus = false
    var readonly = false
    var showInvisibleCharacters = false
    var showHiddenFiles = false
}

/// A scroll view that lets the document run under the title bar.
///
/// The original's window has no visible chrome: the content column extends to the top
/// of the window and the traffic lights float over it. `contentInsets.top` gives
/// the text container the clearance it needs while the visual background stays
/// continuous, and the scroll indicators are overlay-style so they only appear
/// while scrolling.
final class DocumentScrollView: NSScrollView {
    init(textView: NSTextView, theme: EditorTheme) {
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = textView
        backgroundColor = theme.background.nsColor
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        contentInsets = NSEdgeInsets(
            top: theme.contentPadding, left: 0, bottom: 0, right: 0
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentScrollView is created in code")
    }

    func apply(theme: EditorTheme) {
        backgroundColor = theme.background.nsColor
        contentInsets = NSEdgeInsets(
            top: theme.contentPadding, left: 0, bottom: 0, right: 0
        )
    }

    override func layout() {
        super.layout()
        // With `.fullSizeContentView`, the scroll view extends under the title
        // bar; the safe-area inset gives the clearance the traffic lights need
        // so the first heading is not clipped.
        let theme = (documentView as? MarkdownTextView)?.theme
        contentInsets.top = (theme?.contentPadding ?? 30) + safeAreaInsets.top
        centreContentColumn()
    }

    /// Recomputes the text column's width and inset for the current viewport.
    func centreContentColumn() {
        guard let textView = documentView as? MarkdownTextView else { return }
        // The text column is centred inside the viewport; the container width is
        // the theme's measure, not the window's.
        let measure = textView.theme.contentWidth(for: bounds.width)
        let available = bounds.width - contentInsets.left - contentInsets.right
        let inset = max(0, (available - measure) / 2)
        // Height 0: the scroll view's contentInsets already carry the title-bar
        // clearance, and a second inset here doubled the dead space above the
        // first block.
        textView.textContainerInset = NSSize(
            width: inset + textView.theme.contentPadding,
            height: 0
        )
        textView.setFrameSize(
            NSSize(
                width: measure,
                height: max(textView.frame.height, bounds.height)
            )
        )
    }
}

/// One document window.
///
/// One window per document, like the original. Multi-document is native window tabbing
/// rather than an in-app tab strip, which is both what the original does and less code
/// to keep correct.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let editor: MarkdownTextView
    private let scrollView: DocumentScrollView
    private var theme: EditorTheme
    private var documentURL: URL?
    private var isDirty = false
    private var autosizeTimer: Timer?
    private var autosaveTimer: Timer?
    /// Created lazily: source mode only needs a second text view once the user
    /// asks for it.
    private var sourceController: SourceModeController?
    private var parseOptions: BlockParser.Options = .standard

    private(set) var statusText = ""
    /// Files docked left, outline docked right - the original keeps one panel and
    /// swaps its contents, but the two answers ("where am I", "what's nearby")
    /// are read side by side here, so they dock independently.
    private let filesPanel: FileTreeController
    private let outlinePanel: OutlineViewController
    private let findController = FindReplaceController()
    private var findVisible = false
    internal var contentRoot: ContentRootView?
    private let environment: EditorEnvironment

    init(
        theme: EditorTheme, markdown: String = SampleDocument.text, url: URL? = nil,
        environment: EditorEnvironment = .live
    ) {
        self.theme = theme
        self.documentURL = url
        self.environment = environment
        editor = MarkdownTextView(theme: theme)
        scrollView = DocumentScrollView(textView: editor, theme: theme)
        filesPanel = FileTreeController()
        outlinePanel = OutlineViewController()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = theme.background.nsColor
        contentRoot = ContentRootView(
            files: filesPanel.view, editor: scrollView, outline: outlinePanel.view
        )
        contentRoot?.apply(theme: theme)
        window.contentView = contentRoot
        window.tabbingMode = .preferred
        window.minSize = NSSize(width: 520, height: 380)
        super.init(window: window)
        window.delegate = self

        parseOptions = environment.parseOptions
        editor.load(markdown: markdown)
        editor.onTextChange = { [weak self] _ in
            self?.markDirty()
        }
        // Path completion looks next to the document; an unsaved document looks next to
        // nothing and simply offers no candidates.
        let folder = url?.deletingLastPathComponent() ?? environment.sidebarFolder
        editor.completionDirectory = folder
        // A relative image path resolves against the document's folder; an unsaved
        // document has none, so its images simply do not load.
        editor.imagePainter.baseDirectory = folder
        sourceController = SourceModeController(
            theme: theme, markdown: markdown, parseOptions: parseOptions
        )
        sourceController?.onChange = { [weak self] markdown in
            self?.pushFromSource(markdown)
        }
        outlinePanel.onSelect = { [weak self] heading in
            self?.reveal(heading: heading)
        }
        outlinePanel.onToggle = { [weak self] in
            self?.toggleOutline(nil)
        }
        findController.attach(editor: editor)
        findController.onReplace = { [weak self] in
            self?.markDirty()
        }
        filesPanel.onSelect = { [weak self] url in
            guard let self else { return }
            do {
                try self.open(url)
            } catch {
                AppLogger.error("Failed to open \(url.lastPathComponent): \(error)", category: "Document")
            }
        }
        filesPanel.onCreateFile = { [weak self] in
            self?.createFileInFolder()
        }
        syncFilesRoot(forDocument: url)
        setWindowTitle()
        // The outline and the word count come from `updateStatus`; a fresh window
        // never edits anything, so without this the sidebar would sit at
        // "No headings · 0 words" until the first keystroke.
        updateStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DocumentWindowController is created in code")
    }

    // MARK: - Files

    var fileURL: URL? { documentURL }

    func open(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        documentURL = url
        editor.load(markdown: text)
        sourceController?.load(markdown: text)
        // A document opened into a scratch window brings its folder with it: the
        // file tree, path completion and relative images all resolve against it,
        // and none of those were bound when the empty window was created.
        let folder = url.deletingLastPathComponent()
        editor.completionDirectory = folder
        editor.imagePainter.baseDirectory = folder
        syncFilesRoot(forDocument: url)
        isDirty = false
        setWindowTitle()
        updateStatus()
    }

    var hasUnsavedChanges: Bool { isDirty }

    /// Replaces the buffer with a recovered draft and marks it dirty.
    ///
    /// It stays dirty on purpose: the draft is newer than whatever is on disk, so
    /// saving has to be the user's decision, not something recovery does for them.
    func restoreDraft(markdown: String) {
        editor.load(markdown: markdown)
        sourceController?.load(markdown: markdown)
        isDirty = true
        setWindowTitle()
        updateStatus()
    }

    func save() throws {
        guard let documentURL else { return }
        try editor.markdown.write(to: documentURL, atomically: true, encoding: .utf8)
        onSaveCommitted?(documentURL)
        isDirty = false
        autosaveTimer?.invalidate()
        setWindowTitle()
    }

    func saveAs(_ url: URL) throws {
        try editor.markdown.write(to: url, atomically: true, encoding: .utf8)
        onSaveCommitted?(documentURL)
        documentURL = url
        onSaveCommitted?(url)
        isDirty = false
        autosaveTimer?.invalidate()
        setWindowTitle()
    }

    /// Autosave interval in seconds; `0` means off.
    var autosaveInterval: TimeInterval = 0
    /// Filled in by `AppStore`: `Editor/` may not reach into `Session/`.
    var onWriteDraft: ((DraftSnapshot) -> Void)?
    var onSaveCommitted: ((URL?) -> Void)?

    private func markDirty() {
        isDirty = true
        setWindowTitle()
        updateStatus()
        scheduleAutosave()
    }

    /// Mirrors the document and, when autosave is on, writes the file itself.
    ///
    /// Debounced rather than periodic: the timer is restarted on every keystroke, so a
    /// burst of typing produces one write instead of one per interval. A periodic timer
    /// would fire on a document that had not been touched for a while - exactly when
    /// there is nothing to save.
    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        // The draft goes down immediately: it is cheap, it is what crash recovery reads,
        // and it must not depend on a preference the user may have switched off.
        writeDraft()
        guard autosaveInterval > 0 else { return }
        autosaveTimer = Timer.scheduledTimer(
            withTimeInterval: autosaveInterval, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.performAutosave() }
        }
    }

    private func writeDraft() {
        onWriteDraft?(
            DraftSnapshot(
                sourceURL: documentURL,
                title: documentURL?.lastPathComponent ?? "Untitled",
                markdown: editor.markdown,
                savedAt: Date()
            )
        )
    }

    /// Writes the file if the document has a path, and refreshes the draft either way.
    ///
    /// The draft is *not* cleared here. An autosave is not a save: the user has not
    /// committed to this content, so the recovery copy has to stay until they save.
    private func performAutosave() {
        guard isDirty else { return }
        if let documentURL {
            try? editor.markdown.write(to: documentURL, atomically: true, encoding: .utf8)
        }
        writeDraft()
    }

    private func setWindowTitle() {
        // The original centres the bare file name in the titlebar, and the edited
        // state lives in the close button rather than in a suffix. The system
        // title stays set for Mission Control and accessibility; the visible
        // one is drawn by `ContentRootView`, because AppKit offers no centred
        // title on a full-size-content window.
        let name = documentURL?.lastPathComponent ?? "Untitled"
        window?.title = name
        window?.subtitle = ""
        window?.isDocumentEdited = isDirty
        contentRoot?.setTitleText(name)
    }

    // MARK: - Format commands

    /// Runs one Format-menu command against the editor.
    ///
    /// Indentation is excluded from the pure-rewrite path: it needs the caret's
    /// column inside its line, which is a property of the view. A visible source
    /// view is reloaded afterwards, so the two never show different text.
    func format(_ action: FormatAction) {
        switch action {
        case .indent:
            editor.formatIndent(outdent: false)
        case .outdent:
            editor.formatIndent(outdent: true)
        default:
            editor.format { FormatController.edit(for: action, in: $0, range: $1) }
        }
        if sourceController?.isVisible == true {
            sourceController?.load(markdown: editor.markdown)
        }
    }

    // MARK: - Find and replace

    /// Slides the find bar down from the top of the window, as the original does.
    @objc func toggleFind(_ sender: Any?) {
        findVisible.toggle()
        if findVisible, let window {
            findController.present(in: window)
        } else {
            findController.dismiss()
        }
    }

    @objc func findNext(_ sender: Any?) {
        if !findVisible { toggleFind(nil) }
        findController.findNext(sender)
    }

    @objc func findPrevious(_ sender: Any?) {
        if !findVisible { toggleFind(nil) }
        findController.findPrevious(sender)
    }

    // MARK: - Source mode

    var isSourceModeActive: Bool { sourceController?.isVisible ?? false }
    var isSidebarVisible: Bool { areFilesVisible || isOutlineVisible }
    var isOutlineVisible: Bool { contentRoot?.isOutlineVisible ?? false }
    var areFilesVisible: Bool { contentRoot?.isFilesVisible ?? false }

    /// Toggles source mode and keeps the two views in step.
    ///
    /// The original mounts source mode in a second container over the same window; the
    /// markdown comes from the node tree, so attachment-rendered blocks show their
    /// real source rather than the `U+FFFC` the buffer holds for them.
    @objc func toggleSourceMode(_ sender: Any?) {
        guard let window else { return }
        let result = sourceController?.toggle(
            in: window, markdown: editor.markdown, parseOptions: parseOptions
        )
        if let result {
            pushFromSource(result)
            editor.window?.makeFirstResponder(editor)
        }
        updateStatus()
    }

    /// Applies edits made in source mode: re-parse the document and reload the
    /// editor. Wholesale, because source mode is a deliberate mode rather than the
    /// typing path.
    private func pushFromSource(_ markdown: String) {
        editor.load(markdown: markdown)
        markDirty()
    }

    // MARK: - Theme

    func apply(theme: EditorTheme) {
        self.theme = theme
        window?.backgroundColor = theme.background.nsColor
        scrollView.apply(theme: theme)
        editor.apply(theme: theme)
        sourceController?.apply(theme: theme)
        filesPanel.apply(theme: theme)
        outlinePanel.apply(theme: theme)
        contentRoot?.apply(theme: theme)
        updateStatus()
    }

    /// The parsed document, for anything that renders outside the buffer: export,
    /// word count, the outline. Never the text - the buffer is the text.
    ///
    /// Not named `document`: `NSWindowController` already has one, typed `AnyObject?`,
    /// and shadowing it turns every call site into a silent runtime trap.
    var markdown: MarkdownDocument { editor.document }

    // MARK: - Preferences

    /// Pushes the preferences the editor keeps a copy of.
    ///
    /// `Editor/` cannot read `Session/`, so the values arrive one by one rather than
    /// as `EditorSettings`.
    func applyEditorSettings(_ settings: EditorSettingsView) {
        editor.inputOptions = InputOptions(
            autoPairBrackets: settings.autoPairBrackets,
            autoPairMarkdownSyntax: settings.autoPairMarkdownSyntax,
            smartQuotes: settings.smartQuotes,
            indentSize: settings.indentSize,
            codeIndentSize: settings.codeIndentSize
        )
        editor.keepsCaretInMiddle = settings.typewriter
        editor.isFocusModeEnabled = settings.focus
        editor.isReadonly = settings.readonly
        editor.showsInvisibleCharacters = settings.showInvisibleCharacters
        filesPanel.showsHiddenFiles = settings.showHiddenFiles
        editor.needsDisplay = true
        updateStatus()
    }

    // MARK: - Panels

    /// "Files" docks left and "Outline" docks right, independently; "Sidebar"
    /// drives both together. Every change re-lays the content root and re-measures
    /// the editor, since the text column centres in whatever space is left.
    @objc func toggleSidebar(_ sender: Any?) {
        let show = !isSidebarVisible
        contentRoot?.setFilesVisible(show)
        contentRoot?.setOutlineVisible(show)
        editor.markDirty()
    }

    @objc func toggleOutline(_ sender: Any?) {
        contentRoot?.setOutlineVisible(!isOutlineVisible)
        editor.markDirty()
    }

    @objc func toggleFiles(_ sender: Any?) {
        contentRoot?.setFilesVisible(!areFilesVisible)
        editor.markDirty()
    }

    /// Shows the file tree without toggling it away when it is already up.
    ///
    /// Opening a folder is this app's only "show me the hierarchy" moment: the
    /// tree starts hidden (the original's default) and a folder open that left
    /// it hidden would render itself invisible.
    func showFilesPanel() {
        guard !areFilesVisible else { return }
        contentRoot?.setFilesVisible(true)
        editor.markDirty()
    }

    /// Re-points the files tree when the sidebar-folder preference changes.
    func refreshFilesRoot() {
        syncFilesRoot(forDocument: documentURL)
    }

    /// Re-parses the document when a Markdown syntax preference changes, so an
    /// open window follows the setting instead of waiting for a reopen.
    func applyParseOptions(_ options: BlockParser.Options) {
        parseOptions = options
        editor.load(markdown: editor.markdown)
    }

    /// Points the file tree at its folder: the preference wins over the
    /// document's own folder.
    private func syncFilesRoot(forDocument url: URL?) {
        filesPanel.setRoot(
            environment.sidebarFolder ?? url?.deletingLastPathComponent(), fallback: nil
        )
        filesPanel.current(path: url?.path)
    }

    /// The last heading at or before the caret, so the outline highlights the
    /// section the user is reading rather than the block the caret sits in.
    private func currentHeading() -> MarkdownDocument.Heading? {
        let location = editor.selectedRange().location
        var found: MarkdownDocument.Heading?
        for heading in editor.document.headings {
            guard let range = editor.bufferRange(forBlock: heading.blockID) else { continue }
            guard range.location <= location else { break }
            found = heading
        }
        return found
    }

    /// The files panel's "+": a new Markdown file in the tree's folder, opened
    /// once it exists on disk. The tree refreshes itself afterwards, because
    /// nothing watches the folder for changes made outside the app.
    private func createFileInFolder() {
        guard let window, let folder = filesPanel.rootURL else { return }
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.allowedContentTypes = [.plainText, .markdown]
        panel.nameFieldStringValue = "Untitled.md"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data().write(to: url)
            }
            try? self.open(url)
            self.filesPanel.refresh()
        }
    }

    /// Scrolls to a heading chosen in the outline and puts the caret on it.
    private func reveal(heading: MarkdownDocument.Heading) {
        guard let block = editor.document.blocks.first(where: { $0.id == heading.blockID }),
            let range = editor.bufferRange(forBlock: block.id)
        else { return }
        editor.setSelectedRange(range)
        editor.scrollRangeToVisible(range)
    }

    // MARK: - Status

    /// The original's status line is `<selection> words · <total> words · <reading time>`,
    /// falling back to the total when nothing is selected.
    private func updateStatus() {
        let speed = environment.wordsPerMinute
        let total = Counter.count(editor.document.plainText, wordsPerMinute: speed)
        let selection = editor.selectedText
        if selection.isEmpty {
            statusText = total.summary
        } else {
            let part = Counter.selection(selection, wordsPerMinute: speed)
            statusText = "\(part.words) of \(total.words) \(total.words == 1 ? "word" : "words") · \(total.characters) characters"
        }
        outlinePanel.update(
            headings: editor.document.headings,
            counts: (words: total.words, characters: total.characters),
            scrollTo: currentHeading()
        )
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        autosaveTimer?.invalidate()
    }
}

/// Settings the editor needs, handed down instead of read from a singleton.
///
/// `Editor/` must not reference `Session/` (AGENTS.md dependency rule 3): the
/// document state is owned by `AppStore`, and the editor only ever talks upward
/// through parameters and closures. Reading `SettingsStore.shared` from inside the
/// window controller would make every window's parse options and reading speed
/// depend on a global that the session layer mutates at runtime.
struct EditorEnvironment {
    var parseOptions: BlockParser.Options = .standard
    var sidebarFolder: URL?
    var wordsPerMinute: Int = 382
    var autosaveInterval: TimeInterval = 0

    /// Filled in by `AppStore`; the default keeps `DocumentWindowController`
    /// constructible on its own.
    @MainActor
    static var live: EditorEnvironment { EditorEnvironment() }

    /// A document's unsaved content, handed up to the draft store.
    ///
    /// A value rather than the `Draft` type itself: `Editor/` must not name a `Session/`
    /// type, and this is the whole contract between them.
    func draftSnapshot(
        sourceURL: URL?, title: String, markdown: String
    ) -> DraftSnapshot {
        DraftSnapshot(
            sourceURL: sourceURL, title: title, markdown: markdown, savedAt: Date()
        )
    }

}

/// What a window tells the session layer about its unsaved content.
struct DraftSnapshot {
    var sourceURL: URL?
    var title: String
    var markdown: String
    var savedAt: Date
}

/// The window's root view: files docked left, outline docked right, editor between.
///
/// Both panels are created hidden so a fresh window matches the original's default of
/// no sidebars, and toggling one never disturbs the other's frame - the layout
/// only ever moves the dividers. Widths are draggable: the original's rule drags,
/// and a sidebar that cannot be resized makes a narrow file name indistinguishable.
final class ContentRootView: NSView {
    private let files: NSView
    private let outline: NSView
    private let editor: NSView
    private let filesDivider = PanelDivider()
    private let outlineDivider = PanelDivider()
    /// The document name, drawn centred in the title strip like the original's.
    private let titleLabel = NSTextField(labelWithString: "")
    /// Live panel widths, moved by dragging the divider each one owns.
    private var filesWidth: CGFloat = ContentRootView.preferredWidth
    private var outlineWidth: CGFloat = ContentRootView.preferredWidth

    init(files: NSView, editor: NSView, outline: NSView) {
        self.files = files
        self.editor = editor
        self.outline = outline
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        wantsLayer = true
        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)
        filesDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.filesWidth = self.clampedWidth(self.filesWidth + delta, other: self.outlineWidth)
            self.needsLayout = true
        }
        outlineDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.outlineWidth = self.clampedWidth(self.outlineWidth - delta, other: self.filesWidth)
            self.needsLayout = true
        }
        addSubview(files)
        addSubview(filesDivider)
        addSubview(editor)
        addSubview(outlineDivider)
        addSubview(outline)
        files.isHidden = true
        outline.isHidden = true
        filesDivider.isHidden = true
        outlineDivider.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var isFilesVisible: Bool { !files.isHidden }

    var isOutlineVisible: Bool { !outline.isHidden }

    func setFilesVisible(_ visible: Bool) {
        files.isHidden = !visible
        needsLayout = true
    }

    func setOutlineVisible(_ visible: Bool) {
        outline.isHidden = !visible
        needsLayout = true
    }

    /// The dividers straddle the panel edge, so each paints its panel's
    /// background over the grab strip; without it the band beside the hairline
    /// falls through to the window and reads as a gap.
    func apply(theme: EditorTheme) {
        filesDivider.panelBackground = theme.sidebarBackground.nsColor
        filesDivider.panelEdge = .minX
        outlineDivider.panelBackground = theme.background.nsColor
        outlineDivider.panelEdge = .maxX
        filesDivider.needsDisplay = true
        outlineDivider.needsDisplay = true
    }

    /// Keeps one panel between its minimum and whatever the editor floor allows.
    ///
    /// `other` is the width the opposite panel currently holds: with both panels
    /// open each one shrinks so the editor never drops below `editorFloor`, which
    /// is what a drag past the floor should do - stop, not squeeze the editor to
    /// nothing and lose the trailing divider off-screen.
    private func clampedWidth(_ proposed: CGFloat, other: CGFloat) -> CGFloat {
        let ceiling = bounds.width - Self.editorFloor - other - Self.dividerWidth * 2
        return min(
            max(proposed, Self.minimumPanelWidth),
            max(Self.minimumPanelWidth, ceiling)
        )
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        positionTitle(in: bounds)
        let panelCount = CGFloat((isFilesVisible ? 1 : 0) + (isOutlineVisible ? 1 : 0))
        guard panelCount > 0 else {
            filesDivider.isHidden = true
            outlineDivider.isHidden = true
            editor.frame = bounds
            return
        }
        var left = CGFloat(0)
        if isFilesVisible {
            let width = min(
                filesWidth,
                max(Self.minimumPanelWidth, bounds.width - Self.editorFloor - Self.dividerWidth)
            )
            files.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            filesDivider.isHidden = false
            filesDivider.frame = NSRect(
                x: width, y: 0, width: Self.dividerWidth, height: bounds.height
            )
            left = width + Self.dividerWidth
        } else {
            filesDivider.isHidden = true
        }
        var right = bounds.width
        if isOutlineVisible {
            let width = min(
                outlineWidth,
                max(Self.minimumPanelWidth, bounds.width - Self.editorFloor - Self.dividerWidth)
            )
            outline.frame = NSRect(x: right - width, y: 0, width: width, height: bounds.height)
            outlineDivider.isHidden = false
            outlineDivider.frame = NSRect(
                x: right - width - Self.dividerWidth, y: 0,
                width: Self.dividerWidth, height: bounds.height
            )
            right -= width + Self.dividerWidth
        } else {
            outlineDivider.isHidden = true
        }
        editor.frame = NSRect(x: left, y: 0, width: max(0, right - left), height: bounds.height)
    }

    /// The original's sidebar is 220pt out of the box, and resizes by dragging the rule.
    private static let preferredWidth: CGFloat = 220
    private static let minimumPanelWidth: CGFloat = 150
    private static let editorFloor: CGFloat = 340
    /// The grab area: a one-point target is a coin toss with a trackpad, so the
    /// view is wider than the hairline it draws.
    private static let dividerWidth: CGFloat = 5

    /// Sits centred in the strip the traffic lights occupy, which is always the
    /// editor's span: the side panels dock to the edges, never the middle.
    private func positionTitle(in bounds: NSRect) {
        titleLabel.frame = NSRect(x: 0, y: bounds.height - 30, width: bounds.width, height: 22)
    }

    func setTitleText(_ text: String) {
        titleLabel.stringValue = text
    }
}

/// The hairline between a panel and the editor.
///
/// Dragging reports to the root view, which owns the widths; the line itself is
/// drawn a point wide over the wider grab area.
private final class PanelDivider: NSView {
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

/// The document shown on first launch.
enum SampleDocument {
    static let text = """
        ---
        title: Inkstone
        ---

        # the original

        A native Markdown editor. Everything on screen is rendered by AppKit -
        there is no web view anywhere in this app.

        ## What it does

        Type Markdown and watch it render **in place**. Put the caret inside an
        emphasised run and its `**` markers appear again, exactly where they were.

        - Syntax markers are hidden by *zero-width glyphs*, not by rewriting text
        - The buffer is the Markdown, byte for byte
        - Saving writes what you typed

        ### Tasks

        - [x] Parser round-trips 565 real files byte for byte
        - [ ] Outline panel
        - [ ] Export

        ### Code

        ```swift
        let document = BlockParser.parse(markdown)
        for block in document.blocks {
            render(block)
        }
        ```

        ### Table

        | Feature | State | Notes |
        |---|---|---|
        | Parser | done | 1.95 MB corpus, byte identical |
        | Renderer | partial | TextKit 1, zero-width markers |
        | Sidebar | next | |

        > Blockquotes keep their bar, and reveal their `>` markers on focus.

        Math comes later:

        $$
        \\int_0^1 x^2 \\, dx = \\tfrac{1}{3}
        $$

        Links work: [Inkstone](https://example.org) and <https://example.com>.
        """
}
