import AppKit
import Foundation

/// Source mode: the document's Markdown, editable, with syntax colouring.
///
/// ## Why this is a second text view, and why it is fed from the node tree
///
/// The original's source mode is a separate CodeMirror instance in a second container,
/// switched by a CSS class on `body`. The same split applies here, but the
/// content cannot come from the main buffer: in that buffer an attachment-rendered
/// block (table, math, image, HTML, TOC) is a single `U+FFFC` character, so
/// reading the buffer would show `￼` where the user expects the table's rows.
/// `MarkdownDocument.source` materialises those blocks instead, which is why the
/// invariant is "the Node tree is authoritative for anything but plain text".
///
/// Two-way: edits here re-parse the whole document and push it back into the main
/// view. Re-parsing wholesale is acceptable because this view is a deliberate mode,
/// not the typing path - the typing path is incremental.
@MainActor
final class SourceModeController: NSObject {
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private var theme: EditorTheme
    private var document: MarkdownDocument
    private var parseOptions: BlockParser.Options
    private var isActive = false
    /// Set while pushing edits into the main view, so the reverse sync does not
    /// echo them back.
    private var isSyncing = false
    /// Called with the new markdown whenever the user edits in source mode.
    var onChange: ((String) -> Void)?

    init(theme: EditorTheme, markdown: String, parseOptions: BlockParser.Options) {
        self.theme = theme
        self.parseOptions = parseOptions
        let parsed = BlockParser.parse(markdown, options: parseOptions)
        document = parsed

        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: CGSize(width: 860, height: CGFloat.greatestFiniteMagnitude)
        )
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let editor = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 860, height: 600), textContainer: container
        )
        editor.isRichText = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.allowsUndo = true
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        editor.backgroundColor = theme.background.nsColor
        editor.insertionPointColor = EditorColor.caret.nsColor
        editor.textContainerInset = NSSize(
            width: theme.contentPadding, height: theme.contentPadding
        )

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 860, height: 600))
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.backgroundColor = theme.background.nsColor
        scroll.isHidden = true

        textView = editor
        scrollView = scroll
        super.init()
        editor.delegate = self
        setText(parsed.source)
    }

    // MARK: - Toggling

    var isVisible: Bool { isActive }

    /// Shows or hides the source view inside `container`, covering the document's
    /// content (the document lives in a host tab, not a window of its own).
    /// Returns the markdown if the mode was just left, so the caller can push the
    /// result into the document view.
    @discardableResult
    func toggle(in container: NSView, markdown: String, parseOptions: BlockParser.Options)
        -> String?
    {
        isActive.toggle()
        if isActive {
            document = BlockParser.parse(markdown, options: parseOptions)
            setText(document.source)
            container.addSubview(scrollView)
            scrollView.frame = container.bounds
            scrollView.autoresizingMask = [.width, .height]
            scrollView.isHidden = false
            container.window?.makeFirstResponder(textView)
            return nil
        }
        scrollView.isHidden = true
        scrollView.removeFromSuperview()
        // Re-parsing here only refreshes the internal view; the caller pushes the
        // text back through the editor, and assigning `document` on the way out was
        // a dead store (the value is overwritten before it is ever read).
        return textView.string
    }

    /// Replaces the content when the underlying document changes elsewhere - a
    /// file open, or a revert - while leaving the caret alone.
    func load(markdown: String) {
        document = BlockParser.parse(markdown, options: parseOptions)
        setText(document.source)
    }

    func apply(theme: EditorTheme) {
        self.theme = theme
        textView.backgroundColor = theme.background.nsColor
        textView.insertionPointColor = EditorColor.caret.nsColor
        scrollView.backgroundColor = theme.background.nsColor
        setText(textView.string)
    }

    func setWidth(_ width: CGFloat) {
        textView.textContainer?.containerSize = CGSize(
            width: max(width, 200), height: CGFloat.greatestFiniteMagnitude
        )
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
    }

    // MARK: - Content

    private func setText(_ text: String) {
        isSyncing = true
        let selected = textView.selectedRange()
        textView.textStorage?.setAttributedString(
            SourceHighlighter.highlight(text, theme: theme)
        )
        let location = min(selected.location, textView.textStorage?.length ?? 0)
        textView.setSelectedRange(
            NSRange(
                location: location,
                length: min(selected.length, (text as NSString).length)
            )
        )
        isSyncing = false
    }

    var currentMarkdown: String { textView.string }
}

extension SourceModeController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard isActive, !isSyncing else { return }
        // Highlight only the paragraph that changed plus the one after it: enough
        // for block-level constructs, cheap enough to run per keystroke.
        rehighlight()
        onChange?(textView.string)
    }

    private func rehighlight() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let location = textView.selectedRange().location
        let lineRange = (storage.string as NSString).lineRange(
            for: NSRange(location: min(location, storage.length - 1), length: 0)
        )
        let expanded = NSIntersectionRange(lineRange, NSRange(location: 0, length: storage.length))
        isSyncing = true
        SourceHighlighter.apply(
            to: storage, range: expanded, theme: theme
        )
        isSyncing = false
    }
}

/// Colours Markdown source the way the original's `cm-header` / `cm-meta` classes do.
enum SourceHighlighter {
    /// Full-document highlight, used on load and on theme change.
    static func highlight(_ text: String, theme: EditorTheme) -> NSAttributedString {
        let mono = EditorFont.nsMono(size: theme.rootFontSize)
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: mono,
                .foregroundColor: theme.text.nsColor,
                .paragraphStyle: lineStyle(theme: theme),
            ]
        )
        apply(to: result, range: NSRange(location: 0, length: result.length), theme: theme)
        return result
    }

    /// Re-colours `range` in place. Attribute-only, so it never enters the undo
    /// stack and never disturbs the caret.
    static func apply(to storage: NSMutableAttributedString, range: NSRange, theme: EditorTheme) {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        guard clamped.length > 0 else { return }
        let whole = storage.string as NSString
        let mono = EditorFont.nsMono(size: theme.rootFontSize)
        storage.setAttributes(
            [
                .font: mono,
                .foregroundColor: theme.text.nsColor,
                .paragraphStyle: lineStyle(theme: theme),
            ],
            range: clamped
        )

        // Line-leading markers: `#`, `>`, list bullets, fences, `$$`.
        var lineStart = clamped.location
        while lineStart > 0 {
            let previous = whole.lineRange(
                for: NSRange(location: max(0, lineStart - 1), length: 0)
            )
            if previous.location < clamped.location || previous.length == 0 { break }
            lineStart = previous.location
        }
        let lineEnd = NSMaxRange(
            whole.lineRange(for: NSRange(location: min(lineStart, whole.length), length: 0))
        )
        let blockRange = NSIntersectionRange(
            NSRange(location: lineStart, length: max(lineEnd - lineStart, 0)),
            NSRange(location: 0, length: storage.length)
        )
        guard blockRange.length > 0 else { return }

        var position = blockRange.location
        while position < NSMaxRange(blockRange) {
            let line = whole.lineRange(
                for: NSRange(location: position, length: 0)
            )
            guard line.length > 0 else { break }
            let content = whole.substring(with: line)
            let markerLength = leadingMarkerLength(of: content)
            if markerLength > 0 {
                storage.addAttribute(
                    .foregroundColor, value: theme.syntax.marker.nsColor,
                    range: NSRange(location: line.location, length: markerLength)
                )
            }
            position = NSMaxRange(line)
        }

        // Inline syntax, applied across the whole clamped range so a delimiter
        // opening outside the range is still recognised where it matters.
        applyInline(to: storage, range: blockRange, theme: theme)
    }

    /// Length of the leading run of block-marker characters on a line.
    ///
    /// The run counts as a marker when it ends on whitespace or covers the whole
    /// line: `# Heading` and `- item` carry `# `/`- ` as their marker, while
    /// `a-b` keeps its hyphen. (The first version required the character *after*
    /// the run to be whitespace, which is never true for `# Heading` - the tint
    /// was effectively dead for every ordinary marker line.)
    private static func leadingMarkerLength(of line: String) -> Int {
        var index = line.startIndex
        var length = 0
        while index < line.endIndex {
            let character = line[index]
            if "#>-+*|~$= \t".contains(character) {
                length += 1
                index = line.index(after: index)
                continue
            }
            break
        }
        guard length > 0 else { return 0 }
        if length == line.count { return length }
        // The run itself ends in whitespace (`- `), or the next character starts
        // a whitespace run (`#  Title`): either way the prefix is a marker.
        if line[line.index(line.startIndex, offsetBy: length - 1)].isWhitespace { return length }
        let next = line[line.index(line.startIndex, offsetBy: length)]
        return next.isWhitespace ? length : 0
    }

    private static func applyInline(
        to storage: NSMutableAttributedString, range: NSRange, theme: EditorTheme
    ) {
        let text = (storage.string as NSString).substring(with: range)
        let patterns: [(String, DynamicColor)] = [
            ("\\*\\*[^*]+\\*\\*", theme.syntax.keyword),
            ("(?<!\\*)\\*[^*]+\\*(?!\\*)", theme.syntax.type),
            ("_[^_]+_", theme.syntax.type),
            ("~~[^~]+~~", theme.syntax.type),
            ("`[^`]+`", theme.syntax.string),
            ("==[^=]+==", theme.syntax.attribute),
            ("\\$[^$\\n]+\\$", theme.syntax.number),
            ("!\\[[^\\]]*\\]\\([^)]*\\)", theme.syntax.keyword),
            ("\\[[^\\]]*\\]\\([^)]*\\)", theme.syntax.function),
            ("^\\s*\\[[^\\]]+\\]:.*$", theme.syntax.comment),
            ("^#{1,6}\\s", theme.syntax.marker),
        ]
        for (pattern, colour) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            else { continue }
            let matches = expression.matches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length)
            )
            for match in matches {
                let translated = NSRange(
                    location: range.location + match.range.location,
                    length: match.range.length
                )
                storage.addAttribute(.foregroundColor, value: colour.nsColor, range: translated)
            }
        }
    }

    private static func lineStyle(theme: EditorTheme) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = theme.rootFontSize * theme.bodyLineHeight
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.lineBreakMode = .byWordWrapping
        return style
    }
}
