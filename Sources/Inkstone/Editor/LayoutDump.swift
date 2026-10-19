import AppKit
import Foundation

/// Headless layout geometry dump: `Inkstone --dump-layout <file>`.
///
/// The App side of the render-parity comparison (see
/// `.agents/skills/render-parity/`): parse a Markdown file, run the same
/// builder the editor uses, lay it out offscreen in a plain
/// NSLayoutManager/NSTextContainer pair — no window, no `NSApplication.run` —
/// and write the geometry the editor would render as JSON for the comparator.
///
/// Read-only by design: the text geometry comes straight from the layout
/// manager, and the decoration geometry (markers, chips, bars, rules) from the
/// same helpers `BlockDecorator.paint` uses, so what is exported is exactly
/// what would be painted. Nothing here mutates a rendering path.
///
/// Determinism: the text container is the given width (the pipeline passes the
/// reference render's effective content width) rather than a window size, so
/// wrapping matches the baseline regardless of any window.
@MainActor
enum LayoutDump {
    struct Meta: Codable {
        var source: String
        var width: CGFloat
        var theme: String
        var generator: String
    }

    /// One visible line fragment. Coordinates are container-relative, top-down,
    /// shifted so the first line's top is 0. The JSON keys stay short (`i`,
    /// `x`, `y`…) because the comparator consumes them literally.
    struct DumpLine: Codable {
        var index: Int
        var top: CGFloat
        var bottom: CGFloat
        var left: CGFloat
        var right: CGFloat
        var block: Int
        /// The innermost nested scope owning the row (a quote level, a list
        /// child) when one exists — the comparator splits blocks on it so the
        /// nested structures pair with the reference's nested elements.
        var subBlock: Int?
        var kind: String
        var depth: Int
        var headIndent: CGFloat
        var spacingBefore: CGFloat
        var lineHeight: CGFloat
        var text: String

        enum CodingKeys: String, CodingKey {
            case index = "i", top, bottom, left, right, block, subBlock = "sub"
            case kind, depth, headIndent, spacingBefore, lineHeight, text
        }
    }

    struct DumpMarker: Codable {
        var line: Int
        var shape: String
        var centerX: CGFloat
        var centerY: CGFloat
        var size: CGFloat
        var lineWidth: CGFloat
        var text: String?

        enum CodingKeys: String, CodingKey {
            case line, shape
            case centerX = "centerX"
            case centerY = "centerY"
            case size, lineWidth, text
        }
    }

    struct DumpChip: Codable {
        var line: Int
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        /// The chip run's font size and its ascender-descender box: the height
        /// is derived from both, so a divergence points at the font actually
        /// measured (a CJK fallback attribute instead of the mono face, say).
        var fontSize: CGFloat
        var fontBox: CGFloat

        enum CodingKeys: String, CodingKey {
            case line, x, y
            case width = "w"
            case height = "h"
            case fontSize = "fs"
            case fontBox = "fb"
        }
    }

    /// Quote bars, heading rules and thematic breaks — one painted rect each.
    struct DumpBar: Codable {
        var line: Int
        var kind: String
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat

        enum CodingKeys: String, CodingKey {
            case line, kind, x, y
            case width = "w"
            case height = "h"
        }
    }

    struct Dump: Codable {
        var meta: Meta
        var lines: [DumpLine]
        var markers: [DumpMarker]
        var chips: [DumpChip]
        var bars: [DumpBar]
    }

    /// Runs the dump from raw command-line arguments. Returns the exit status.
    static func run(_ arguments: [String]) -> Int32 {
        guard let path = arguments.firstIndex(of: "--dump-layout").map({ arguments[$0 + 1] })
        else {
            fputs("usage: Inkstone --dump-layout <file.md> [--width N] [--theme id] [--out path]\n", stderr)
            return 2
        }
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count
            else { return nil }
            return arguments[index + 1]
        }
        let width = CGFloat(value("--width").flatMap(Double.init) ?? 860)
        let themeID = value("--theme") ?? "github"
        let out = value("--out")

        let source: String
        do {
            source = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            fputs("cannot read \(path): \(error)\n", stderr)
            return 2
        }

        // Bundled faces must resolve before anything measures text.
        FontRegistration.registerBundledFonts()
        let theme = BuiltInTheme.theme(named: themeID) ?? BuiltInTheme.github
        let document = BlockParser.parse(source)
        let context = LayoutContext(
            containerWidth: width,
            imageBaseDirectory: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        )
        let output = AttributedBuilder(theme: theme, context: context).build(document)

        let storage = NSTextStorage(attributedString: output.attributed)
        let manager = NSLayoutManager()
        // The marker hider is what makes hidden syntax zero-advance, exactly as
        // in the live editor — without it every hidden run advances and the
        // exported geometry drifts right of what would be painted.
        let markerHider = MarkerHider()
        markerHider.listItemSpacing = theme.listItemSpacing
        markerHider.quoteLevelSpacing = theme.blockMargin
        manager.delegate = markerHider
        let container = NSTextContainer(
            size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        // Matches the live editor's container setup (MarkdownTextView): no
        // fragment padding, so line rects start at the text column.
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        _ = manager.glyphRange(for: container)

        struct Fragment {
            var rect: NSRect
            var used: NSRect
            var charRange: NSRange
            var blockID: Int
            var subBlockID: Int?
            var kind: String
            /// The visual owner's own kind, before the sub-scope's kind
            /// (if any) overrides it: a quote's zero-width blank rows are
            /// paragraph margins, not rendered rows, and only the owner's
            /// kind identifies them as such.
            var rawKind: String
            var depth: Int
        }
        var fragments: [Fragment] = []
        var debugRaw = arguments.contains("--debug-fragments")
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) {
            rect, used, _, glyphRange, _ in
            let charRange = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard charRange.length > 0, charRange.location < storage.length else { return }
            // rect.height alone cannot reject the row yet: a thematic break's
            // collapsed row is decided after the block kind is known below.
            guard rect.width >= 0 else { return }
            if debugRaw {
                let text = (storage.string as NSString).substring(with: charRange)
                    .replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\r", with: "")
                let style = storage.attribute(.paragraphStyle, at: charRange.location, effectiveRange: nil)
                    as? NSParagraphStyle
                let hidden = MarkdownAttribute.isHidden(storage, at: charRange.location)
                let styleNote = style.map {
                    " maxLH=\($0.maximumLineHeight) spB=\($0.paragraphSpacingBefore) headInd=\($0.headIndent)"
                } ?? " no-style"
                let message =
                    "frag y=\(rect.minY)...\(rect.maxY) used=\(used.minY)...\(used.maxY) "
                    + "w=\(rect.width)/\(used.width) chars=\(charRange.location)..\(NSMaxRange(charRange)) '\(text.prefix(30))'"
                    + styleNote
                    + (hidden ? " [hidden]" : "")
                    + "\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
            // The fragment may START with boundary characters (the separator
            // newline a glued thematic break lays out behind) that carry no
            // block attributes; probe forward to the block's own first char.
            func attribute(_ key: NSAttributedString.Key) -> Any? {
                storage.attribute(key, at: probeLocation, effectiveRange: nil)
            }
            var probeLocation = charRange.location
            while probeLocation < NSMaxRange(charRange),
                storage.attribute(MarkdownAttribute.block, at: probeLocation, effectiveRange: nil) == nil
            { probeLocation += 1 }
            guard probeLocation < NSMaxRange(charRange),
                let blockID = attribute(MarkdownAttribute.block) as? Int
            else { return }
            // A row scoped to a child that claims its own rows in the
            // reference's model (a `pre`/`table` element, a list item) reports
            // the child's kind and pairs as its own block. A nested paragraph
            // or quote is claimed by its container and keeps the container's
            // kind.
            let selfClaiming: Set<String> = [
                BlockKind.fences.rawValue, BlockKind.indentedCode.rawValue,
                BlockKind.table.rawValue, BlockKind.listItem.rawValue,
                BlockKind.taskItem.rawValue, BlockKind.mathBlock.rawValue,
                BlockKind.htmlBlock.rawValue, BlockKind.toc.rawValue,
            ]
            let subKind = storage.attribute(MarkdownAttribute.subKind, at: probeLocation, effectiveRange: nil)
                as? String
            let rawKind = attribute(MarkdownAttribute.blockKind) as? String
            let kind = subKind.flatMap { selfClaiming.contains($0) ? $0 : nil }
                ?? rawKind
            guard let kind else { return }
            // The boundary hairline filter below must not eat a thematic
            // break's collapsed row: the painted 2pt rule IS the block's whole
            // visual, so the kind has to decide before the height does.
            guard rect.height > 0.5 || kind == BlockKind.hr.rawValue else { return }
            fragments.append(
                Fragment(
                    rect: rect, used: used, charRange: charRange, blockID: blockID,
                    subBlockID: attribute(MarkdownAttribute.subBlock) as? Int,
                    kind: kind, rawKind: rawKind ?? "",
                    depth: attribute(MarkdownAttribute.blockDepth) as? Int ?? 0
                )
            )
        }
        guard !fragments.isEmpty else {
            fputs("no layout produced for \(path)\n", stderr)
            return 1
        }

        // Container coordinates for a standalone container are top-down; guard
        // the assumption once instead of trusting it, then shift to first-line
        // origin so both sides of the comparison share a coordinate system.
        guard let firstFragment = fragments.first, let lastFragment = fragments.last else {
            fputs("no layout produced for the document\n", stderr)
            return 1
        }
        let topDown = lastFragment.rect.minY >= firstFragment.rect.minY
        let originY = fragments.map(\.rect.minY).min() ?? 0
        let originX = fragments.map(\.rect.minX).min() ?? 0
        func normalize(_ rect: NSRect) -> NSRect {
            let y = topDown ? rect.minY - originY : originY + originY - rect.maxY
            return NSRect(x: rect.minX - originX, y: y, width: rect.width, height: rect.height)
        }

        var lines: [DumpLine] = []
        var markers: [DumpMarker] = []
        var chips: [DumpChip] = []
        var bars: [DumpBar] = []
        for fragment in fragments {
            let rect = normalize(fragment.rect)
            let used = normalize(fragment.used)
            // The FRAGMENT rect includes the boundary hairline's spacing; the
            // USED rect is the rendered row. A fragment of entirely hidden
            // glyphs (used width and height ~0 — a glued marker, a boundary
            // hairline, a fence delimiter row) is not a rendered row — except
            // a thematic break's, whose painted 2pt rule IS the block's whole
            // visual. The strut (the style's fixed line height at the row's
            // first character) decides: a zero-width row on a collapsed strut
            // can never carry visible glyphs, no matter how much line spacing
            // a delegate stacks on top of it.
            let strut =
                (storage.attribute(
                    .paragraphStyle, at: fragment.charRange.location, effectiveRange: nil
                ) as? NSParagraphStyle)?.maximumLineHeight ?? rect.height
            guard used.width > 0.5 || used.height > 0.5 || strut > 0.5
                || fragment.kind == BlockKind.hr.rawValue
            else { continue }
            // A quote's zero-width blank row (the bare `>` line between the
            // quote's children) is the paragraph margin, not a rendered row -
            // the reference has no row there either.
            if used.width <= 0.5, fragment.rawKind == BlockKind.blockquote.rawValue {
                continue
            }
            let style =
                storage.attribute(
                    .paragraphStyle, at: fragment.charRange.location, effectiveRange: nil
                ) as? NSParagraphStyle
            // The fragment rect includes `spacingBefore` (TextKit puts it above
            // the paragraph's first line) and any glyph overflow past the fixed
            // line height; the used rect's top can sit lower than the line box
            // when a row's only visible glyphs are smaller than the body font
            // (a list row of nothing but a code chip). The line BOX is
            // fragment.minY + paragraph-start spacing … + lineHeight — that is
            // the engine-independent geometry the comparator aligns.
            let spacingBefore = style?.paragraphSpacingBefore ?? 0
            let isParagraphStart =
                fragment.charRange.location == 0
                || (storage.string as NSString).substring(
                    with: NSRange(location: fragment.charRange.location - 1, length: 1)
                ) == "\n"
            let contentTop = rect.minY + (isParagraphStart ? spacingBefore : 0)
            let lineHeight = style?.maximumLineHeight ?? rect.height
            let text = (storage.string as NSString).substring(with: fragment.charRange)
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "⏎")
            // The used rect can be shorter than the line box when a row's only
            // glyphs are small (an empty boundary line, a chip-only row, a
            // table cell): the line box height still belongs to the row.
            let lineBottom = max(used.maxY, contentTop + lineHeight)
            lines.append(
                DumpLine(
                    index: lines.count, top: contentTop, bottom: lineBottom,
                    left: used.minX, right: used.maxX,
                    block: fragment.blockID, subBlock: fragment.subBlockID, kind: fragment.kind,
                    depth: fragment.depth,
                    headIndent: style?.headIndent ?? 0,
                    spacingBefore: spacingBefore,
                    lineHeight: lineHeight,
                    text: String(text.prefix(120))
                )
            )
            let lineIndex = lines.count - 1

            // Decoration plans, merged over the line's two scopes exactly like
            // BlockDecorator.draw does.
            var plans: [(plan: DecorationPlan, subScoped: Bool)] = []
            if let subBlockID = fragment.subBlockID, let nested = output.decorations[subBlockID] {
                plans += nested.map { ($0, true) }
            }
            if let blockPlans = output.decorations[fragment.blockID] {
                plans += blockPlans.map { ($0, false) }
            }
            let painted =
                storage.attribute(
                    MarkdownAttribute.painted, at: fragment.charRange.location,
                    effectiveRange: nil
                ) as? Bool == true

            if !painted,
                plans.contains(where: { plan, _ in
                    if case .inlineCode = plan { return true }
                    return false
                })
            {
                for chip in BlockDecorator.inlineCodeChipRuns(
                    theme: theme,
                    storage: storage, manager: manager, container: container,
                    lineCharRange: fragment.charRange
                ) {
                    let normalized = normalize(chip.rect)
                    chips.append(
                        DumpChip(
                            line: lineIndex, x: normalized.minX, y: normalized.minY,
                            width: normalized.width, height: normalized.height,
                            fontSize: chip.fontSize, fontBox: chip.fontBox
                        )
                    )
                }
            }

            for (plan, subScoped) in plans {
                switch plan {
                case .listMarker(let text, let markerWidth, _):
                    let origin = subScoped ? (fragment.subBlockID ?? fragment.blockID) : fragment.blockID
                    guard
                        BlockDecorator.markerIsOnLine(
                            planOrigin: origin, lineCharRange: fragment.charRange,
                            in: output, storage: storage
                        )
                    else { break }
                    let geometry = BlockDecorator.listMarkerGeometry(
                        text: text, width: markerWidth, lineRect: rect, theme: theme
                    )
                    let shape: String
                    let glyph: String?
                    switch geometry.shape {
                    case .disc:
                        shape = "disc"
                        glyph = nil
                    case .ring:
                        shape = "ring"
                        glyph = nil
                    case .square:
                        shape = "square"
                        glyph = nil
                    case .text(let value):
                        shape = "text"
                        glyph = value
                    }
                    markers.append(
                        DumpMarker(
                            line: lineIndex, shape: shape,
                            centerX: geometry.center.x, centerY: geometry.center.y,
                            size: geometry.size, lineWidth: geometry.lineWidth, text: glyph
                        )
                    )
                case .inlineCode:
                    // Chips are collected once per line below the plans loop:
                    // the owner accumulates every descendant's inline-code plan,
                    // so iterating plans would repeat the same rects.
                    break
                case .quoteBar(_, let barWidth, _):
                    bars.append(
                        DumpBar(
                            line: lineIndex, kind: "quoteBar", x: rect.minX, y: rect.minY,
                            width: barWidth, height: rect.height
                        )
                    )
                case .headingRule:
                    bars.append(
                        DumpBar(
                            line: lineIndex, kind: "headingRule", x: rect.minX,
                            y: rect.maxY - EditorMetrics.hairline, width: rect.width,
                            height: EditorMetrics.hairline
                        )
                    )
                case .horizontalRule(_, let ruleHeight):
                    bars.append(
                        DumpBar(
                            line: lineIndex, kind: "horizontalRule", x: rect.minX,
                            y: rect.midY - ruleHeight / 2, width: rect.width, height: ruleHeight
                        )
                    )
                    // The rule's painted box is the block's real extent.
                    lines[lineIndex].bottom = lines[lineIndex].top + ruleHeight
                case .taskCheckbox(_, let checkboxWidth):
                    guard
                        BlockDecorator.markerIsOnLine(
                            planOrigin: subScoped ? (fragment.subBlockID ?? fragment.blockID) : fragment.blockID,
                            lineCharRange: fragment.charRange, in: output, storage: storage
                        )
                    else { break }
                    let side: CGFloat = 12
                    bars.append(
                        DumpBar(
                            line: lineIndex, kind: "taskCheckbox",
                            x: rect.minX + checkboxWidth - side - 4,
                            y: rect.midY - side / 2, width: side, height: side
                        )
                    )
                case .codeBlock, .alertBox, .tocPlaceholder, .tocEntries, .emojiGlyph,
                    .frontMatterTable, .tableGrid, .inlineImage:
                    // Painted-block chrome (tables, TOC, front matter) and fenced
                    // code boxes are phase 2; their text rows are already dumped.
                    continue
                }
            }
        }

        let dump = Dump(
            meta: Meta(
                source: (path as NSString).lastPathComponent, width: width,
                theme: theme.identifier, generator: "inkstone-dump"
            ),
            lines: lines, markers: markers, chips: chips, bars: bars
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(dump)
        } catch {
            fputs("cannot encode dump: \(error)\n", stderr)
            return 2
        }
        if let out {
            do {
                try data.write(to: URL(fileURLWithPath: out))
            } catch {
                fputs("cannot write \(out): \(error)\n", stderr)
                return 2
            }
        } else {
            FileHandle.standardOutput.write(data)
        }
        return 0
    }
}
