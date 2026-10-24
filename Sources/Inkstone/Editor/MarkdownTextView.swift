import AppKit
import Foundation

/// The document surface.
///
/// A `NSTextView` on a TextKit 1 stack (`NSTextStorage` + `NSLayoutManager` +
/// `NSTextContainer`) because TextKit 1 is the only pipeline with the glyph-level
/// hook `MarkerHider` needs. Everything else - editing, selection, undo, IME,
/// drag and drop, spell checking, accessibility - comes from AppKit rather than
/// being reimplemented.
///
/// ## What this class owns
///
///   * incremental re-parsing: only the block under the caret is re-parsed, and
///     only when its block structure actually changed;
///   * refocus: recomputing which markers are visible when the caret moves;
///   * caret clamping: keeping the caret out of zero-width marker runs;
///   * `typingAttributes`: recomputed from the node tree so text typed on a
///     collapsed line is not invisible.
@MainActor
final class MarkdownTextView: NSTextView {
    /// The node tree for the current buffer contents.
    private(set) var document = MarkdownDocument(blocks: [])
    /// The result of the last layout pass.
    private(set) var layout = LayoutOutput(attributed: NSAttributedString())
    private(set) var theme: EditorTheme
    private let hider = MarkerHider()
    /// Read access for the decoration layer: the heading rule hangs off the
    /// engine's baseline, which only this delegate captured (`MarkerHider
    /// .baselines`).
    var markerHider: MarkerHider { hider }
    /// Incremental-reparse state.
    var focusedBlockID: Int?
    private var reparseTimer: Timer?

    @MainActor deinit {
        reparseTimer?.invalidate()
    }
    private var isReplacingForReparse = false
    /// Set while the caret is inside a collapsed run, so the clamp can be skipped
    /// once and not fight the user's own navigation.
    private var lastClampedLocation: Int?
    /// True while the text storage is being replaced. See `rebuildLayout`.
    private var isMutatingStorage = false
    /// Focus mode dims everything outside the focused block.
    var isFocusModeEnabled = false
    var isReadonly = false {
        didSet { updateEditability() }
    }
    /// Typewriter mode: hold the caret line at the vertical centre of the viewport.
    var keepsCaretInMiddle = false
    /// Keystroke rewriting, pushed in from the settings store.
    var inputOptions = InputOptions()
    /// Loads and draws inline images. Set up by the window so a relative path can
    /// resolve against the document's folder.
    let imagePainter = InlineImagePainter()
    /// Draws spaces and tabs, for the people who cannot see them.
    ///
    /// A `NSLayoutManagerDelegate` cannot do this: glyph generation only runs when the
    /// attributes change, so it is expressed as a foreground colour on whitespace
    /// instead - the same reason the marker reveal works without touching the buffer.
    var showsInvisibleCharacters = false {
        didSet { applyInvisibleCharacterVisibility() }
    }
    /// Called after any change that should mark the document dirty.
    var onTextChange: ((String) -> Void)?

    init(theme: EditorTheme) {
        self.theme = theme
        hider.listItemSpacing = theme.listItemSpacing
        hider.quoteLevelSpacing = theme.blockMargin
        hider.quoteParagraphSpacing = theme.blockMargin
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 800, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.delegate = hider
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        // Layer backing has to be off. With it on, TextKit 1's layout manager draws the
        // glyphs into the layer *after* `draw(_:)` returns, which erases everything
        // `BlockDecorator` painted - no bullet, rule, checkbox or code-block chrome was
        // ever visible. See DESIGN.md §6: decorations are drawn from `draw(_:)`.
        wantsLayer = false
        isRichText = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        allowsUndo = true
        isIncrementalSearchingEnabled = false
        usesFindBar = false
        // Transparent on purpose: block backgrounds are painted by `BlockDecorator`
        // from `draw(_:)`, *before* `super.draw`, so they sit under the glyphs. An
        // opaque background here would erase them.
        backgroundColor = .clear
        insertionPointColor = EditorColor.caret.nsColor
        selectedTextAttributes = [
            .backgroundColor: theme.selection.nsColor,
            .foregroundColor: theme.text.nsColor,
        ]
        textContainerInset = NSSize(
            width: theme.contentPadding, height: theme.contentPadding / 2
        )
        delegate = self
        setAccessibilityLabel("Markdown Editor — Live preview with syntax highlighting and focus mode")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MarkdownTextView is created in code")
    }

    // MARK: - Loading

    /// The parse options the live view re-parses with. Pushed in from the
    /// document so the Markdown preference pane (strict mode, inline maths,
    /// highlight, sub/superscript, …) governs rendering instead of being
    /// silently ignored.
    var parseOptions = BlockParser.Options.standard

    /// Replaces the whole document. Used on open, not while editing.
    func load(markdown text: String) {
        let parsed = BlockParser.parse(text, options: parseOptions)
        document = parsed
        rebuildLayout(replacingSelection: true)
    }

    /// The markdown to save: the buffer's text with attachment-rendered blocks
    /// materialised from the node tree. For phase 1 the buffer is the whole
    /// document, so this is the text verbatim.
    var markdown: String { document.source }

    /// The buffer range of a block, or `nil` when the block has no text (an
    /// attachment-rendered block occupies a single character instead).
    ///
    /// This is the only bridge between node-relative and buffer-relative offsets,
    /// and it is deliberately one-way: the outline needs to place a caret, it never
    /// needs to translate an edit.
    func bufferRange(forBlock id: Int) -> NSRange? {
        guard let block = layout.blocks.first(where: { $0.id == id }) else { return nil }
        return block.range
    }

    /// Readonly is enforced on the view rather than by refusing keystrokes, so the
    /// text stays selectable and every read path keeps working.
    private func updateEditability() {
        isEditable = !isReadonly
        isSelectable = true
    }

    /// Scrolls the caret's line to the middle of the visible rect.
    ///
    /// Driven by the selection rather than by typing, so it also follows a click, and
    /// skipped while the user is scrolling by hand - yanking the viewport back on every
    /// scroll event would make the document impossible to read.
    func centerCaretIfNeeded() {
        guard keepsCaretInMiddle, let layoutManager, let scrollView = enclosingScrollView
        else { return }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: selectedRange(), actualCharacterRange: nil
        )
        var rect = NSRect.zero
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { line, _, _, _, stop in
            rect = line
            stop.pointee = true
        }
        guard rect.height > 0 else { return }
        let visible = scrollView.contentView.bounds
        let target = visible.midY - rect.height / 2
        if abs(rect.midY - visible.midY) > 1 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Scrolls the given range to the top of the viewport with a short eased
    /// animation, instead of the default jump. Outline navigation uses this so
    /// moving between sections keeps the reader oriented.
    func smoothScrollRangeToVisible(_ range: NSRange) {
        guard let scrollView = enclosingScrollView, let layoutManager,
            let container = textContainer
        else {
            scrollRangeToVisible(range)
            return
        }
        // A far-away heading may live in text that is not laid out yet; measure
        // only after forcing the layout for its range.
        layoutManager.ensureLayout(forCharacterRange: range)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil
        )
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard lineRect.height > 0 else {
            scrollRangeToVisible(range)
            return
        }
        // Container coordinates -> view coordinates: a viewport-tall rect whose
        // top edge is the heading's first line leaves the scroller exactly one
        // legal position, the heading pinned at the top. AppKit clamps near the
        // document end, where the pin cannot be honoured.
        let top = lineRect.minY + textContainerOrigin.y
        let viewport = scrollView.contentView.bounds.height
        let pinRect = NSRect(x: 0, y: top, width: 1, height: viewport)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            scrollToVisible(pinRect)
        }
    }

    /// Forces a re-layout pass. Needed after the sidebar changes the measure.
    func markDirty() {
        rebuildLayout(replacingSelection: false)
    }

    /// The selected markdown, used by the status bar for the "n of m words" count.
    /// Read straight from the text storage rather than the node tree: the selection
    /// is a buffer range, and inside a hidden marker run the two disagree.
    var selectedText: String {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return "" }
        let text = storage.string as NSString
        return text.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: text.length)))
    }

    /// Replaces the whole document from a node tree - the path used by
    /// replace-all, which edits the tree and then re-materialises.
    func load(document: MarkdownDocument) {
        self.document = document
        rebuildLayout(replacingSelection: true)
    }

    /// Notifies the rest of the window after the buffer was edited from code, so
    /// the status bar, sidebar and dirty flag see the change.
    func notifyTextChanged() {
        onTextChange?(textStorage?.string ?? "")
    }

    /// Repaints whitespace in a dimmed colour, leaving every other character alone.
    ///
    /// Colour rather than a glyph substitution on purpose: TextKit only regenerates
    /// glyphs when the attributes on a range change, so an attribute is both the cheap
    /// mechanism and the only one that stays in step with the zero-width markers.
    func applyInvisibleCharacterVisibility() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let hidden = MarkdownAttribute.hidden
        let dim = EditorColor.marker.nsColor.withAlphaComponent(0.35)
        storage.beginEditing()
        var location = 0
        while location < storage.length {
            let scalar = (storage.string as NSString).character(at: location)
            let isSpace = scalar == 32 || scalar == 9
            let length = 1
            if showsInvisibleCharacters, isSpace,
                storage.attribute(hidden, at: location, effectiveRange: nil) as? Bool != true
            {
                storage.addAttribute(.foregroundColor, value: dim, range: NSRange(location: location, length: length))
            } else if storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor == dim {
                // Undo only our own tint, never the theme colour underneath it.
                storage.addAttribute(
                    .foregroundColor, value: theme.text.nsColor,
                    range: NSRange(location: location, length: length)
                )
            }
            location += length
        }
        storage.endEditing()
        refreshVisibleMarkers()
        needsDisplay = true
    }

    override func shouldChangeText(
        in range: NSRange, replacementString text: String?
    ) -> Bool {
        guard let text, !isReplacingForReparse, text != "\n",
            let context = ruleContext(around: range),
            let rule = InputRules.plan(for: text, in: context, options: inputOptions)
        else {
            return super.shouldChangeText(in: range, replacementString: text)
        }
        switch rule {
        case .reject:
            return false
        case let .insert(replacement, caretOffset, deleteBefore):
            // A rule may widen the range backwards to swallow characters it is replacing.
            let target = NSRange(
                location: range.location - deleteBefore, length: range.length + deleteBefore
            )
            let caret = NSRange(
                location: target.location + replacement.utf16.count - caretOffset, length: 0
            )
            // `shouldChangeText` validates and registers undo; it does not edit.
            // The replacement has to be written here and the edit closed with
            // `didChangeText`, then the original keystroke refused - returning true
            // made AppKit perform the *raw* key at the *original* range, so smart
            // dashes, auto-pairing and markdown delimiters never reached the buffer
            // while the undo stack recorded a phantom edit.
            guard super.shouldChangeText(in: target, replacementString: replacement) else {
                return false
            }
            textStorage?.replaceCharacters(in: target, with: replacement)
            didChangeText()
            setSelectedRange(caret, affinity: .downstream, stillSelecting: false)
            return false
        }
    }

    /// The text around the caret, as the rules need to see it.
    private func ruleContext(around range: NSRange) -> RuleContext? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let location = max(0, min(range.location, storage.length - 1))
        let ns = storage.string as NSString
        var lineStart = location
        while lineStart > 0 && ns.character(at: lineStart - 1) != 10 { lineStart -= 1 }
        var lineEnd = NSMaxRange(range)
        while lineEnd < storage.length && ns.character(at: lineEnd) != 10 { lineEnd += 1 }
        let after = min(lineEnd, storage.length)
        return RuleContext(
            lineBefore: ns.substring(with: NSRange(location: lineStart, length: location - lineStart)),
            lineAfter: ns.substring(
                with: NSRange(location: NSMaxRange(range), length: after - NSMaxRange(range))
            ),
            selection: range.length > 0
                ? ns.substring(with: NSRange(location: range.location, length: range.length))
                : ""
        )
    }

    // MARK: - Completion

    private lazy var completionController: CompletionController = {
        let controller = CompletionController()
        controller.onAccept = { [weak self] item, range in
            self?.applyCompletion(item, replacing: range)
        }
        return controller
    }()

    /// Directory paths are completed against, set by the window.
    var completionDirectory: URL?

    override func keyDown(with event: NSEvent) {
        if completionController.handle(event) { return }
        super.keyDown(with: event)
        refreshCompletion()
    }

    private func refreshCompletion() {
        guard let storage = textStorage, storage.length > 0 else {
            completionController.hide()
            return
        }
        let caret = min(selectedRange().location, storage.length - 1)
        let ns = storage.string as NSString

        // Emoji: a run of shortcode characters directly before the caret.
        var start = caret
        while start > 0, isShortcodeCharacter(ns.character(at: start - 1)) { start -= 1 }
        // `start > 0` is what keeps `character(at: -1)` off the wire: with the caret
        // inside an all-alphanumeric run from the buffer's very start, the scan ends
        // at 0 and reading "the character before the run" raised NSRangeException -
        // a crash on the first word of any plain-text document.
        if start > 0, start < caret, ns.character(at: start - 1) == colonCode {
            let query = ns.substring(
                with: NSRange(location: start, length: caret - start)
            )
            let items = CompletionSource.emoji(matching: query)
            let range = NSRange(location: start - 1, length: caret - start + 1)
            completionController.update(items: items, for: range, in: self, theme: theme)
            return
        }

        // Paths: only inside a link or image destination, where a `/` was just typed.
        if ns.character(at: caret) == slashCode
            || (caret > 0 && ns.character(at: caret - 1) == slashCode)
        {
            var pathStart = caret
            while pathStart > 0 {
                let character = ns.character(at: pathStart - 1)
                if character == 10 || character == 40 || character == 32 { break }
                pathStart -= 1
            }
            let query = ns.substring(
                with: NSRange(location: pathStart, length: caret - pathStart)
            )
            // The token must open with `](` - the walk above stops at `(`, so the
            // two characters before it identify a link destination. Anything else is
            // prose with a slash in it, and prose gets no file listing.
            guard
                pathStart >= 2,
                ns.character(at: pathStart - 1) == 40,
                ns.character(at: pathStart - 2) == 93
            else {
                completionController.hide()
                return
            }
            let items = CompletionSource.paths(
                matching: query, in: completionDirectory
            )
            let range = NSRange(location: pathStart, length: caret - pathStart)
            completionController.update(items: items, for: range, in: self, theme: theme)
            return
        }
        completionController.hide()
    }

    private let colonCode: unichar = 58
    private let slashCode: unichar = 47

    private func isShortcodeCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        // `_` separates words in a shortcode, and only ASCII counts: the catalogue is
        // ASCII, so a non-ASCII letter ends the run rather than being searched for.
        if character == 95 { return true }
        return character < 128 && CharacterSet.alphanumerics.contains(scalar)
    }

    private func applyCompletion(_ item: Completion, replacing range: NSRange) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        let inserted = item.insert + item.suffix
        // Through the standard editing path: `shouldChangeText` registers undo,
        // `didChangeText` closes the group and fires `textDidChange`, which is what
        // schedules the reparse. The previous direct-storage write was invisible to
        // undo and left the node tree stale until the next keystroke.
        guard super.shouldChangeText(in: range, replacementString: inserted) else { return }
        storage.replaceCharacters(in: range, with: inserted)
        didChangeText()
        let caret = range.location + inserted.utf16.count
        setSelectedRange(
            NSRange(location: caret, length: 0), affinity: .downstream, stillSelecting: false
        )
    }

    override func insertTab(_ sender: Any?) {
        applyIndent(outdent: false)
    }

    override func insertBacktab(_ sender: Any?) {
        applyIndent(outdent: true)
    }

    /// Rewrites the indentation of every line the selection touches.
    ///
    /// The lines are collected first and rewritten in one replacement, so a multi-line
    /// indent cannot land as a series of separate undo steps or leave the selection
    /// stranded in the middle of the document.
    private func applyIndent(outdent: Bool) {
        guard let storage = textStorage, storage.length > 0 else {
            super.insertTab(nil)
            return
        }
        let ns = storage.string as NSString
        let selection = selectedRange()
        let selectionStart = min(selection.location, storage.length)
        let selectionEnd = min(NSMaxRange(selection), storage.length)

        var lineStart = selectionStart
        while lineStart > 0 && ns.character(at: lineStart - 1) != 10 { lineStart -= 1 }
        var lineEnd = selectionEnd
        while lineEnd < storage.length && ns.character(at: lineEnd) != 10 { lineEnd += 1 }

        var ranges: [NSRange] = []
        var offset = lineStart
        while true {
            var end = offset
            while end < storage.length && ns.character(at: end) != 10 { end += 1 }
            ranges.append(NSRange(location: offset, length: end - offset))
            if end >= lineEnd { break }
            offset = end + 1
        }
        let isMultiline = ranges.count > 1

        var rewritten = ""
        for range in ranges {
            let line = ns.substring(with: range)
            switch InputRules.indent(
                outdent: outdent, line: line,
                caretColumnInLine: selectionStart - range.location,
                selectionIsMultiline: isMultiline,
                insideCodeBlock: isInsideCodeBlock(at: range.location), options: inputOptions
            ) {
            case let .replaceCurrentLine(text):
                rewritten += text
            case .insert, .none:
                rewritten += line
            }
            rewritten += "\n"
        }
        if rewritten.hasSuffix("\n") { rewritten.removeLast() }

        let target = NSRange(location: ranges[0].location, length: lineEnd - lineStart)
        // `shouldChangeText` validates and registers undo; the rewrite itself has to
        // be performed here and closed with `didChangeText` - the old code computed
        // the replacement and threw it away, so Tab and Shift-Tab did nothing.
        guard super.shouldChangeText(in: target, replacementString: rewritten) else { return }
        textStorage?.replaceCharacters(in: target, with: rewritten)
        didChangeText()
        setSelectedRange(
            NSRange(location: target.location + rewritten.utf16.count, length: 0),
            affinity: .downstream, stillSelecting: false
        )
    }

    private func isInsideCodeBlock(at location: Int) -> Bool {
        layout.block(containing: location).map {
            $0.kind == .fences || $0.kind == .indentedCode
        } ?? false
    }

    /// Return carries the line's block prefix down, and an empty item leaves the list.
    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage, storage.length > 0 else {
            super.insertNewline(sender)
            return
        }
        let ns = storage.string as NSString
        var start = min(selectedRange().location, storage.length)
        while start > 0 && ns.character(at: start - 1) != 10 { start -= 1 }
        let end = min(NSMaxRange(selectedRange()), storage.length)
        let line = ns.substring(with: NSRange(location: start, length: end - start))

        switch InputRules.continuation(forLine: line) {
        case let .prefix(prefix):
            super.insertNewline(sender)
            insertBlockPrefix(prefix)
        case let .exit(indent):
            // An empty item ends the list: drop the marker rather than carry it down.
            // Through the standard path, so the deletion is undoable - a direct
            // storage write made ⌘Z restore the newline but not the marker.
            let markerRange = NSRange(location: start, length: end - start)
            if super.shouldChangeText(in: markerRange, replacementString: "") {
                storage.replaceCharacters(in: markerRange, with: "")
                didChangeText()
            }
            super.insertNewline(sender)
            if !indent.isEmpty { insertBlockPrefix(indent) }
        case .none:
            super.insertNewline(sender)
        }
    }

    private func insertBlockPrefix(_ prefix: String) {
        let caret = selectedRange().location
        insertText(prefix, replacementRange: NSRange(location: caret, length: 0))
        setSelectedRange(
            NSRange(location: caret + prefix.utf16.count, length: 0),
            affinity: .downstream, stillSelecting: false
        )
    }

    var themeDidChange: ((EditorTheme) -> Void)?

    func apply(theme: EditorTheme) {
        self.theme = theme
        hider.listItemSpacing = theme.listItemSpacing
        hider.quoteLevelSpacing = theme.blockMargin
        hider.quoteParagraphSpacing = theme.blockMargin
        // Transparent on purpose: block backgrounds are painted by `BlockDecorator`
        // from `draw(_:)`, *before* `super.draw`, so they sit under the glyphs. An
        // opaque background here would erase them.
        backgroundColor = .clear
        insertionPointColor = EditorColor.caret.nsColor
        selectedTextAttributes = [
            .backgroundColor: theme.selection.nsColor,
            .foregroundColor: theme.text.nsColor,
        ]
        textContainerInset = NSSize(
            width: theme.contentPadding, height: theme.contentPadding / 2
        )
        themeDidChange?(theme)
        rebuildLayout(replacingSelection: false)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Decorations first. `codeBlock` and `tableChrome` fill the whole line rect
        // with an opaque colour, so painting them after `super.draw` painted them on
        // top of the glyphs and hid the contents of every code block and table.
        BlockDecorator.draw(in: self, theme: theme, layout: layout)
        super.draw(dirtyRect)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The text container tracks the viewport; a resize changes the measure and
        // therefore the wrapping.
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let measureChanged = abs(newSize.width - frame.width) > 1
        super.setFrameSize(newSize)
        if measureChanged, let container = textContainer {
            let width = theme.contentWidth(for: newSize.width)
            if abs(container.containerSize.width - width) > 0.5 {
                container.containerSize = CGSize(
                    width: width, height: CGFloat.greatestFiniteMagnitude
                )
                rebuildLayout(replacingSelection: false)
            }
        }
    }

    // MARK: - Layout

    /// The measure the content column should use for the current viewport.
    var contentWidth: CGFloat {
        theme.contentWidth(for: bounds.width)
    }

    /// Re-runs the layout pass over the whole document.
    ///
    /// Cheap enough to run on open, on a theme switch, and on resize. Incremental
    /// editing uses `reparseIfNeeded` instead.
    private func rebuildLayout(replacingSelection: Bool) {
        let saved = selectedRange()
        let container = textContainer ?? NSTextContainer()
        container.containerSize = CGSize(
            width: max(contentWidth, 200), height: CGFloat.greatestFiniteMagnitude
        )
        let built = AttributedBuilder(
            theme: theme,
            context: LayoutContext(
                containerWidth: contentWidth,
                imageBaseDirectory: imagePainter.baseDirectory,
                imageSize: { [imagePainter] path in imagePainter.displaySize(of: path) },
                imageMaxWidth: InlineImagePainter.maximumWidth
            )
        ).build(document)
        layout = built

        // TextKit routes `endEditing` through the layout manager, which calls back
        // into `setSelectedRanges` while the storage is mid-replacement: `length`
        // already reports the new value but the backing store is still short, and
        // any attribute query at that point throws NSRangeException. The flag makes
        // the clamping override stand down for the duration.
        isMutatingStorage = true
        textStorage?.beginEditing()
        textStorage?.setAttributedString(built.attributed)
        textStorage?.endEditing()
        isMutatingStorage = false

        if replacingSelection {
            setSelectedRange(clamped(saved, to: built.attributed.length))
        } else {
            setSelectedRangeWithoutClamping(saved)
        }
        MarkerVisibility(storage: textStorage ?? NSTextStorage(), layout: built)
            .apply(for: selectedRange())
        // The storage's edit pass drops the painted rows' attributes on front
        // matter (observed: the builder emits painted+hidden rows, the storage
        // reads neither after the replace) — the source then renders on top of
        // the painted key/value table. Re-assert the built attributes.
        if let storage = textStorage, storage.length == built.attributed.length {
            let whole = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            built.attributed.enumerateAttribute(
                MarkdownAttribute.painted, in: whole, options: []
            ) { value, range, _ in
                guard (value as? Bool) == true else { return }
                if storage.attribute(
                    MarkdownAttribute.painted, at: range.location, effectiveRange: nil
                ) as? Bool != true {
                    storage.addAttributes(
                        built.attributed.attributes(
                            at: range.location, effectiveRange: nil
                        ),
                        range: range
                    )
                }
            }
            storage.endEditing()
        }
        needsDisplay = true
    }

    // MARK: - Incremental reparse

    private func block(containing location: Int) -> BlockRange? {
        layout.block(containing: min(location, max(layout.blocks.last?.range.location ?? 0, 0)))
    }

    /// Re-parses only the focused block, and only rebuilds when its block
    /// structure changed.
    ///
    /// The original calls this `simpleParse`: a paragraph that still reads as a plain
    /// paragraph is left alone entirely, and a re-parse that produces exactly one
    /// paragraph is discarded, so ordinary typing never triggers a relayout.
    func reparseIfNeeded() {
        guard !isReplacingForReparse, textStorage != nil else { return }
        let caret = selectedRange().location
        guard let range = block(containing: caret) else { return }
        let node = document.blocks.first { $0.id == range.id }
        let blockNode = node ?? firstDescendant(id: range.id)
        guard let blockNode else { return }

        let text = ((textStorage?.string ?? "") as NSString)
            .substring(with: clampToStorage(range.range))
        let parsed = BlockParser.parse(text, options: parseOptions)
        let before = signature(of: blockNode)
        let after = parsed.blocks.map { $0.kind }
        guard before != after else {
            // Structure unchanged: nothing to rebuild.
            return
        }
        // Re-parsing produced a different block sequence for this block.
        //
        // The buffer is the source, so re-parsing changes no characters: a paragraph
        // that has become a list still occupies the same range, with the `- ` turned
        // into a hidden marker and a drawn bullet. That is what makes `anchor` - the
        // block's start *before* the rebuild - still a valid offset *after* it, and
        // therefore the basis for putting the caret back.
        let anchor = range.range.location
        let offsetInBlock = max(0, caret - anchor)
        document = BlockParser.parse(textStorage?.string ?? "", options: parseOptions)
        rebuildLayout(replacingSelection: false)
        restoreCaret(anchoredAt: anchor, offsetInBlock: offsetInBlock)
    }

    private func clampToStorage(_ range: NSRange) -> NSRange {
        guard let storage = textStorage else { return range }
        let location = max(0, min(range.location, storage.length))
        let length = max(0, min(range.length, storage.length - location))
        return NSRange(location: location, length: length)
    }

    private func firstDescendant(id: Int) -> BlockNode? {
        var found: BlockNode?
        document.blocks.forEachNode { node in
            if node.id == id { found = node }
        }
        return found
    }

    /// Block kinds only - comparing full attributes would relayout on every
    /// keystroke.
    private func signature(of node: BlockNode) -> [BlockKind] {
        var kinds: [BlockKind] = []
        node.forEachNode { kinds.append($0.kind) }
        return kinds
    }

    /// Places the caret where the block-structure change implies, using the block
    /// index and the offset within the block rather than a proportional guess.
    /// Puts the caret back where it was, relative to its block.
    ///
    /// Absolute buffer offsets do not survive the rebuild: a block that splits into
    /// several (or is re-classified) gets a different extent, so the same absolute
    /// position now points somewhere else in the paragraph. Anchoring to the block
    /// start and the offset within it is the only mapping that survives, and it is
    /// what makes typing `- ` at the start of a line leave the caret after the
    /// bullet instead of throwing it to the end of the document.
    private func restoreCaret(anchoredAt anchor: Int, offsetInBlock: Int) {
        let length = textStorage?.length ?? 0
        guard length > 0 else { return }
        let target = layout.block(containing: min(anchor, length - 1))?.range.location ?? anchor
        let location = max(0, min(target + offsetInBlock, length))
        setSelectedRangeWithoutClamping(NSRange(location: location, length: 0))
    }

    // MARK: - Focus and marker visibility

    /// Recomputes which markers are visible and which block is focused.
    ///
    /// This is the editor's `refocus`. The reveal is an attribute flip, so no text
    /// changes and undo stays clean.
    func refocus() {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        let visibility = MarkerVisibility(storage: storage, layout: layout)
        let changed = visibility.apply(for: range)
        focusedBlockID = block(containing: range.location)?.id
        revealPaintedBlock(containing: range)
        for invalidated in changed {
            layoutManager?.invalidateDisplay(forCharacterRange: invalidated)
        }
        updateTypingAttributes(for: range)
        needsDisplay = true
    }

    /// Brings a painted block's own source text back while the caret is inside it.
    ///
    /// Tables are painted rather than typeset, so their characters are zero width; a
    /// caret in one would have nothing to sit between and typing would go into a
    /// collapsed range. Unhiding is an attribute change on the storage - no text is
    /// touched, so the caret stays put and nothing enters the undo stack.
    ///
    /// The loop keys off the attribute being *present*, not on it currently reading
    /// `true`: a block the caret just left reads `false`, and requiring `true` would
    /// skip it and leave the table showing its pipes forever. Absent means the builder
    /// never painted this block at all, and those are left alone.
    private func revealPaintedBlock(containing range: NSRange) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let focus = block(containing: min(range.location, storage.length - 1))?.id
        storage.beginEditing()
        for candidate in layout.blocks {
            let probe = min(candidate.range.location, storage.length - 1)
            guard
                storage.attribute(
                    MarkdownAttribute.painted, at: probe, effectiveRange: nil
                ) != nil
            else { continue }
            let start = min(candidate.range.location, storage.length)
            let length = max(0, min(candidate.range.length, storage.length - start))
            guard length > 0 else { continue }
            let isPaintedNow = candidate.id != focus
            // Never hide a newline: a `.null` newline is skipped by the layout manager,
            // so hiding the separators would collapse every row onto a single line.
            let blockRange = NSRange(location: start, length: length)
            let spans = newlineFreeSpans(of: blockRange, in: storage)
            // Only when the block crosses the focus line: rewriting a paragraph style
            // re-shapes the whole range, which on every caret move would relayout the
            // table constantly for an identical result.
            let wasPainted =
                storage.attribute(
                    MarkdownAttribute.painted, at: probe, effectiveRange: nil
                ) as? Bool
            let styles =
                wasPainted == isPaintedNow
                ? nil : paragraphStyles(for: candidate.id, rows: spans.count, revealed: !isPaintedNow)
            for span in spans {
                storage.addAttribute(MarkdownAttribute.painted, value: isPaintedNow, range: span)
                storage.addAttribute(MarkdownAttribute.hidden, value: isPaintedNow, range: span)
            }
            guard let styles else { continue }
            for index in spans.indices where index < styles.count {
                storage.addAttribute(.paragraphStyle, value: styles[index], range: spans[index])
            }
            // A line is as tall as the style at its first character, and for every row
            // after the first that character is the terminator of the row above. Leaving
            // the newlines on the painted style would keep each row at the height it
            // had before the caret arrived.
            let ns = storage.string as NSString
            for index in spans.indices where index + 1 < spans.count {
                let at = NSMaxRange(spans[index])
                guard at < storage.length, ns.character(at: at) == 10 else { continue }
                guard index + 1 < styles.count else { continue }
                storage.addAttribute(
                    .paragraphStyle, value: styles[index + 1], range: NSRange(location: at, length: 1)
                )
            }
        }
        storage.endEditing()
    }

    /// Paragraph styles for the buffer's rows of a painted block, or `nil`
    /// when the block is not one.
    private func paragraphStyles(
        for blockID: Int, rows: Int, revealed: Bool
    ) -> [NSParagraphStyle]? {
        guard let plans = layout.decorations[blockID] else { return nil }
        var grid: TableGrid?
        var front: FrontMatterLayout?
        for plan in plans {
            if case let .tableGrid(found) = plan { grid = found }
            if case let .frontMatterTable(found) = plan { front = found }
        }
        if let grid {
            return (0..<rows).map { index in
                grid.paragraphStyle(
                    forSourceRow: index, revealed: revealed,
                    spacing: index == 0 ? theme.blockMargin : 0
                )
            }
        }
        if let front {
            return (0..<rows).map { index in
                front.paragraphStyle(
                    forSourceRow: index, revealed: revealed,
                    spacing: index == 0 ? theme.blockMargin : 0
                )
            }
        }
        // A table of contents paints `count` rows into one source line; the
        // revealed source is one ordinary line again.
        for plan in plans {
            if case let .tocEntries(entries) = plan {
                let rowHeight = theme.bodyLineHeight * theme.bodyFontSize
                return (0..<rows).map { _ in
                    NSParagraphStyle.markdownBody(
                        lineHeight: revealed ? rowHeight : rowHeight * CGFloat(max(entries.count, 1)),
                        spacing: theme.blockMargin
                    )
                }
            }
        }
        return nil
    }

    /// Splits a range into the sub-ranges that contain no newline.
    private func newlineFreeSpans(of range: NSRange, in storage: NSTextStorage) -> [NSRange] {
        let ns = storage.string as NSString
        var spans: [NSRange] = []
        var cursor = range.location
        let end = NSMaxRange(range)
        while cursor < end {
            let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
            // `NSMaxRange(lineRange)` includes the newline, so step back over it.
            var lineEnd = min(NSMaxRange(line), end)
            if lineEnd > cursor && ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
            if lineEnd > cursor { spans.append(NSRange(location: cursor, length: lineEnd - cursor)) }
            // Step past the newline itself.
            var next = lineEnd
            while next < end && ns.character(at: next) == 10 { next += 1 }
            cursor = max(next, cursor + 1)
        }
        return spans
    }

    /// `typingAttributes` is global, so inheriting it from a collapsed line would
    /// make newly typed characters invisible. Recompute it from the node tree.
    private func updateTypingAttributes(for range: NSRange) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let location = min(range.location, storage.length - 1)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: EditorFont.nsSystem(size: theme.bodyFontSize),
            .foregroundColor: theme.text.nsColor,
        ]
        // Prefer the attributes of the nearest visible character to the caret.
        var probe = location
        while probe >= 0,
            storage.attribute(
                MarkdownAttribute.hidden, at: probe, effectiveRange: nil
            ) as? Bool == true
        {
            probe -= 1
        }
        if probe >= 0, probe < storage.length {
            attributes = storage.attributes(at: probe, effectiveRange: nil)
        }
        attributes.removeValue(forKey: MarkdownAttribute.marker)
        attributes.removeValue(forKey: MarkdownAttribute.hidden)
        attributes.removeValue(forKey: MarkdownAttribute.block)
        attributes.removeValue(forKey: MarkdownAttribute.blockKind)
        attributes.removeValue(forKey: MarkdownAttribute.blockDepth)
        attributes.removeValue(forKey: MarkdownAttribute.rawBlock)
        typingAttributes = attributes
    }

    // MARK: - Caret clamping

    /// Keeps the caret out of zero-width marker runs.
    ///
    /// Inside a collapsed run every character shares one x position, so a caret
    /// there is invisible and typing would split the delimiters. The left edge has
    /// to be handled as well: TextKit treats a position at the start of a collapsed
    /// run as invalid for a leftward move and jumps to the document start.
    func clampedSelection(_ range: NSRange) -> NSRange {
        guard let storage = textStorage, storage.length > 0 else { return range }
        guard range.length == 0 else {
            // A selection may legitimately span markers; only the ends matter.
            return range
        }
        // `at:` is bounds-checked by throwing, not by trapping, so the index has to
        // be validated here even though `storage.length` was just consulted.
        guard range.location >= 0, range.location < storage.length else { return range }
        let hiddenKey = MarkdownAttribute.hidden
        guard storage.attribute(hiddenKey, at: range.location, effectiveRange: nil) as? Bool == true
        else {
            lastClampedLocation = nil
            return range
        }
        var effective = NSRange(location: 0, length: 0)
        let flag = storage.attribute(hiddenKey, at: range.location, effectiveRange: &effective)
        guard flag as? Bool == true, NSMaxRange(effective) > range.location else { return range }
        // Jump to the end of the collapsed run.
        let moved = NSRange(location: NSMaxRange(effective), length: 0)
        lastClampedLocation = range.location
        return moved
    }

    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = max(0, min(range.location, length))
        let clampedLength = max(0, min(range.length, length - location))
        return NSRange(location: location, length: clampedLength)
    }

    private func setSelectedRangeWithoutClamping(_ range: NSRange) {
        super.selectedRange = range
    }

    /// The real selection entry point.
    ///
    /// `NSTextView` funnels every caret move - property setter, arrow keys,
    /// `moveWord:`, mouse clicks - through `setSelectedRanges(_:affinity:stillSelecting:)`,
    /// so clamping here covers the cases an override of the two-argument form would
    /// miss. The move is applied silently and then re-entered once, which is what
    /// keeps `clampedSelection` from recursing.
    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        var needsResync = false
        var adjusted: [NSValue] = []
        adjusted.reserveCapacity(ranges.count)
        for value in ranges {
            let range = value.rangeValue
            let safe = clampedSelection(range)
            if safe != range { needsResync = true }
            adjusted.append(NSValue(range: safe))
        }
        super.setSelectedRanges(adjusted, affinity: affinity, stillSelecting: stillSelecting)
        if needsResync {
            super.setSelectedRanges(
                adjusted, affinity: affinity, stillSelecting: stillSelecting
            )
        }
    }

    /// Replaces the selection with the pasteboard's plain text.
    ///
    /// Overridden rather than left to AppKit because the stock implementation also
    /// accepts the pasteboard's RTF/HTML flavours, and those carry attributes this
    /// editor has no meaning for. Reading `.string` keeps a paste into a document
    /// identical to typing the text.
    override func pasteAsPlainText(_ sender: Any?) {
        guard
            let text = NSPasteboard.general.string(forType: .string)
        else { return }
        insertText(text, replacementRange: selectedRange())
    }

    /// Pastes clipboard HTML as Markdown, as the original does.
    ///
    /// The stock `paste:` also accepts the RTF/HTML flavours, and those carry
    /// attributes this editor has no meaning for - fonts and colours that would
    /// sit in a buffer that must stay Markdown source. HTML goes through the
    /// converter; RTF without HTML is reduced to its markers; anything else
    /// falls back to plain text, which is always safe.
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let data = board.data(forType: .html),
            let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
            !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let markdown = HTMLToMarkdown.convert(html)
            if !markdown.isEmpty {
                insertText(markdown, replacementRange: selectedRange())
                return
            }
        }
        if let markdown = markdownFromRichPasteboard(), !markdown.isEmpty {
            insertText(markdown, replacementRange: selectedRange())
            return
        }
        pasteAsPlainText(sender)
    }

    /// Reduces pasted RTF/RTFD to Markdown markers: bold, italic, underline,
    /// strikethrough, monospace and links. Colours, sizes and attachments have
    /// no Markdown form and are dropped; images stay out by design.
    private func markdownFromRichPasteboard() -> String? {
        let board = NSPasteboard.general
        let data =
            board.data(forType: .rtf) ?? board.data(forType: .rtfd)
        guard let data else { return nil }
        guard
            let content = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: board.data(forType: .rtf) != nil
                        ? NSAttributedString.DocumentType.rtf
                        : NSAttributedString.DocumentType.rtfd
                ],
                documentAttributes: nil
            ),
            !content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let ns = content.string as NSString
        // Paragraph ranges first: markers wrap runs, joins split paragraphs.
        var boundaries = [0]
        var cursor = 0
        while cursor < ns.length {
            if ns.character(at: cursor) == 10 { boundaries.append(cursor + 1) }
            cursor += 1
        }
        boundaries.append(ns.length)
        var paragraphs: [String] = []
        for index in 0..<boundaries.count - 1 {
            let range = NSRange(
                location: boundaries[index], length: boundaries[index + 1] - boundaries[index]
            )
            let marked = markedRuns(in: content, range: range)
            let trimmed = marked.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { paragraphs.append(trimmed) }
        }
        guard !paragraphs.isEmpty else { return nil }
        return paragraphs.joined(separator: "\n\n")
    }

    /// One paragraph with its attribute runs wrapped in markers.
    private func markedRuns(in content: NSAttributedString, range: NSRange) -> String {
        var out = ""
        content.enumerateAttributes(in: range, options: []) { attributes, run, _ in
            var text = (content.string as NSString).substring(with: run)
            guard !text.isEmpty else { return }
            if attributes[.attachment] != nil { return }
            var open = ""
            var close = ""
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) {
                    open += "**"
                    close = "**" + close
                }
                if traits.contains(.italic) {
                    open += "*"
                    close = "*" + close
                }
                // A fixed-pitch run pasted from code is code.
                if font.isFixedPitch {
                    open += "`"
                    close = "`" + close
                }
            }
            if let link = attributes[.link] as? URL, !link.absoluteString.isEmpty {
                open += "["
                close = "](\(link.absoluteString))" + close
            } else if let link = attributes[.link] as? String, !link.isEmpty {
                open += "["
                close = "](\(link))" + close
            }
            if (attributes[.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue {
                open += "<u>"
                close = "</u>" + close
            }
            if let strike = attributes[.strikethroughStyle] as? Int,
                strike == NSUnderlineStyle.single.rawValue
                    || strike == NSUnderlineStyle.double.rawValue
                    || strike == NSUnderlineStyle.thick.rawValue
            {
                open += "~~"
                close = "~~" + close
            }
            text = text.replacingOccurrences(of: "\n", with: " ")
            out += open + text + close
        }
        return out
    }

    override func moveWordLeft(_ sender: Any?) {
        super.moveWordLeft(sender)
        setSelectedRange(clampedSelection(selectedRange()))
    }

    override func moveWordRight(_ sender: Any?) {
        super.moveWordRight(sender)
        setSelectedRange(clampedSelection(selectedRange()))
    }

    override func moveToBeginningOfLine(_ sender: Any?) {
        super.moveToBeginningOfLine(sender)
        setSelectedRange(clampedSelection(selectedRange()))
    }

    override func moveToEndOfLine(_ sender: Any?) {
        super.moveToEndOfLine(sender)
        setSelectedRange(clampedSelection(selectedRange()))
    }

    /// Refreshes marker visibility without a full re-layout.
    func refreshVisibleMarkers() {
        refocus()
    }

    // MARK: - Format commands

    /// Applies a formatting rewrite as one undo step.
    ///
    /// The mutation goes through the ordinary text-system path - one
    /// `shouldChangeText`, the replacement written, then `didChangeText` to close
    /// the undo group and fire `textDidChange` - so undo, the dirty flag and the
    /// reparse all behave exactly as they do for typing. `shouldChangeText` alone
    /// validates and registers undo; it never edits, and skipping the write made
    /// every Format command a no-op that still marked the document dirty.
    func apply(_ edit: FormatController.Edit) {
        guard let storage = textStorage, !isReadonly else { return }
        guard NSMaxRange(edit.range) <= storage.length else { return }
        guard edit.range.length > 0 || !edit.text.isEmpty else { return }
        guard super.shouldChangeText(in: edit.range, replacementString: edit.text) else {
            return
        }
        storage.replaceCharacters(in: edit.range, with: edit.text)
        didChangeText()
        setSelectedRange(edit.selection, affinity: .downstream, stillSelecting: false)
    }

    /// Runs a pure formatting rewrite against the whole buffer.
    func format(_ command: (String, NSRange) -> FormatController.Edit) {
        guard let storage = textStorage else { return }
        apply(command(storage.string, selectedRange()))
    }

    /// ⌘[ and ⌘] go where Tab and Shift-Tab go.
    func formatIndent(outdent: Bool) {
        guard !isReadonly else { return }
        applyIndent(outdent: outdent)
    }

    // MARK: - Mouse interaction

    /// Handed to the session layer: a ⌘-clicked relative link, resolved against
    /// the document's folder. `Editor/` may not reach into `Session/`, so the
    /// view never opens these itself.
    var onOpenURL: ((URL) -> Void)?
    /// Buffer offset the context menu was built for; menu actions fire later.
    private var contextMenuLocation = 0
    /// Task block armed by a mouseDown on its checkbox, toggled on mouseUp.
    private var pendingCheckboxBlock: Int?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Caps lock and the fn key ride along in the device-independent flags
        // but change nothing about a click; leaving them in made every
        // single-click affordance silently die under caps lock.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags.contains(.command) {
            if openLink(at: characterIndex(at: point)) { return }
        } else if event.clickCount == 1, flags.isEmpty {
            // A table of contents navigates even in readonly mode; toggling a
            // checkbox is an edit and stays behind the readonly gate.
            if let entry = tocEntryHit(at: point) {
                jumpToTOCEntry(entry)
                return
            }
            if !isReadonly, let blockID = taskCheckboxHit(at: point) {
                pendingCheckboxBlock = blockID
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let blockID = pendingCheckboxBlock {
            pendingCheckboxBlock = nil
            let point = convert(event.locationInWindow, from: nil)
            if taskCheckboxHit(at: point) == blockID {
                toggleTaskCheckbox(blockID)
                return
            }
        }
        super.mouseUp(with: event)
    }

    /// Buffer offset under `point`, clamped into the storage.
    private func characterIndex(at point: NSPoint) -> Int {
        guard let layoutManager, let container = textContainer, let storage = textStorage,
            storage.length > 0
        else { return 0 }
        let inContainer = NSPoint(
            x: point.x - textContainerInset.width, y: point.y - textContainerInset.height
        )
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container)
        return min(layoutManager.characterIndexForGlyph(at: glyph), storage.length - 1)
    }

    /// The task block whose painted checkbox holds `point`, mirroring the
    /// decoration layer's geometry exactly (see `BlockDecorator`).
    private func taskCheckboxHit(at point: NSPoint) -> Int? {
        guard let layoutManager, let storage = textStorage, storage.length > 0 else { return nil }
        let location = characterIndex(at: point)
        guard let block = layout.block(containing: location), block.kind == .taskItem,
            block.range.length > 0,
            let width = layout.decorations[block.id]?.compactMap({ plan -> CGFloat? in
                if case let .taskCheckbox(_, width) = plan { return width }
                return nil
            }).first
        else { return nil }
        let firstGlyph = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: block.range.location, length: 1),
            actualCharacterRange: nil
        )
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: firstGlyph.location, effectiveRange: nil
        )
        let line = fragment.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
        let side: CGFloat = 12
        let box = CGRect(
            x: line.minX + width - side * 1.9, y: line.midY - side / 2,
            width: side, height: side
        )
        return box.insetBy(dx: -5, dy: -5).contains(point) ? block.id : nil
    }

    private func toggleTaskCheckbox(_ blockID: Int) {
        guard let storage = textStorage, let range = bufferRange(forBlock: blockID) else { return }
        apply(
            FormatController.toggleTask(at: range.location, selection: selectedRange(), in: storage.string)
        )
    }

    /// What a ⌘-click found: a URL to open, or a footnote to jump to.
    private enum ClickTarget {
        case url(String)
        case footnote(String)
    }

    /// Opens the link under `location`. Returns whether one was there, so the
    /// click can fall through to normal selection when it was not.
    @discardableResult
    private func openLink(at location: Int) -> Bool {
        guard let target = linkTarget(at: location) else { return false }
        switch target {
        case .url(let string): open(urlString: string)
        case .footnote(let label): jumpToFootnote(label)
        }
        return true
    }

    /// The link under `location`, found by re-lexing its verbatim slice: the
    /// layout knows ranges, the node tree knows destinations, and the slice is
    /// what joins them without a stored cross-reference.
    private func linkTarget(at location: Int) -> ClickTarget? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let chain = layout.inlineChain(at: min(location, storage.length - 1))
        let kinds: [InlineKind] = [.link, .refLink, .autolink, .footnoteRef]
        guard let element = chain.first(where: { kinds.contains($0.kind) }),
            NSMaxRange(element.range) <= storage.length
        else { return nil }
        let slice = (storage.string as NSString).substring(with: element.range)
        guard let node = InlineLexer.parse(slice).first else { return nil }
        switch node.kind {
        case .link, .autolink:
            let destination = node.attributes.destination ?? node.payload
            return destination.isEmpty ? nil : .url(destination)
        case .refLink:
            guard let reference = node.attributes.reference?.lowercased(), !reference.isEmpty else {
                return nil
            }
            let destination = document.linkDefinitions[reference]?.attributes.definitionDestination ?? ""
            return destination.isEmpty ? nil : .url(destination)
        case .footnoteRef:
            guard let label = node.attributes.reference, !label.isEmpty else { return nil }
            return .footnote(label)
        default:
            return nil
        }
    }

    private func open(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("ftp://")
        {
            if let url = URL(string: trimmed) { NSWorkspace.shared.open(url) }
            return
        }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            onOpenURL?(url)
            return
        }
        if trimmed.hasPrefix("/") {
            onOpenURL?(URL(fileURLWithPath: trimmed))
            return
        }
        let base = completionDirectory ?? imagePainter.baseDirectory
        guard let base else { return }
        onOpenURL?(base.appendingPathComponent(trimmed))
    }

    private func jumpToFootnote(_ label: String) {
        let definitions = document.footnoteDefinitions
        let node =
            definitions[label] ?? definitions.first { $0.key.lowercased() == label.lowercased() }?.value
        guard let node, let range = bufferRange(forBlock: node.id) else { return }
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
    }

    /// The TOC entry under `point`, using the same row geometry the builder
    /// reserved and the painter drew, so clicks land on the row they hit.
    private func tocEntryHit(at point: NSPoint) -> MarkdownDocument.Heading? {
        guard let layoutManager, let storage = textStorage, storage.length > 0 else { return nil }
        let location = characterIndex(at: point)
        guard let block = layout.block(containing: location), block.kind == .toc,
            block.range.length > 0,
            let entries = layout.decorations[block.id]?.compactMap(
                { plan -> [MarkdownDocument.Heading]? in
                    if case let .tocEntries(entries) = plan { return entries }
                    return nil
                }
            ).first,
            !entries.isEmpty
        else { return nil }
        let firstGlyph = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: block.range.location, length: 1),
            actualCharacterRange: nil
        )
        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: firstGlyph.location, effectiveRange: nil
        )
        let line = fragment.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
        let margin =
            (storage.attribute(.paragraphStyle, at: block.range.location, effectiveRange: nil)
            as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
        let rowHeight = theme.bodyLineHeight * theme.bodyFontSize
        guard rowHeight > 0 else { return nil }
        let index = Int((point.y - (line.minY + margin)) / rowHeight)
        guard entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    private func jumpToTOCEntry(_ entry: MarkdownDocument.Heading) {
        guard let range = bufferRange(forBlock: entry.blockID) else { return }
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
    }

    // MARK: - Context menu

    /// Typora-style right-click menu: link actions on a link, table operations
    /// in a table, and the everyday edit/format items otherwise.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let storage = textStorage else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        contextMenuLocation = characterIndex(at: point)
        // The actions below run on the selection, so a right-click outside it
        // moves the caret there first - otherwise Cut and the table operations
        // would act on a stale range the user is not pointing at.
        if !NSLocationInRange(contextMenuLocation, selectedRange()) {
            setSelectedRange(NSRange(location: contextMenuLocation, length: 0))
            contextMenuLocation = selectedRange().location
        }
        let text = storage.string
        let menu = NSMenu()

        if let target = linkTarget(at: contextMenuLocation) {
            switch target {
            case .url:
                let open = menu.addItem(
                    withTitle: "Open Link", action: #selector(openContextLink), keyEquivalent: ""
                )
                open.target = self
                let copy = menu.addItem(
                    withTitle: "Copy Link Address", action: #selector(copyContextLink),
                    keyEquivalent: ""
                )
                copy.target = self
            case .footnote:
                let jump = menu.addItem(
                    withTitle: "Jump to Footnote", action: #selector(jumpContextFootnote),
                    keyEquivalent: ""
                )
                jump.target = self
            }
            menu.addItem(.separator())
        }

        for (title, selector) in [
            ("Cut", #selector(NSText.cut(_:))),
            ("Copy", #selector(NSText.copy(_:))),
            ("Paste", #selector(NSText.paste(_:))),
            ("Paste as Plain Text", #selector(NSTextView.pasteAsPlainText(_:))),
            ("Select All", #selector(NSText.selectAll(_:))),
        ] {
            menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        }
        menu.addItem(.separator())

        for (title, action) in [
            ("Bold", FormatAction.bold),
            ("Italic", FormatAction.italic),
            ("Strikethrough", FormatAction.strikethrough),
            ("Inline Code", FormatAction.inlineCode),
            ("Link", FormatAction.link),
        ] {
            let item = menu.addItem(
                withTitle: title, action: #selector(applyContextFormat(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action.rawValue
        }

        if FormatController.containsTable(at: contextMenuLocation, in: storage.string) {
            menu.addItem(.separator())
            for (title, action) in [
                ("Insert Row Above", FormatAction.tableRowAbove),
                ("Insert Row Below", FormatAction.tableRowBelow),
                ("Delete Row", FormatAction.tableDeleteRow),
                ("Insert Column Left", FormatAction.tableColumnLeft),
                ("Insert Column Right", FormatAction.tableColumnRight),
                ("Delete Column", FormatAction.tableDeleteColumn),
            ] {
                let item = menu.addItem(
                    withTitle: title, action: #selector(applyContextFormat(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = action.rawValue
            }
        }
        return menu
    }

    @objc func applyContextFormat(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let action = FormatAction(rawValue: raw)
        else { return }
        format { FormatController.edit(for: action, in: $0, range: $1) }
    }

    @objc func openContextLink() {
        openLink(at: contextMenuLocation)
    }

    @objc func copyContextLink() {
        guard case .url(let string) = linkTarget(at: contextMenuLocation) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @objc func jumpContextFootnote() {
        guard case .footnote(let label) = linkTarget(at: contextMenuLocation) else { return }
        jumpToFootnote(label)
    }
}

extension MarkdownTextView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard !isReplacingForReparse else { return }
        scheduleReparse()
        onTextChange?(textStorage?.string ?? "")
    }

    private func scheduleReparse() {
        // The original coalesces continuous typing with a ~50ms window so a burst of
        // keystrokes causes one relayout, not one per character.
        reparseTimer?.invalidate()
        reparseTimer = Timer.scheduledTimer(
            withTimeInterval: 0.05, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reparseIfNeeded()
            }
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        refocus()
        centerCaretIfNeeded()
    }
}
