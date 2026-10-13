import AppKit
import Foundation

/// Applies token colours to fenced code.
///
/// Registry-based rather than a single hand-rolled highlighter: a small
/// line-oriented tokeniser per language family, resolved by name, alias or MIME
/// type. Unregistered languages fall through to the theme's plain colour, which is
/// the documented behaviour difference from the original (DESIGN.md §7).
final class CodeHighlighter: @unchecked Sendable {
    static let shared = CodeHighlighter()

    private init() {}

    /// Applies syntax attributes to `result` starting at `offset`.
    ///
    /// `result` already holds the code line; this only adds colours, so it is safe
    /// to call during a layout pass.
    func apply(
        to result: NSMutableAttributedString,
        text: String,
        language: String,
        palette: SyntaxPalette,
        offset: Int
    ) {
        guard let family = CodeLanguage(family: language),
            let range = result.length > offset
                ? NSRange(location: offset, length: result.length - offset) : nil
        else { return }
        result.addAttribute(.foregroundColor, value: palette.plain.nsColor, range: range)
        for token in CodeTokenizer.tokenize(text, family: family) {
            let tokenRange = NSRange(location: offset + token.range.location, length: token.range.length)
            guard NSMaxRange(tokenRange) <= NSMaxRange(range) else { continue }
            result.addAttribute(.foregroundColor, value: token.color(palette).nsColor, range: tokenRange)
        }
    }
}

/// The tokeniser families. Chosen so the common cases stay small: one family per
/// punctuation style rather than one per language.
enum CodeLanguage: String, CaseIterable {
    case clike
    case hash
    case shell
    case sql
    case markup
    case css
    case yaml
    case ini
    case plain

    init?(family: String) {
        switch family.lowercased() {
        case "swift", "javascript", "js", "jsx", "typescript", "ts", "tsx", "c", "h",
            "objective-c", "objc", "cpp", "c++", "cc", "hpp", "java", "kotlin", "scala",
            "go", "rust", "rs", "csharp", "c#", "php", "dart", "groovy":
            self = .clike
        case "python", "py", "ruby", "rb", "perl", "r":
            self = .hash
        case "sh", "bash", "zsh", "shell", "console", "fish":
            self = .shell
        case "sql":
            self = .sql
        case "html", "xml", "svg", "vue", "svelte":
            self = .markup
        case "css", "scss", "less":
            self = .css
        case "yaml", "yml", "toml":
            self = .yaml
        case "ini", "cfg", "conf", "properties", "gitconfig", "dockerfile":
            self = .ini
        case "", "text", "plain", "plaintext":
            self = .plain
        default:
            // Unregistered languages fall through to plain, per the documented
            // behaviour difference from the original (DESIGN.md §7) - tokenising
            // prose-like input as C-like sprayed keywords over text the user
            // never asked to highlight.
            self = .plain
        }
    }
}

struct CodeToken {
    enum Kind {
        case keyword, string, number, comment, tag, attribute, function, type
        case `operator`, punctuation, plain
    }

    let kind: Kind
    let range: NSRange

    func color(_ palette: SyntaxPalette) -> DynamicColor {
        switch kind {
        case .keyword: return palette.keyword
        case .string: return palette.string
        case .number: return palette.number
        case .comment: return palette.comment
        case .tag: return palette.tag
        case .attribute: return palette.attribute
        case .function: return palette.function
        case .type: return palette.type
        case .`operator`: return palette.operator
        case .punctuation: return palette.punctuation
        case .plain: return palette.plain
        }
    }
}

/// A compact tokeniser. Not a full grammar: it recognises comments, strings,
/// numbers, keywords, types and punctuation, which is what makes code blocks
/// readable. Anything it cannot classify stays plain.
enum CodeTokenizer {
    private static let keywords: Set<String> = [
        "abstract", "actor", "any", "as", "associatedtype", "async", "await", "break",
        "case", "catch", "class", "continue", "convenience", "default", "defer", "deinit",
        "didSet", "do", "dynamic", "else", "enum", "extension", "fallthrough", "false",
        "final", "fileprivate", "for", "func", "get", "guard", "if", "import", "in",
        "indirect", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil",
        "nonmutating", "open", "operator", "optional", "override", "package", "postfix",
        "precedence", "prefix", "private", "protocol", "public", "repeat", "required",
        "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript",
        "super", "switch", "throw", "throws", "true", "try", "typealias", "unowned",
        "var", "weak", "where", "while", "willSet",
        "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "finally", "for", "function", "if",
        "import", "in", "instanceof", "interface", "let", "new", "of", "return", "super",
        "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
        "const", "continue", "default", "do", "double", "else", "enum", "extends", "final",
        "finally", "float", "for", "goto", "if", "implements", "import", "instanceof", "int",
        "interface", "long", "native", "new", "package", "private", "protected", "public",
        "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this",
        "throw", "throws", "transient", "try", "void", "volatile", "while",
        "chan", "defer", "fallthrough", "func", "go", "map", "range", "select", "struct",
        "type", "var", "const", "interface", "namespace", "template", "public", "private",
        "protected", "static", "extern", "enum", "struct", "typedef", "union", "goto",
    ]

    private static let types: Set<String> = [
        "Int", "String", "Bool", "Double", "Float", "Array", "Dictionary", "Set",
        "Optional", "Result", "Error", "Character", "UInt", "Data", "URL", "Date",
        "CGFloat", "NSColor", "NSFont", "NSView", "NSViewController", "Color", "Font",
        "int", "long", "short", "byte", "char", "float", "double", "boolean", "void",
        "string", "auto", "size_t", "uint8_t", "uint32_t", "int64_t",
    ]

    static func tokenize(_ text: String, family: CodeLanguage) -> [CodeToken] {
        guard family != .plain else { return [] }
        let characters = Array(text)
        var tokens: [CodeToken] = []
        var index = 0
        // Tokens are found over `[Character]` but consumed as NSString ranges
        // (UTF-16 offsets): an emoji in a comment used to shift every later token
        // one unit per astral character and silently miscolour the line.
        var utf16Offsets = [Int](repeating: 0, count: characters.count + 1)
        for (position, character) in characters.enumerated() {
            utf16Offsets[position + 1] = utf16Offsets[position] + String(character).utf16.count
        }

        func emit(_ kind: CodeToken.Kind, from start: Int, to end: Int) {
            guard end > start else { return }
            let location = utf16Offsets[min(max(start, 0), characters.count)]
            let limit = utf16Offsets[min(max(end, 0), characters.count)]
            tokens.append(CodeToken(kind: kind, range: NSRange(location: location, length: limit - location)))
        }

        while index < characters.count {
            let character = characters[index]

            // Line comment.
            if character == "/", index + 1 < characters.count {
                let next = characters[index + 1]
                let isComment =
                    (next == "/" && family != .shell)
                    || (next == "*" && family != .shell)
                if isComment {
                    if next == "*" {
                        // Block comment.
                        var end = index + 2
                        while end + 1 < characters.count,
                            !(characters[end] == "*" && characters[end + 1] == "/")
                        {
                            end += 1
                        }
                        end = min(end + 2, characters.count)
                        emit(.comment, from: index, to: end)
                        index = end
                        continue
                    }
                    var end = index + 2
                    while end < characters.count, characters[end] != "\n" { end += 1 }
                    emit(.comment, from: index, to: end)
                    index = end
                    continue
                }
            }
            if family == .hash, character == "#" {
                var end = index + 1
                while end < characters.count, characters[end] != "\n" { end += 1 }
                emit(.comment, from: index, to: end)
                index = end
                continue
            }
            if family == .shell, character == "#" {
                var end = index + 1
                while end < characters.count, characters[end] != "\n" { end += 1 }
                emit(.comment, from: index, to: end)
                index = end
                continue
            }
            if family == .ini, character == ";" || character == "#" {
                var end = index + 1
                while end < characters.count, characters[end] != "\n" { end += 1 }
                emit(.comment, from: index, to: end)
                index = end
                continue
            }
            if family == .yaml, character == ";" || character == "#" {
                var end = index + 1
                while end < characters.count, characters[end] != "\n" { end += 1 }
                emit(.comment, from: index, to: end)
                index = end
                continue
            }

            // Strings.
            if character == "\"" || character == "'" || (family == .shell && character == "\"") {
                let quote = character
                var end = index + 1
                while end < characters.count {
                    if characters[end] == "\\" {
                        end += 2
                        continue
                    }
                    if characters[end] == quote {
                        end += 1
                        break
                    }
                    end += 1
                }
                emit(.string, from: index, to: min(end, characters.count))
                index = min(end, characters.count)
                continue
            }
            if family == .hash && character == "`" {
                var end = index + 1
                while end < characters.count, characters[end] != "`" { end += 1 }
                end = min(end + 1, characters.count)
                emit(.string, from: index, to: end)
                index = end
                continue
            }

            // Markup tags and attributes.
            if family == .markup, character == "<" {
                var end = index + 1
                while end < characters.count, characters[end] != ">" { end += 1 }
                end = min(end + 1, characters.count)
                let body = String(characters[(index + 1)..<max(end - 1, index + 1)])
                if body.hasPrefix("/") || body.hasPrefix("!") {
                    emit(.comment, from: index, to: end)
                } else {
                    let nameEnd =
                        body.firstIndex(where: {
                            $0 == " " || $0 == "\t" || $0 == "/"
                                || $0 == "\n"
                        }) ?? body.endIndex
                    // A Character offset into `body`, not a UTF-16 one: the tag name
                    // length lands back on the same index space the tokenizer uses.
                    let nameLength = body.distance(from: body.startIndex, to: nameEnd)
                    emit(.tag, from: index, to: index + 1 + nameLength)
                    emit(.attribute, from: index + 1 + nameLength, to: end)
                }
                index = end
                continue
            }

            // YAML keys.
            if family == .yaml, character.isLetter || character == "_" {
                let start = index
                var end = index
                while end < characters.count,
                    characters[end].isLetter || characters[end].isNumber
                        || characters[end] == "_" || characters[end] == "-"
                {
                    end += 1
                }
                // A key is followed by a colon.
                if end < characters.count, characters[end] == ":" {
                    emit(.attribute, from: start, to: end)
                    index = end
                    continue
                }
                index = end
                continue
            }

            // Numbers.
            if character.isNumber {
                let start = index
                var end = index
                while end < characters.count,
                    characters[end].isNumber || characters[end] == "." || characters[end] == "x"
                        || characters[end] == "e" || characters[end] == "_"
                {
                    end += 1
                }
                emit(.number, from: start, to: end)
                index = end
                continue
            }

            // Identifiers.
            if character.isLetter || character == "_" || character == "$" || character == "@" {
                let start = index
                var end = index
                while end < characters.count,
                    characters[end].isLetter || characters[end].isNumber
                        || characters[end] == "_" || characters[end] == "$"
                        || characters[end] == "@"
                {
                    end += 1
                }
                // A tokenizer must always advance. `@` passes the *start* test but
                // was missing from the *continuation* set, so `end` stayed at `start`,
                // `index = end` never moved, and any fenced block whose info string
                // selected this family and contained a bare `@` hung the process.
                if end == start { end = min(start + 1, characters.count) }
                let word = String(characters[start..<end])
                var lookahead = end
                while lookahead < characters.count, characters[lookahead] == " " {
                    lookahead += 1
                }
                if keywords.contains(word) {
                    emit(.keyword, from: start, to: end)
                } else if types.contains(word) {
                    emit(.type, from: start, to: end)
                } else if lookahead < characters.count, characters[lookahead] == "(" {
                    emit(.function, from: start, to: end)
                } else if word.first?.isUppercase == true {
                    emit(.type, from: start, to: end)
                }
                index = end
                continue
            }

            // Operators and punctuation.
            if "+-*/%=<>!&|^~?:".contains(character) {
                emit(.`operator`, from: index, to: index + 1)
            } else if "()[]{},;.".contains(character) {
                emit(.punctuation, from: index, to: index + 1)
            }
            index += 1
        }
        return tokens
    }
}

extension String.Index {
    /// Number of UTF-16 units between the string's start and this index.
    ///
    /// Returns 0 for an index that does not belong to `string`, which every call
    /// site reads as "no token here" rather than as a crash.
    fileprivate func utf16Offset(in string: String) -> Int {
        guard let offset = self.samePosition(in: string) else { return 0 }
        return string.utf16.distance(
            from: string.utf16.startIndex,
            to: offset.samePosition(in: string.utf16)
                ?? string.utf16.endIndex
        )
    }
}
