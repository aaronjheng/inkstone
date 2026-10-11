import Foundation

/// Find and replace over the document model.
///
/// ## Why it walks the node tree, not the buffer
///
/// Searching the buffer would match syntax the user cannot see: the `**` around a
/// bold run, the `|` between table cells, the brackets of a link. the original solves this
/// with a CSS class that reveals the syntax of any hit; we get it for free by
/// matching only the visible text of each inline node, and recording which node each
/// hit came from.
///
/// ## Ranges are node-relative
///
/// A `Hit` carries the block and the offset within that block's *content*, not an
/// offset into the document. Mapping to a buffer range goes through `LayoutIndex`,
/// which is the only thing that knows where the buffer and the tree agree - and for
/// attachment-rendered blocks they do not agree at all, since the buffer holds one
/// character where the tree holds a whole table.
public struct NodeSearch {
    public struct Options: Sendable {
        public var caseSensitive = false
        public var wholeWord = false
        public var useRegularExpression = false
        /// The original stops collecting at this many hits.
        public var limit = 5000

        public init() {}

        public static let `default` = Options()
    }

    public struct Hit: Equatable, Sendable {
        public let blockID: Int
        /// Offset from the start of the block's content.
        public let offset: Int
        public let length: Int
        public let matchedText: String

        public init(blockID: Int, offset: Int, length: Int, matchedText: String) {
            self.blockID = blockID
            self.offset = offset
            self.length = length
            self.matchedText = matchedText
        }
    }

    public struct Results: Sendable {
        public var hits: [Hit] = []
        public var isTruncated = false

        public var isEmpty: Bool { hits.isEmpty }
        public var count: Int { hits.count }
    }

    private let options: Options

    public init(options: Options = .default) {
        self.options = options
    }

    public func find(in document: MarkdownDocument, query: String) -> Results {
        guard !query.isEmpty else { return Results() }
        var results = Results()
        let expression = try? makeExpression(for: query)

        document.blocks.forEachNode { block in
            guard results.count < options.limit else { return }
            guard !block.inlines.isEmpty else { return }
            // Front matter is metadata, and the original excludes it from search.
            guard block.kind != .frontMatter else { return }

            let plain = block.inlines.plainText
            guard !plain.isEmpty else { return }
            // `String.range(of:options:range:)` is shadowed by the Swift 6 range
            // expression overload, so bridging to NSString is what makes the
            // Foundation search available at all.
            let storage = plain as NSString
            let literalOptions: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]

            var searchRange = NSRange(location: 0, length: storage.length)
            while searchRange.length > 0, results.count < options.limit {
                var found: NSRange?
                if options.useRegularExpression, let expression {
                    found =
                        expression.firstMatch(
                            in: plain, options: [], range: searchRange
                        )?.range
                } else {
                    found = storage.range(
                        of: query, options: literalOptions, range: searchRange
                    )
                }
                guard let found, found.length > 0 else { break }
                let start = found.location
                if options.wholeWord, !isWholeWord(plain, at: start, length: found.length) {
                    searchRange = NSRange(
                        location: NSMaxRange(found),
                        length: storage.length - NSMaxRange(found)
                    )
                    continue
                }
                results.hits.append(
                    Hit(
                        blockID: block.id,
                        offset: start,
                        length: found.length,
                        matchedText: storage.substring(with: found)
                    )
                )
                searchRange = NSRange(
                    location: NSMaxRange(found),
                    length: storage.length - NSMaxRange(found)
                )
            }
            if results.count >= options.limit { results.isTruncated = true }
        }
        return results
    }

    /// Replaces every hit whose text equals the query.
    ///
    /// Replacement works on the block's inline nodes rather than on flat text, so
    /// a hit inside a bold run stays inside it and the surrounding syntax survives.
    public func replace(
        in blocks: [BlockNode], query: String, with replacement: String
    ) -> [BlockNode] {
        guard !query.isEmpty else { return blocks }
        return blocks.map { replace(in: $0, query: query, with: replacement) }
    }

    private func replace(in block: BlockNode, query: String, with replacement: String) -> BlockNode {
        var copy = block
        guard !copy.inlines.isEmpty else { return copy }
        // The original body has to be captured before the edit, because `source` is
        // an exact slice of the input and nothing else knows what it was.
        let previousBody = copy.text
        copy.inlines = replace(in: copy.inlines, query: query, with: replacement)
        guard copy.text != previousBody else { return copy }
        copy.refreshSource(from: previousBody)
        return copy
    }

    private func replace(
        in nodes: [InlineNode], query: String, with replacement: String
    ) -> [InlineNode] {
        nodes.map { node in
            var copy = node
            // Code, math, autolinks and emoji are literal payloads: they are drawn
            // verbatim and never searched, so a replace must leave them alone.
            let literal: Set<InlineKind> = [.code, .inlineMath, .autolink, .emoji]
            if !copy.payload.isEmpty, !literal.contains(copy.kind) {
                copy.payload = substitute(copy.payload, query: query, with: replacement)
            }
            if !copy.children.isEmpty {
                copy.children = replace(in: copy.children, query: query, with: replacement)
            }
            return copy
        }
    }

    private func substitute(_ text: String, query: String, with replacement: String) -> String {
        if options.useRegularExpression {
            guard let expression = try? makeExpression(for: query) else { return text }
            return expression.stringByReplacingMatches(
                in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: replacement
            )
        }
        guard !options.caseSensitive else {
            return text.replacingOccurrences(of: query, with: replacement)
        }
        var result = ""
        var cursor = 0
        let storage = text as NSString
        while cursor < storage.length {
            let found = storage.range(
                of: query, options: [.caseInsensitive],
                range: NSRange(location: cursor, length: storage.length - cursor)
            )
            guard found.location != NSNotFound else { break }
            let length = found.length
            if options.wholeWord,
                !isWholeWord(text, at: found.location, length: length)
            {
                result += storage.substring(
                    with: NSRange(location: cursor, length: found.location + length - cursor)
                )
                cursor = found.location + length
                continue
            }
            result += storage.substring(
                with: NSRange(location: cursor, length: found.location - cursor)
            )
            result += replacement
            cursor = found.location + length
        }
        result += storage.substring(with: NSRange(location: cursor, length: storage.length - cursor))
        return result
    }

    private func makeExpression(for query: String) throws -> NSRegularExpression? {
        var pattern = query
        if options.wholeWord {
            pattern = "\\b(?:" + pattern + ")\\b"
        }
        var flags: NSRegularExpression.Options = []
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: flags)
    }

    private func isWholeWord(_ text: String, at location: Int, length: Int) -> Bool {
        let characters = Array(text)
        let before = location > 0 ? characters[location - 1] : nil
        let afterIndex = location + length
        let after = afterIndex < characters.count ? characters[afterIndex] : nil
        let isWordCharacter: (Character?) -> Bool = { character in
            guard let character else { return false }
            return character.isLetter || character.isNumber || character == "_"
        }
        return !isWordCharacter(before) && !isWordCharacter(after)
    }
}
