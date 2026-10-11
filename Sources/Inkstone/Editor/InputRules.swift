import AppKit

/// Keystroke rewriting for the editor: auto-pairing, smart quotes and dashes, and
/// list continuation on Return.
///
/// Kept separate from `MarkdownTextView` because these are decisions about text, not
/// about TextKit. `Editor/` may not read `Session/`, so the preferences arrive as a
/// plain value rather than as `EditorSettings`.
struct InputOptions {
    var autoPairBrackets = true
    var autoPairMarkdownSyntax = true
    var smartQuotes = true
    var indentSize = 2
    var codeIndentSize = 4
    /// The original inserts spaces rather than tab characters, and a tab in the buffer would
    /// be a byte the user never typed.
    var tabInsertsSpaces = true
}

enum InputRule {
    /// Insert `text`, then place the caret `caretOffset` characters back from its end.
    ///
    /// `deleteBefore` widens the replaced range backwards over characters already in the
    /// buffer, which is what turns the second `-` of `--` into one en dash instead of
    /// leaving a stray dash behind.
    case insert(String, caretOffset: Int, deleteBefore: Int = 0)
    /// Swallow the keystroke entirely.
    case reject
}

/// The text around the caret when a rule fires.
struct RuleContext {
    /// Characters on the current line before the caret.
    var lineBefore: String
    /// Characters on the current line after the caret.
    var lineAfter: String
    /// The characters the insertion would replace.
    var selection: String

    var hasSelection: Bool { !selection.isEmpty }
}

/// Brackets that pair, and the closer each one gets.
private let bracketPairs: [Character: Character] = [
    "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'",
]

/// Markdown delimiters that pair around a selection or the caret.
private let markdownPairs: [Character: Character] = [
    "*": "*", "_": "_", "`": "`", "$": "$", "~": "~",
]

enum InputRules {
    /// The plan for one keystroke, or `nil` to let the text view handle it normally.
    static func plan(for text: String, in context: RuleContext, options: InputOptions)
        -> InputRule?
    {
        guard text.count == 1, let character = text.first else { return nil }
        if character == "-" {
            return dashRule(in: context, options: options)
        }
        // A typed closer right before the very character it should close is the user
        // "stepping over" the pair, not asking for a second one.
        if context.selection.isEmpty, character == ")",
            context.lineBefore.hasSuffix("(")
        {
            return .insert(")", caretOffset: 0)
        }
        if bracketPairing(character, in: context, options: options),
            let closer = bracketPairs[character]
        {
            return bracket(character, closer)
        }
        if options.autoPairMarkdownSyntax, markdownPairs[character] != nil,
            markdownPairing(character, in: context)
        {
            return markdownDelimiter(character)
        }
        if options.smartQuotes, character == "\"", !context.hasSelection {
            return .insert("\"\"", caretOffset: 1)
        }
        return nil
    }

    // MARK: - Pairing

    private static func bracketPairing(
        _ character: Character, in context: RuleContext, options: InputOptions
    ) -> Bool {
        guard options.autoPairBrackets, bracketPairs[character] != nil else { return false }
        // After a word, `(` is multiplication rather than an opener.
        if let previous = context.lineBefore.last, previous.isLetter || previous.isNumber {
            return false
        }
        // Mid-line typing usually wants the closer out of the way, so only auto-close
        // at the end of the line or around a selection.
        return context.lineAfter.isEmpty || context.hasSelection
    }

    private static func markdownPairing(_ character: Character, in context: RuleContext) -> Bool {
        guard context.hasSelection else { return true }
        // `*`, `_` and `~` open emphasis only when doubled, so the first keystroke must
        // pass through untouched. A backtick or a dollar cannot start a run at all.
        let needsDoubled = "*_~".contains(character)
        return !needsDoubled || context.lineBefore.hasSuffix(String(character))
    }

    private static func bracket(_ opener: Character, _ closer: Character) -> InputRule {
        .insert(String([opener, closer]), caretOffset: 1)
    }

    private static func markdownDelimiter(_ delimiter: Character) -> InputRule {
        .insert(String(repeating: delimiter, count: 2), caretOffset: 2)
    }

    // MARK: - Dashes

    /// `--` becomes an en dash and `---` an em dash, but only between words: a leading
    /// `---` is a horizontal rule and has to stay literal, and a dash run must be
    /// replaced rather than appended to, or `--` would leave `–-` behind.
    private static func dashRule(in context: RuleContext, options: InputOptions) -> InputRule? {
        guard options.smartQuotes else { return nil }
        // The keystroke completes a run of dashes already in the buffer.
        let existing = context.lineBefore.reversed().prefix(while: { $0 == "-" }).count
        guard existing == 1 || existing == 2 else { return nil }
        // What decides it is the character *before* the run: `a--` is an en dash, but a
        // run that starts the line is a setext underline or a horizontal rule.
        let lead = context.lineBefore.dropLast(existing).last
        guard let lead, lead.isLetter || lead.isNumber else { return nil }
        let replacement = existing == 1 ? "\u{2013}" : "\u{2014}"
        return .insert(replacement, caretOffset: 0, deleteBefore: existing)
    }

    // MARK: - Line continuation

    /// The block prefix a Return should carry to the next line.
    ///
    /// `- item` becomes `- ` on the next line, `1. item` becomes `2. `, `> quote`
    /// becomes `> `. An empty item means "leave the list", which is what every user
    /// expects and what makes escaping a list possible without the mouse.
    enum Continuation {
        case prefix(String)
        /// The line is an empty item: drop the prefix and leave the list.
        case exit(String)
        case none
    }

    static func continuation(forLine line: String) -> Continuation {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let body = line.dropFirst(indent.count)

        if body.hasPrefix("> ") || body == ">" {
            let rest = String(body.dropFirst(body.hasPrefix("> ") ? 2 : 1))
            return rest.trimmingCharacters(in: .whitespaces).isEmpty
                ? .exit(indent + "> ")
                : .prefix(indent + "> ")
        }
        guard let marker = listMarker(of: body) else { return .none }
        let rest = String(body.dropFirst(marker.text.count))
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            return .exit(indent)
        }
        return .prefix(indent + marker.next)
    }

    /// One list marker, and whether it is an ordered one.
    private struct Marker {
        var text: String
        var number: Int = 0
        var ordered = false

        /// The marker the next line should carry.
        var next: String {
            guard ordered else { return text }
            return "\(number + 1). "
        }
    }

    private static func listMarker(of body: Substring) -> Marker? {
        for marker in ["- [ ] ", "- [x] ", "- [X] "] where body.hasPrefix(marker) {
            return Marker(text: marker)
        }
        if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
            return Marker(text: String(body.prefix(2)))
        }
        let digits = body.prefix { $0.isNumber }
        let rest = body.dropFirst(digits.count)
        for terminator in [". ", ") "] where !digits.isEmpty && rest.hasPrefix(terminator) {
            return Marker(text: String(digits) + terminator, number: Int(digits) ?? 1, ordered: true)
        }
        return nil
    }
}

// MARK: - Indentation

/// What Tab or Shift-Tab should do.
enum IndentAction {
    /// Replace the caret's line range with this text and put the caret at its end.
    case replaceCurrentLine(String)
    /// Insert text at the caret.
    case insert(String)
    case none
}

extension InputRules {
    /// Leading whitespace of a line, and the column after it.
    static func leadingWhitespace(of line: String) -> (indent: String, column: Int) {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        // A tab is not a fixed column count without a tab width; the original treats it as
        // `indentSize`, which is also what it inserts, so the two agree.
        let column =
            indent.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        return (indent, column)
    }

    /// Indent or outdent.
    ///
    /// `outdent` removes at most one level and does nothing when there is no indent to
    /// remove, rather than eating a single space: Shift-Tab pressed in the left margin
    /// should be inert, not destructive.
    static func indent(
        outdent: Bool, line: String, caretColumnInLine: Int, selectionIsMultiline: Bool,
        insideCodeBlock: Bool, options: InputOptions
    ) -> IndentAction {
        let step = insideCodeBlock ? options.codeIndentSize : options.indentSize
        let unit = String(repeating: " ", count: max(1, step))
        let (indent, column) = leadingWhitespace(of: line)
        let body = String(line.dropFirst(indent.count))

        if outdent {
            guard !indent.isEmpty else { return .none }
            // Take a whole level if the caret sits past it, otherwise one step.
            // Down to the previous whole level. A line sitting exactly on a boundary
            // drops a full level, not one character short of it. `target` is a column
            // count and the indent is one column per character, so the difference is
            // both the new width and the number of characters to drop.
            let target = column % step == 0 ? column - step : (column / step) * step
            let remaining = max(0, min(indent.count, target))
            return .replaceCurrentLine(String(repeating: " ", count: remaining) + body)
        }

        // Tab while the caret is still inside the line's own indentation snaps to the
        // next level rather than adding a whole step, which is what makes aligning a
        // nested bullet possible with two keystrokes instead of four.
        if !selectionIsMultiline, caretColumnInLine <= indent.count, !body.isEmpty {
            let level = max(1, step)
            let next = (max(0, caretColumnInLine) / level + 1) * level
            return .insert(String(repeating: " ", count: max(1, next - caretColumnInLine)))
        }

        // Everywhere else - at the start of the content, on an empty line, or inside a
        // code block - Tab is one literal level.
        _ = column
        return .insert(unit)
    }
}
