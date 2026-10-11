import Foundation

/// The kinds of inline (span-level) Markdown syntax.
///
/// The list mirrors the original's inline lexer output (`md-inline` attribute
/// values) so behaviour can be diffed against the original one construct at a
/// time.
public enum InlineKind: String, Hashable, Sendable {
    case text
    case strong
    case em
    case underline
    case strike
    case highlight
    case code
    case link
    case image
    case autolink
    case refLink
    case refImage
    case footnoteRef
    case inlineMath
    case sub
    case sup
    case emoji
    case html
    case ruby
    case hardBreak
    case softBreak
    case escape
    case entity

    /// Whether the construct can contain further inline children.
    var isContainer: Bool {
        switch self {
        case .text, .code, .image, .autolink, .emoji, .hardBreak, .softBreak, .escape,
            .entity, .inlineMath, .footnoteRef:
            return false
        case .strong, .em, .underline, .strike, .highlight, .link, .refLink, .refImage,
            .sub, .sup, .html, .ruby:
            return true
        }
    }

    /// Whether this node's source is a leaf payload rather than inline content.
    var isLeafPayload: Bool {
        switch self {
        case .text, .code, .inlineMath, .emoji, .autolink, .escape, .entity, .image,
            .hardBreak, .softBreak, .footnoteRef:
            return true
        default:
            return false
        }
    }
}

/// One inline node.
///
/// Every node stores its own delimiters verbatim in `prefix`/`suffix`, and leaf
/// payloads verbatim in `payload`. That makes `verbatim` an exact
/// reconstruction of the original bytes for *any* syntax the lexer recognises,
/// which is what the round-trip guarantee rests on: concatenating
/// `prefix + children.verbatim + suffix` (or `payload`) always reproduces the
/// input slice.
///
/// Known delimiters:
///
///     strong      prefix "**"  suffix "**"      children = content
///     link        prefix "["   suffix "](url \"title\")"
///     code        prefix "`"xN suffix "`"xN     payload = body
///     inlineMath  prefix "$"   suffix "$"       payload = body
///     hardBreak   prefix "  \n" suffix ""       payload = ""
public struct InlineNode: Hashable, Sendable {
    public var kind: InlineKind
    /// Opening delimiter, verbatim.
    public var prefix: String = ""
    /// Closing delimiter, verbatim. For links this is `](dest "title")`.
    public var suffix: String = ""
    /// Body for leaf-payload kinds, verbatim.
    public var payload: String = ""
    /// The source text this node occupies, when it differs from `prefix + payload +
    /// suffix`.
    ///
    /// Only code spans need it: CommonMark strips one leading and trailing space from a
    /// space-padded code body, but that is a rule about the *rendered* content. The
    /// buffer has to stay byte-identical to the file, so the padding stays in the
    /// source and is dropped only when the code is drawn.
    public var rawBody: String?
    public var children: [InlineNode] = []
    /// Kind-specific data: link destination and title, emoji name, etc.
    public var attributes: Attributes = .init()

    public struct Attributes: Hashable, Sendable {
        public var destination: String?
        public var title: String?
        /// Name for `.emoji` (without the surrounding colons).
        public var name: String?
        /// Reference label for `.refLink` / `.refImage` / `.footnoteRef`.
        public var reference: String?
        /// Ordered-list numbering is synthesised at render time; recorded here so
        /// the writer can reproduce the original marker.
        public var isContainerText: Bool { false }
    }

    init(
        _ kind: InlineKind,
        prefix: String = "",
        suffix: String = "",
        payload: String = "",
        children: [InlineNode] = [],
        attributes: Attributes = .init(),
        rawBody: String? = nil
    ) {
        self.kind = kind
        self.prefix = prefix
        self.suffix = suffix
        self.payload = payload
        self.children = children
        self.attributes = attributes
        self.rawBody = rawBody
    }

    public static func text(_ value: String) -> InlineNode {
        InlineNode(.text, payload: value)
    }

    /// The exact original text this node was parsed from.
    public var verbatim: String {
        if let rawBody {
            return prefix + rawBody + suffix
        }
        if kind.isLeafPayload {
            return prefix + payload + suffix
        }
        // A container with no children but a payload is a bare autolinked URL,
        // which the lexer records in `payload` with empty delimiters.
        if children.isEmpty, !payload.isEmpty {
            return prefix + payload + suffix
        }
        return prefix + children.map(\.verbatim).joined() + suffix
    }

    /// Plain text with all syntax removed - what search, word count, outline and
    /// plain-text copy should see.
    public var plainText: String {
        switch kind {
        case .text, .escape, .softBreak:
            return payload
        case .hardBreak:
            return "\n"
        case .entity:
            return InlineNode.decodeEntity(payload)
        case .code, .inlineMath, .emoji, .autolink:
            return payload
        case .image, .refImage:
            return attributes.name ?? payload
        case .link, .refLink:
            // A bare autolinked URL carries its text in `payload`; a bracketed
            // link carries it in children.
            let inner = children.map(\.plainText).joined()
            return inner.isEmpty ? payload : inner
        default:
            return children.map(\.plainText).joined()
        }
    }

    /// Depth-first walk including this node.
    public func forEachNode(_ body: (InlineNode) -> Void) {
        body(self)
        for child in children {
            child.forEachNode(body)
        }
    }

    /// Decodes the five entities that matter for copy-as-plain-text and word
    /// counting; anything else passes through unchanged.
    public static func decodeEntity(_ body: String) -> String {
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return " "
        default: return "&" + body + ";"
        }
    }
}

extension Array where Element == InlineNode {
    public var verbatim: String { map(\.verbatim).joined() }
    public var plainText: String { map(\.plainText).joined() }

    public func forEachNode(_ body: (InlineNode) -> Void) {
        for node in self {
            node.forEachNode(body)
        }
    }
}
