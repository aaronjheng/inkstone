import AppKit
import Foundation

/// Per-inline typography.
///
/// Every entry layers onto the block's attributes, so an inline style never has to
/// restate the paragraph style, the marker colour or the block metadata.
struct InlineStyle {
    /// The attribute overrides, ready to merge onto a block's attributes.
    struct Overrides {
        var attributes: [NSAttributedString.Key: Any]

        func merged(into base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            base.merging(attributes) { _, new in new }
        }

        /// The overrides expressed as a derived block style.
        ///
        /// The recursive emit writes `.font` and `.foregroundColor` onto every run
        /// from the style it is handed, so a dictionary layered underneath is
        /// overwritten the moment a child is emitted. Applying an inline style means
        /// deriving a new `BlockStyle` and passing *that* to the children, which is
        /// what makes `**bold *inside* bold**` compose instead of the inner run
        /// silently reverting to the block's plain font.
        ///
        /// `.font` and `.foregroundColor` are lifted out of the dictionary into the
        /// struct's own fields, so they cannot be clobbered by the generic merge.
        func applied(to style: BlockStyle) -> BlockStyle {
            var result = style
            result.base = style.base.merged(attributes)
            if let font = attributes[.font] as? NSFont { result.font = font }
            if let color = attributes[.foregroundColor] as? NSColor { result.textColor = color }
            return result
        }
    }

    static func strong(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(
            attributes: [
                .font: bolder(base.font)
            ]
        )
    }

    static func em(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(attributes: [.font: italic(base.font)])
    }

    static func underline(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue])
    }

    static func strike(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(
            attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: theme.text.nsColor,
            ]
        )
    }

    static func highlight(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(
            attributes: [
                .backgroundColor: theme.codeBlockBackground.nsColor,
                .underlineColor: theme.rule.nsColor,
            ]
        )
    }

    static func `subscript`(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(attributes: baselineOffset(base.font.pointSize * -0.2))
    }

    static func superscript(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(attributes: baselineOffset(base.font.pointSize * 0.35))
    }

    static func code(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(
            attributes: [
                .font: EditorFont.nsMono(theme: theme, size: theme.codeFontSize),
                .foregroundColor: theme.inlineCodeText.nsColor,
                .backgroundColor: theme.inlineCodeBackground.nsColor,
            ]
        )
    }

    /// Inline maths gets the same face as a display block, so `$x$` inside a sentence
    /// and `$$x$$` on its own line do not read as two different notations.
    static func inlineMath(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(
            attributes: [
                .font: EditorFont.nsMath(size: theme.bodyFontSize),
                .foregroundColor: base.textColor,
            ]
        )
    }

    static func link(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(
            attributes: [
                .foregroundColor: theme.link.nsColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.link.nsColor,
            ]
        )
    }

    static func autolink(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(
            attributes: [
                .foregroundColor: theme.link.nsColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.link.nsColor,
            ]
        )
    }

    static func image(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(
            attributes: [
                .foregroundColor: theme.link.nsColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.link.nsColor,
            ]
        )
    }

    static func footnoteRef(theme: EditorTheme, base: BlockStyle) -> Overrides {
        Overrides(
            attributes: [
                .font: EditorFont.nsSystem(size: max(base.font.pointSize - 2, 9)),
                .foregroundColor: theme.link.nsColor,
                .baselineOffset: base.font.pointSize * 0.3,
            ]
        )
    }

    // MARK: Font derivation

    /// Emphasises while keeping the point size, so a bold heading stays its size.
    private static func bolder(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor
        let traits = descriptor.symbolicTraits.union(.bold)
        guard let bold = NSFont(descriptor: descriptor.withSymbolicTraits(traits), size: 0)
        else { return font }
        return bold
    }

    /// `.union` rather than a replacement: `italic` is reached with whatever font the
    /// enclosing inline styles produced, and `*emphasis*` inside `**bold**` has to come
    /// out bold-italic, not italic. `bolder` above unions for the same reason.
    private static func italic(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor
        let traits = descriptor.symbolicTraits.union(.italic)
        guard let italic = NSFont(descriptor: descriptor.withSymbolicTraits(traits), size: 0)
        else { return font }
        return italic
    }

    /// Sup- and subscript are expressed as a baseline shift; TextKit has no other
    /// way to raise or lower a run.
    private static func baselineOffset(_ offset: CGFloat) -> [NSAttributedString.Key: Any] {
        [.baselineOffset: offset]
    }
}
