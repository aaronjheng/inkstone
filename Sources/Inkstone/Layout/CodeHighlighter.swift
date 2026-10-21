import AppKit
import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterCSharp
import TreeSitterGo
import TreeSitterHTML
import TreeSitterHaskell
import TreeSitterJSON
import TreeSitterJava
import TreeSitterKotlin
import TreeSitterLua
import TreeSitterPHP
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterXML
import TreeSitterYAML

/// Applies token colours to fenced code with tree-sitter.
///
/// One bundled grammar per supported language, selected by the fence's info
/// string; a language with no bundled grammar renders in the theme's plain
/// colour. The whole block is parsed rather than each line, so a construct that
/// spans lines - a block comment, a multi-line string - colours across all of
/// them.
///
/// Callers run on the main thread (the layout pass), which lets the parsers be
/// cached without locking.
@MainActor
final class CodeHighlighter {
    static let shared = CodeHighlighter()

    /// The bundled grammars. The raw value is the cache key.
    private enum Grammar: String {
        case swift, typescript, tsx, cLanguage, cpp, java, go, rust, html, json, bash
        case python, ruby, php, csharp, css, haskell, kotlin, yaml, lua, xml

        /// The resource bundle SwiftPM builds for a grammar package. The
        /// pattern is `<Package>_<Target>`; TypeScript's TSX parser is the
        /// second target of its package, so it is named explicitly.
        var bundleName: String {
            self == .tsx
                ? "TreeSitterTypeScript_TreeSitterTSX"
                : "TreeSitter\(packageName)_TreeSitter\(packageName)"
        }

        /// Relative directories inside the bundle that may hold
        /// `highlights.scm`, in probe order. XML copies `queries/xml` rather
        /// than `queries`, so its own folder comes first.
        var queryDirectories: [String] {
            let standard = ["queries", "Contents/Resources/queries"]
            switch self {
            case .xml: return ["xml", "Contents/Resources/xml"] + standard
            default: return standard
            }
        }

        private var packageName: String {
            switch self {
            case .swift: "Swift"
            case .typescript: "TypeScript"
            case .tsx: "TSX"
            case .cLanguage: "C"
            case .cpp: "CPP"
            case .java: "Java"
            case .go: "Go"
            case .rust: "Rust"
            case .html: "HTML"
            case .json: "JSON"
            case .bash: "Bash"
            case .python: "Python"
            case .ruby: "Ruby"
            case .php: "PHP"
            case .csharp: "CSharp"
            case .css: "CSS"
            case .haskell: "Haskell"
            case .kotlin: "Kotlin"
            case .yaml: "YAML"
            case .lua: "Lua"
            case .xml: "XML"
            }
        }
    }

    /// Fence info strings → grammar. Only spellings a bundled grammar actually
    /// covers are listed; everything else renders plain.
    private static let aliases: [String: Grammar] = [
        "swift": .swift,
        "typescript": .typescript, "ts": .typescript,
        "javascript": .typescript, "js": .typescript,
        "tsx": .tsx, "jsx": .tsx,
        "c": .cLanguage, "h": .cLanguage,
        "cpp": .cpp, "c++": .cpp, "cc": .cpp, "cxx": .cpp,
        "hpp": .cpp, "hxx": .cpp, "hh": .cpp,
        "java": .java,
        "go": .go, "golang": .go,
        "rust": .rust, "rs": .rust,
        "html": .html, "xhtml": .html,
        "json": .json, "jsonc": .json,
        "bash": .bash, "sh": .bash, "shell": .bash, "zsh": .bash, "console": .bash,
        "python": .python, "py": .python, "python3": .python,
        "ruby": .ruby, "rb": .ruby,
        "php": .php,
        "csharp": .csharp, "cs": .csharp, "c#": .csharp,
        "css": .css,
        "haskell": .haskell, "hs": .haskell,
        "kotlin": .kotlin, "kt": .kotlin,
        "yaml": .yaml, "yml": .yaml,
        "lua": .lua,
        "xml": .xml,
    ]

    /// A grammar's language object and the highlight query that colours it.
    private struct Highlighting {
        let language: Language
        let query: Query
    }

    private var highlighters: [Grammar: Highlighting] = [:]
    private var parsers: [Grammar: Parser] = [:]

    private init() {}

    /// The highlight ranges for one fenced block's body, as offsets into
    /// `source`. Empty when the info string names no bundled grammar.
    func highlights(in source: String, language: String) -> [NamedRange] {
        guard let grammar = Self.aliases[language.lowercased()],
            let highlighting = highlighting(for: grammar),
            let parser = parser(for: grammar, highlighting: highlighting),
            let tree = parser.parse(source)
        else { return [] }
        let cursor = highlighting.query.execute(in: tree)
        let ranges = cursor.resolve(with: Predicate.Context(string: source)).highlights()
        return ranges
    }

    /// The theme colour for a tree-sitter capture name.
    ///
    /// The grammars agree on the base components (`keyword`, `string`,
    /// `function`, ...) and differ on the sub-components, so the base decides
    /// and only the spellings the grammars disagree on (`@escape`, `@boolean`,
    /// `@embedded`, `@delimiter`) are named explicitly. A capture with no
    /// palette token stays plain.
    func color(for capture: String, palette: SyntaxPalette) -> DynamicColor? {
        let components = capture.split(separator: ".")
        guard let base = components.first else { return nil }
        let sub = components.count > 1 ? components[1] : nil
        switch base {
        case "keyword":
            return sub == "operator" ? palette.operator : palette.keyword
        case "string", "embedded":
            return palette.string
        case "number", "constant", "boolean":
            return palette.number
        case "comment":
            return palette.comment
        case "tag":
            return palette.tag
        case "attribute", "property", "label":
            return palette.attribute
        case "function":
            return palette.function
        case "constructor", "type":
            return palette.type
        case "operator", "escape":
            return palette.operator
        case "punctuation", "delimiter":
            return palette.punctuation
        case "variable":
            // `self`, `this`, `$!` read as keywords; ordinary variables are the
            // body of the code and keep the plain colour.
            return sub == "builtin" ? palette.keyword : nil
        default:
            return nil
        }
    }

    /// Builds (once) and caches the grammar's language and highlight query.
    ///
    /// Only `highlights.scm` is read: the packages also ship locals, injections,
    /// folds and outline queries, none of which this editor uses, and loading
    /// them all would let one unparseable file take a whole language down to
    /// plain. A missing bundle or query is a packaging bug rather than user
    /// error, so it is logged once and the language falls back.
    private func highlighting(for grammar: Grammar) -> Highlighting? {
        if let cached = highlighters[grammar] { return cached }
        guard let language = Self.language(for: grammar),
            let query = Self.highlightQuery(for: grammar, language: language)
        else {
            AppLogger.warn(
                "tree-sitter grammar unavailable", category: "Editor",
                fields: ["language": grammar.rawValue]
            )
            return nil
        }
        let highlighting = Highlighting(language: language, query: query)
        highlighters[grammar] = highlighting
        return highlighting
    }

    private static func language(for grammar: Grammar) -> Language? {
        switch grammar {
        case .swift: Language(tree_sitter_swift())
        case .typescript: Language(tree_sitter_typescript())
        case .tsx: Language(tree_sitter_tsx())
        case .cLanguage: Language(tree_sitter_c())
        case .cpp: Language(tree_sitter_cpp())
        case .java: Language(tree_sitter_java())
        case .go: Language(tree_sitter_go())
        case .rust: Language(tree_sitter_rust())
        case .html: Language(tree_sitter_html())
        case .json: Language(tree_sitter_json())
        case .bash: Language(tree_sitter_bash())
        case .python: Language(tree_sitter_python())
        case .ruby: Language(tree_sitter_ruby())
        case .php: Language(tree_sitter_php())
        case .csharp: Language(tree_sitter_c_sharp())
        case .css: Language(tree_sitter_css())
        case .haskell: Language(tree_sitter_haskell())
        case .kotlin: Language(tree_sitter_kotlin())
        case .yaml: Language(tree_sitter_yaml())
        case .lua: Language(tree_sitter_lua())
        case .xml: Language(tree_sitter_xml())
        }
    }

    /// Loads the packaged `highlights.scm`.
    ///
    /// The queries sit either directly inside the bundle or under
    /// `Contents/Resources`, depending on how the bundle was built, so both
    /// layouts are tried.
    private static func highlightQuery(for grammar: Grammar, language: Language) -> Query? {
        guard let bundle = Bundle.main.url(forResource: grammar.bundleName, withExtension: "bundle")
        else { return nil }
        for relative in grammar.queryDirectories {
            let url =
                bundle
                .appendingPathComponent(relative, isDirectory: true)
                .appendingPathComponent("highlights.scm")
            if FileManager.default.fileExists(atPath: url.path),
                let query = try? Query(language: language, url: url)
            {
                return query
            }
        }
        return nil
    }

    /// A parser is reusable across parses; one per grammar keeps the language
    /// set once instead of on every block.
    private func parser(for grammar: Grammar, highlighting: Highlighting) -> Parser? {
        if let cached = parsers[grammar] { return cached }
        let parser = Parser()
        do {
            try parser.setLanguage(highlighting.language)
        } catch {
            AppLogger.warn(
                "tree-sitter rejected the language", category: "Editor",
                fields: ["language": grammar.rawValue]
            )
            return nil
        }
        parsers[grammar] = parser
        return parser
    }
}
