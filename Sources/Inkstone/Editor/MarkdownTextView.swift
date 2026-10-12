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
    /// Incremental-reparse state.
    var focusedBlockID: Int?
    private var reparseTimer: Timer?
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

    /// Replaces the whole document. Used on open, not while editing.
    func load(markdown text: String) {
        let parsed = BlockParser.parse(text, options: .standard)
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
            guard super.shouldChangeText(in: target, replacementString: replacement) else {
                return false
            }
            setSelectedRange(caret, affinity: .downstream, stillSelecting: false)
            return true
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
        if start < caret, ns.character(at: start - 1) == colonCode {
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
        storage.replaceCharacters(in: range, with: item.insert + item.suffix)
        let caret = range.location + item.insert.utf16.count + item.suffix.utf16.count
        setSelectedRange(
            NSRange(location: caret, length: 0), affinity: .downstream, stillSelecting: false
        )
        notifyTextChanged()
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
        guard super.shouldChangeText(in: target, replacementString: rewritten) else { return }
        setSelectedRange(
            NSRange(location: target.location + rewritten.utf16.count, length: 0),
            affinity: .downstream, stillSelecting: false
        )
        notifyTextChanged()
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
            storage.replaceCharacters(
                in: NSRange(location: start, length: end - start), with: ""
            )
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
                containerWidth: contentWidth, imageBaseDirectory: imagePainter.baseDirectory
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
        let parsed = BlockParser.parse(text, options: .standard)
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
        document = BlockParser.parse(textStorage?.string ?? "", options: .standard)
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

    /// Paragraph styles for the buffer's rows of a table block, or `nil` when the
    /// block is not one.
    private func paragraphStyles(
        for blockID: Int, rows: Int, revealed: Bool
    ) -> [NSParagraphStyle]? {
        guard let plans = layout.decorations[blockID] else { return nil }
        var grid: TableGrid?
        for plan in plans {
            if case let .tableGrid(found) = plan { grid = found }
        }
        guard let grid else { return nil }
        return (0..<rows).map { index in
            grid.paragraphStyle(
                forSourceRow: index, revealed: revealed,
                spacing: index == 0 ? theme.blockMargin : 0
            )
        }
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
    /// `shouldChangeText`, then the caret where the command put it - so undo,
    /// the dirty flag and the reparse all behave exactly as they do for typing.
    func apply(_ edit: FormatController.Edit) {
        guard let storage = textStorage, !isReadonly else { return }
        guard NSMaxRange(edit.range) <= storage.length else { return }
        guard edit.range.length > 0 || !edit.text.isEmpty else { return }
        guard super.shouldChangeText(in: edit.range, replacementString: edit.text) else {
            return
        }
        setSelectedRange(edit.selection, affinity: .downstream, stillSelecting: false)
        notifyTextChanged()
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
