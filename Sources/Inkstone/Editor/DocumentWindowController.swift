import AppKit
import Foundation
import UniformTypeIdentifiers

/// The preferences a document mirrors.
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
        // so the first heading is not clipped. Inside a host tab there is no
        // title bar of its own, so the inset is just the theme's padding.
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

/// One open document: its buffer, editor, outline and draft bookkeeping.
///
/// A document no longer owns a window - it is mounted as a tab inside an
/// `EditorWindowController`, which owns the window, the title strip and the
/// window-global Files panel. Everything here is the document's own content.
@MainActor
final class DocumentWindowController {
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
    /// Outline docked right of the editor; the Files panel is the host's.
    private let outlinePanel: OutlineViewController
    private let findController = FindReplaceController()
    private var findVisible = false
    private let environment: EditorEnvironment
    /// What a tab shows: the editor with the outline beside it.
    private(set) var documentContent: DocumentContentView

    /// The window hosting this document's tab, set by the host when the tab
    /// is added. Sheets, the find bar and first responder all go here - the
    /// document itself has no window.
    weak var hostWindow: NSWindow?
    /// Fired when the title, file URL or edited state changes, so the host can
    /// refresh the tab label and title strip.
    var onContentChange: (() -> Void)?

    init(
        theme: EditorTheme, markdown: String = SampleDocument.text, url: URL? = nil,
        environment: EditorEnvironment = .live
    ) {
        self.theme = theme
        self.documentURL = url
        self.environment = environment
        editor = MarkdownTextView(theme: theme)
        scrollView = DocumentScrollView(textView: editor, theme: theme)
        outlinePanel = OutlineViewController()
        documentContent = DocumentContentView(editor: scrollView, outline: outlinePanel.view)
        documentContent.apply(theme: theme)

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
        findController.attach(editor: editor)
        findController.onReplace = { [weak self] in
            self?.markDirty()
        }
        findController.onClose = { [weak self] in
            self?.findVisible = false
        }
        // The outline and the word count come from `updateStatus`; a fresh
        // document never edits anything, so without this the sidebar would sit
        // at "No headings · 0 words" until the first keystroke.
        updateStatus()
    }

    @available(*, unavailable)
    convenience init?(coder: NSCoder) {
        fatalError("DocumentWindowController is created in code")
    }

    // MARK: - Files

    var fileURL: URL? { documentURL }

    /// The name the tab label and title strip show.
    var titleText: String { documentURL?.lastPathComponent ?? "Untitled" }

    func open(_ url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        documentURL = url
        editor.load(markdown: text)
        sourceController?.load(markdown: text)
        // A document opened into a scratch tab brings its folder with it: path
        // completion and relative images resolve against it, and neither was
        // bound when the empty tab was created.
        let folder = url.deletingLastPathComponent()
        editor.completionDirectory = folder
        editor.imagePainter.baseDirectory = folder
        isDirty = false
        notifyHost()
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
        notifyHost()
        updateStatus()
    }

    func save() throws {
        guard let documentURL else { return }
        try editor.markdown.write(to: documentURL, atomically: true, encoding: .utf8)
        onSaveCommitted?(documentURL)
        isDirty = false
        autosaveTimer?.invalidate()
        notifyHost()
    }

    func saveAs(_ url: URL) throws {
        try editor.markdown.write(to: url, atomically: true, encoding: .utf8)
        onSaveCommitted?(documentURL)
        documentURL = url
        onSaveCommitted?(url)
        isDirty = false
        autosaveTimer?.invalidate()
        notifyHost()
    }

    /// Autosave interval in seconds; `0` means off.
    var autosaveInterval: TimeInterval = 0
    /// Filled in by `AppStore`: `Editor/` may not reach into `Session/`.
    var onWriteDraft: ((DraftSnapshot) -> Void)?
    var onSaveCommitted: ((URL?) -> Void)?
    /// Set once `AppStore` attaches autosave/draft wiring. Tabs are built on
    /// both the new-document and the file-open paths, so the store funnels
    /// both through one attach point instead of nil-checking the closures.
    private(set) var hasSessionWiring = false
    func markSessionWired() { hasSessionWiring = true }

    private func markDirty() {
        isDirty = true
        notifyHost()
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

    /// Tells the host to refresh the tab label, title strip and edited dot.
    ///
    /// The original centred the bare file name in the titlebar, and the edited
    /// state lives in the close button rather than in a suffix; the system title
    /// stays set for Mission Control and accessibility.
    private func notifyHost() {
        hostWindow?.title = titleText
        hostWindow?.isDocumentEdited = isDirty
        onContentChange?()
    }

    /// Tears down tab state; called when the tab is closed.
    func close() {
        autosaveTimer?.invalidate()
        autosizeTimer?.invalidate()
        // A closing tab must not leave its find bar floating in the host window.
        if findVisible { findController.hide() }
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

    /// Slides the find bar down from the top of the host window, as the original does.
    @objc func toggleFind(_ sender: Any?) {
        findVisible.toggle()
        if findVisible, let hostWindow {
            findController.present(in: hostWindow)
        } else {
            findController.dismiss()
        }
    }

    /// Hides the bar but remembers the toggle, so a tab switch never leaks one
    /// document's bar into another tab.
    func suspendFindBar() {
        findController.hide()
    }

    /// Re-shows this document's bar after a tab switch, without moving focus.
    func restoreFindBarIfNeeded() {
        guard findVisible, let hostWindow else { return }
        findController.show(in: hostWindow)
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
    var isOutlineVisible: Bool { documentContent.isOutlineVisible }

    /// Toggles source mode and keeps the two views in step.
    ///
    /// Source mode mounts over the tab's content; the markdown comes from the
    /// node tree, so attachment-rendered blocks show their real source rather
    /// than the `U+FFFC` the buffer holds for them.
    @objc func toggleSourceMode(_ sender: Any?) {
        let result = sourceController?.toggle(
            in: documentContent, markdown: editor.markdown, parseOptions: parseOptions
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
        scrollView.apply(theme: theme)
        editor.apply(theme: theme)
        sourceController?.apply(theme: theme)
        outlinePanel.apply(theme: theme)
        documentContent.apply(theme: theme)
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
        editor.needsDisplay = true
        updateStatus()
    }

    // MARK: - Panels

    /// Outline is per-document; the Files panel belongs to the window, so
    /// "Sidebar" drives both through the host and here together.
    @objc func toggleOutline(_ sender: Any?) {
        documentContent.setOutlineVisible(!isOutlineVisible)
        editor.markDirty()
    }

    func setOutlineVisible(_ visible: Bool) {
        guard visible != isOutlineVisible else { return }
        documentContent.setOutlineVisible(visible)
        editor.markDirty()
    }

    /// Re-parses the document when a Markdown syntax preference changes, so an
    /// open tab follows the setting instead of waiting for a reopen.
    func applyParseOptions(_ options: BlockParser.Options) {
        parseOptions = options
        editor.load(markdown: editor.markdown)
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

/// What a document tells the session layer about its unsaved content.
struct DraftSnapshot {
    var sourceURL: URL?
    var title: String
    var markdown: String
    var savedAt: Date
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
