import AppKit
import Foundation
import SwiftUI

/// Per-block typography and paragraph styling.
///
/// TextKit 1's linear text flow cannot express everything a rendered block needs,
/// so this type splits into two groups:
///
///   * what `NSParagraphStyle` can express (indentation, tab stops, line height,
///     paragraph spacing) and goes straight into the attributed string;
///   * what needs drawing (rules, quote bars, code-block chrome, list bullets)
///     and is emitted as a `DecorationPlan` for `MarkdownTextView.draw(_:)`.
struct BlockStyle {
    /// `var` rather than `let` because an inline style is applied by deriving a new
    /// `BlockStyle` with a bolder or italic font - see `InlineStyle.Overrides.applied(to:)`.
    var font: NSFont
    var textColor: NSColor
    /// Extra attributes layered under everything else.
    var base: [NSAttributedString.Key: Any] = [:]
    /// Instructions for the decoration layer.
    var decoration: [DecorationPlan] = []

    /// Base attributes for a run of body text.
    static func body(theme: EditorTheme) -> BlockStyle {
        BlockStyle(
            font: EditorFont.nsBody(theme: theme),
            textColor: theme.text.nsColor,
            base: [:],
            decoration: []
        )
    }

    static func paragraph(theme: EditorTheme) -> BlockStyle {
        var style = BlockStyle.body(theme: theme)
        style.base[.paragraphStyle] = NSParagraphStyle.markdownBody(
            lineHeight: theme.bodyLineHeight * theme.bodyFontSize,
            spacing: theme.blockMargin
        )
        return style
    }

    static func heading(theme: EditorTheme, level: Int) -> BlockStyle {
        let font = EditorFont.nsHeading(
            theme: theme, level: level, weight: nsWeight(theme.headingWeight(level))
        )
        let lineHeight = theme.headingLineHeight(level)
        var style = BlockStyle(
            font: font,
            textColor: theme.headingTextColor?.nsColor ?? theme.text.nsColor
        )
        var after = theme.headingMargin
        if let rule = theme.headingRule(level) {
            // The ruled heading's after-spacing. The preview's h1/h2 carry
            // `padding-bottom: 0.3em` above their border-bottom, so the
            // border sits 0.3em below the content-box (line-box) bottom and
            // the next content starts one border plus one collapsed margin
            // below the border. The App anchors the rule to the engine
            // baseline (see DecorationPlan.headingRule) and lets the layout
            // delegate trim the after-spacing per row
            // (`MarkerHider.lineSpacingAfterGlyphAt`): the style applies the
            // LATIN-strut assumption — the attribute font's descent is the
            // largest a heading row mixes — and CJK rows, whose fallback face
            // descends less, hand the difference back additively. The
            // builder's collapse accounting keeps reporting the plain margin
            // for the heading, so the extra rides through uniformly: the gap
            // after the heading is `margin + 1 + padding` minus the
            // engine/strut baseline delta, exactly the reference's structure.
            let padding = 0.3 * font.pointSize
            // The baseline→rule distance (see DecorationPlan.headingRule):
            // the strut's box-bottom distance `(H − asc − desc)/2` plus the
            // padding the border sits below the box.
            let baselineGap = (lineHeight - font.ascender - font.descender) / 2 + padding
            style.decoration.append(
                .headingRule(color: rule.nsColor, baselineGap: baselineGap)
            )
            style.base[MarkdownAttribute.headingRuleGap] = baselineGap
            // The descent the after-spacing assumes: the mono face at the
            // heading size — the largest descent a ruled heading row can mix
            // (the chip's mono run descends past both the text face and its
            // CJK fallback). The layout delegate trims the difference for
            // rows whose visible faces descend less.
            let descentModel = -EditorFont.nsMono(theme: theme, size: font.pointSize).descender
            style.base[MarkdownAttribute.headingRuleAttrDesc] = descentModel
            after = baselineGap
                - descentModel.rounded()
                + theme.headingMargin + EditorMetrics.hairline
        }
        style.base[.paragraphStyle] = NSParagraphStyle.markdownHeading(
            lineHeight: lineHeight,
            margin: theme.headingMargin,
            after: after
        )
        return style
    }

    static func listItem(theme: EditorTheme, ordered: Bool, depth: Int, marker: String) -> BlockStyle {
        var style = BlockStyle(
            font: EditorFont.nsBody(theme: theme),
            textColor: theme.text.nsColor
        )
        // `ul, ol { padding-left: 30px }` scaled by nesting.
        let indent = theme.listIndent * CGFloat(max(depth, 1))
        style.base[.paragraphStyle] = NSParagraphStyle.markdownListItem(
            indent: indent,
            // Only feeds the paragraph style's tab stop now; the marker is drawn by
            // the decoration layer right against the text column.
            markerWidth: max(theme.listIndent * 0.28, 14),
            lineHeight: theme.bodyLineHeight * theme.bodyFontSize
        )
        style.decoration.append(
            .listMarker(text: marker, width: indent, alignment: .right)
        )
        return style
    }

    static func taskItem(theme: EditorTheme, depth: Int, checked: Bool) -> BlockStyle {
        var style = BlockStyle(
            font: EditorFont.nsBody(theme: theme),
            textColor: theme.text.nsColor
        )
        // The checkbox cell (12pt box + 8pt of gaps) lives inside the item's
        // indent: the text column starts after it, as the reference's inline
        // checkbox lays out.
        let indent = theme.listIndent * CGFloat(max(depth, 1)) + 20
        style.base[.paragraphStyle] = NSParagraphStyle.markdownListItem(
            indent: indent,
            markerWidth: max(theme.listIndent * 0.28, 14),
            lineHeight: theme.bodyLineHeight * theme.bodyFontSize
        )
        style.decoration.append(.taskCheckbox(checked: checked, width: indent))
        return style
    }

    static func codeFence(theme: EditorTheme) -> BlockStyle {
        var style = BlockStyle(
            font: EditorFont.nsMono(theme: theme, size: theme.codeFontSize),
            textColor: theme.codeText.nsColor
        )
        // `code { line-height: 1.357em }` — the preview's code rows pitch at
        // the code element's own line height, not the body's.
        let paragraphStyle = NSParagraphStyle.markdownCode(
            lineHeight: theme.codeFontSize * 1.357,
            padding: theme.codePaddingLeft ?? theme.codePadding
        )
        // The painted box grows by the padding insets (top 8 / bottom 6); the
        // exported box carries the same growth. The rows themselves carry no
        // spacing: the reference's `pre` is one paragraph and its lines pitch
        // at the bare line height - a spacing here opened every pair of rows
        // by the padding (measured 29.04pt pitch against 23.04).
        style.base[.paragraphStyle] = paragraphStyle
        style.decoration.append(
            .codeBlock(
                background: theme.codeBlockBackground.nsColor,
                radius: EditorMetrics.radiusSmall,
                border: theme.codeBorder?.nsColor,
                topInset: theme.codePaddingTop,
                bottomInset: theme.codePaddingBottom
            )
        )
        return style
    }

    /// Marker runs, derived from the block they belong to.
    ///
    /// The paragraph style is inherited from the block **on purpose**. TextKit takes a
    /// line's height from the paragraph style of the run at the *start* of the line,
    /// and a block marker is always the first thing on its line. Giving markers their
    /// own 0.01pt line height therefore collapsed every list item, table row and
    /// heading on top of the previous one. The zero width comes from
    /// `GlyphProperty.null` in `MarkerHider`, not from the paragraph style, so nothing
    /// is lost by inheriting.
    static func collapsed(from base: BlockStyle, theme: EditorTheme) -> BlockStyle {
        var style = base
        style.font = EditorFont.nsMono(theme: theme, size: theme.codeFontSize)
        style.decoration = []
        return style
    }

    static func table(theme: EditorTheme) -> BlockStyle {
        var style = BlockStyle(
            font: EditorFont.nsBody(theme: theme),
            textColor: theme.text.nsColor
        )
        style.base[.paragraphStyle] = NSParagraphStyle.markdownBody(
            lineHeight: theme.bodyLineHeight * theme.bodyFontSize,
            spacing: theme.blockMargin
        )
        // No background and no per-line chrome here: the decorator draws the header
        // stripe and the borders for the table as a whole, because it knows the row
        // height and the column geometry and a line fragment knows neither.
        return style
    }

    static func horizontalRule(theme: EditorTheme) -> BlockStyle {
        var style = BlockStyle(
            font: EditorFont.nsBody(theme: theme),
            textColor: theme.text.nsColor
        )
        style.base[.paragraphStyle] = NSParagraphStyle.markdownRuleLine(spacingBefore: theme.ruleMargin)
        style.decoration.append(.horizontalRule(color: theme.rule.nsColor, height: 2))
        return style
    }

    static func mathBlock(theme: EditorTheme) -> BlockStyle {
        let size = theme.codeFontSize + 2
        var style = BlockStyle(
            font: EditorFont.nsMath(size: size),
            textColor: theme.text.nsColor
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1
        paragraph.minimumLineHeight = theme.bodyLineHeight * size
        paragraph.maximumLineHeight = theme.bodyLineHeight * size
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = theme.blockMargin
        paragraph.lineBreakMode = .byWordWrapping
        // Display maths is centred; an inline run of the same text would not be, but
        // inline maths is styled by `InlineStyle`, not here.
        paragraph.alignment = .center
        style.base[.paragraphStyle] = paragraph
        style.base[.backgroundColor] = theme.codeBlockBackground.nsColor
        style.decoration.append(
            .alertBox(
                title: "", background: theme.codeBlockBackground.nsColor,
                border: theme.tableBorder.nsColor
            )
        )
        return style
    }

    static func htmlBlock(theme: EditorTheme) -> BlockStyle {
        var style = BlockStyle(
            font: EditorFont.nsMono(theme: theme, size: theme.codeFontSize),
            textColor: theme.codeText.nsColor
        )
        style.base[.paragraphStyle] = NSParagraphStyle.markdownCode(
            lineHeight: theme.bodyLineHeight * theme.codeFontSize,
            padding: theme.codePaddingLeft ?? theme.codePadding
        )
        style.decoration.append(
            .codeBlock(
                background: theme.rawBlockEditingBackground.nsColor,
                radius: EditorMetrics.radiusSmall,
                border: nil, topInset: 0, bottomInset: 0
            )
        )
        return style
    }

    static func frontMatter(theme: EditorTheme) -> BlockStyle {
        var style = BlockStyle(
            font: EditorFont.nsMono(theme: theme, size: theme.codeFontSize),
            textColor: theme.quoteText.nsColor
        )
        style.base[.paragraphStyle] = NSParagraphStyle.markdownCode(
            lineHeight: theme.bodyLineHeight * theme.codeFontSize,
            padding: theme.codePaddingLeft ?? theme.codePadding
        )
        style.base[.backgroundColor] = theme.rawBlockEditingBackground.nsColor
        return style
    }

    static func definition(theme: EditorTheme) -> BlockStyle {
        var style = BlockStyle(
            font: EditorFont.nsSystem(size: max(theme.bodyFontSize - 2, 10)), textColor: theme.quoteText.nsColor
        )
        style.base[.paragraphStyle] = NSParagraphStyle.markdownBody(
            lineHeight: theme.bodyLineHeight * max(theme.bodyFontSize - 2, 10),
            spacing: theme.blockMargin
        )
        return style
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

/// Drawing instructions for the parts of a block that `NSParagraphStyle` cannot
/// express.
///
/// TextKit 1 gives us exact line-fragment rectangles, so the decoration layer can
/// align chrome to wrapped text lines rather than to the block's nominal origin -
/// which is what makes a multi-line code block or a wrapped quote look right.
enum DecorationPlan {
    /// A heading's bottom rule (`h1 { border-bottom: 1px solid }`).
    ///
    /// `baselineGap` is the reference's baseline→rule distance, computed at
    /// build time from the heading font's own metrics: Chromium centres the
    /// strut's ascender+descender inside the fixed line box, so its baseline
    /// sits `(lineHeight − ascender − descender)/2` above the box bottom, and
    /// the rule (the border-bottom) sits at that box bottom. The App's own
    /// baseline comes from the layout delegate at paint time (TextKit clamps
    /// the line box from below — the descent side — so the engines place the
    /// same glyphs at different heights inside an identical line box, and the
    /// rule must hang off the baseline, not off the box, to visually match).
    case headingRule(color: NSColor, baselineGap: CGFloat)
    case quoteBar(color: NSColor, width: CGFloat, inset: CGFloat)
    case listMarker(text: String, width: CGFloat, alignment: NSTextAlignment)
    case taskCheckbox(checked: Bool, width: CGFloat)
    case codeBlock(
        background: NSColor, radius: CGFloat, border: NSColor?,
        topInset: CGFloat, bottomInset: CGFloat
    )
    case horizontalRule(color: NSColor, height: CGFloat)
    case inlineCode(background: NSColor?, radius: CGFloat)
    case alertBox(title: String, background: NSColor, border: NSColor)
    case tocPlaceholder(color: NSColor)
    /// A live table of contents: one painted row per heading, drawn by the
    /// decoration layer over the block's hidden `[TOC]` source - the same
    /// painted route pipe tables take, including focus revealing the source.
    case tocEntries([MarkdownDocument.Heading])
    /// An emoji shortcode paints its glyph over the hidden `:name:` source.
    /// The plan only triggers the per-block paint; ranges come from the
    /// block's `.emoji` inline nodes, so one plan covers the whole block.
    case emojiGlyph
    /// A front matter block's parsed rows, painted as a metadata table over
    /// the hidden source - the same painted route pipe tables take.
    case frontMatterTable(FrontMatterLayout)
    /// A pipe table's cells, painted by the decoration layer.
    ///
    /// The rows hold no visible glyphs; see `TableGrid` for why the columns cannot be
    /// expressed in the text at all.
    case tableGrid(TableGrid)
    /// An inline image, drawn by the decoration layer over its alt text.
    ///
    /// The buffer keeps the `![](…)` source, so this is the only way to show a picture
    /// without spending a character on it - which the source invariant forbids.
    case inlineImage(path: String, alt: String, height: CGFloat)
}

extension NSParagraphStyle {
    /// `spacing` is the gap *above* the block.
    ///
    /// `paragraphSpacingBefore`, not `paragraphSpacing`: TextKit applies the latter per
    /// line, which also opened up the wrapped lines inside a paragraph and turned a
    /// two-line paragraph into two paragraphs. Blocks are separated by explicit
    /// newlines in the buffer, so "before" lands exactly between two blocks.
    static func markdownBody(lineHeight: CGFloat, spacing: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = spacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// A copy with a taller line box, used where an inline image needs the room.
    static func withMinimumLineHeight(_ style: NSParagraphStyle, minimum height: CGFloat) -> NSParagraphStyle {
        guard height > style.maximumLineHeight,
            let copy = style.mutableCopy() as? NSMutableParagraphStyle
        else { return style }
        copy.minimumLineHeight = height
        copy.maximumLineHeight = height
        return copy
    }

    static func markdownHeading(lineHeight: CGFloat, margin: CGFloat, after: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacingBefore = margin
        // The heading's bottom margin (`h1 { margin-bottom: 1rem }`): applied
        // after the last line, like the CSS box model. The following block's
        // spacing is collapsed against it by the builder (see the boundary
        // backfill there), so the visible gap is max(bottom, top) as in CSS.
        // The ruled levels pass a reduced `after`: the rule itself consumes
        // part of it, because it hangs above the line-box bottom (see
        // `ruleBottomShrink`).
        style.paragraphSpacing = after ?? margin
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func markdownQuote(
        indent: CGFloat, lineHeight: CGFloat, spacing: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacing = spacing
        return style
    }

    static func markdownListItem(indent: CGFloat, markerWidth: CGFloat, lineHeight: CGFloat)
        -> NSParagraphStyle
    {
        let style = NSMutableParagraphStyle()
        // The marker glyphs are hidden (zero-width), and TextKit glues them into the
        // *previous* line fragment - so the item's text line lays out as a
        // continuation line and takes `headIndent`, not `firstLineHeadIndent`. Both
        // sit on the text column: the marker is drawn by the decoration layer just
        // left of it, which is what keeps the bullet-to-text gap small.
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent + markerWidth)]
        style.defaultTabInterval = markerWidth
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        // The gap below each item row (`li p { margin: .5rem 0 }` in the original's
        // base style) is NOT carried here: the item's hidden marker glyphs are
        // zero-width and glue backwards into the previous line fragment, so an item
        // paragraph's first line fragment is the *previous* item's row and TextKit
        // drops any paragraph spacing at that glued boundary. The gap comes from
        // `MarkerHider.lineSpacingAfterGlyphAt` instead, per row, after the layout
        // knows exactly where the row ends.
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }

    static func markdownCode(lineHeight: CGFloat, padding: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = padding
        style.headIndent = padding
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacing = 0
        // The reference's `#write pre { white-space: pre-wrap }` soft-wraps
        // code at the container edge (measured: a long CJK line laid out two
        // rows against the App's one) - clipping here left every long line a
        // row short. `pre-wrap` breaks between any two characters, so the
        // matching TextKit mode is per-character wrapping: word wrapping kept
        // a long ASCII run whole and packed the CJK line into one row too
        // many (measured 3 rows against the reference's 2).
        style.lineBreakMode = .byCharWrapping
        return style
    }

    /// A copy of `style` with both head indents replaced, for content that nests
    /// inside a list item and must align with the item's own text column.
    static func withHeadIndents(
        _ style: NSParagraphStyle?, indent: CGFloat,
        spacingBefore: CGFloat = 0
    ) -> NSParagraphStyle {
        guard let style, let copy = style.mutableCopy() as? NSMutableParagraphStyle else {
            let fresh = NSMutableParagraphStyle()
            fresh.firstLineHeadIndent = indent
            fresh.headIndent = indent
            fresh.paragraphSpacingBefore = spacingBefore
            return fresh
        }
        copy.firstLineHeadIndent = indent
        copy.headIndent = indent
        copy.paragraphSpacingBefore = spacingBefore
        return copy
    }

    /// A line whose entire content is replaced by a drawn decoration.
    ///
    /// Only valid for a block that occupies whole lines by itself, such as a thematic
    /// break: collapsing the line height here is what stops the hidden `---` from
    /// taking up vertical space. It must never be used for a block marker, because the
    /// marker shares its line with real text - see `collapsed(from:theme:)`.
    static func markdownRuleLine(spacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // The row IS the rule's content box (`hr { height: 2px }`): the painted
        // bar fills it exactly, so the collapsed margins around it measure from
        // the bar's edges like the reference's element box. A 0.01 strut here
        // left every gap around a rule 2pt tighter than the reference (the bar
        // painted ±1pt outside the layout flow).
        style.minimumLineHeight = 2
        style.maximumLineHeight = 2
        style.paragraphSpacing = 0
        // The block after a rule brings its own top spacing, mirroring CSS margin
        // collapsing (`hr { margin: 16px 0 }` collapses with the neighbour's own).
        style.paragraphSpacingBefore = spacingBefore
        style.lineBreakMode = .byClipping
        return style
    }
}
