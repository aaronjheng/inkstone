import SwiftUI

/// Contents of the Markdown Reference window opened from `Help`.
///
/// The menu item used to call `showHelp` with no help book registered, which
/// is a beep and nothing else. An in-app cheat sheet lists exactly the syntax
/// this editor parses - and the panes stay honest about what works.
struct MarkdownReferenceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ReferenceSection.all) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.system(size: 13, weight: .bold))
                        ForEach(section.rows) { row in
                            HStack(alignment: .top, spacing: 12) {
                                Text(row.syntax)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(minWidth: 140, alignment: .leading)
                                Text(row.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.top, 12 + AboutMetrics.titlebarClearance)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .textSelection(.enabled)
        .focusEffectDisabled()
        .accessibilityLabel("Markdown Reference")
    }
}

/// One cheat-sheet section.
private struct ReferenceSection: Identifiable {
    var id: String { title }
    var title: String
    var rows: [ReferenceRow]

    struct ReferenceRow: Identifiable {
        var id: String { syntax + detail }
        var syntax: String
        var detail: String
    }

    static let all: [ReferenceSection] = [
        ReferenceSection(
            title: "Text",
            rows: [
                .init(syntax: "**bold**", detail: "Bold (__also__)"),
                .init(syntax: "*italic*", detail: "Italic (_also_)"),
                .init(syntax: "<u>text</u>", detail: "Underline"),
                .init(syntax: "~~struck~~", detail: "Strikethrough"),
                .init(syntax: "==marked==", detail: "Highlight"),
                .init(syntax: "`code`", detail: "Inline code"),
                .init(syntax: "$x^2$", detail: "Inline math"),
                .init(syntax: "~sub~ / ^sup^", detail: "Subscript / superscript"),
                .init(syntax: ":smile:", detail: "Emoji shortcode"),
                .init(syntax: "[text](https://…)", detail: "Link, optional \"title\""),
                .init(syntax: "![alt](pic.png)", detail: "Image"),
                .init(syntax: "[^1] + [^1]: …", detail: "Footnote"),
            ]
        ),
        ReferenceSection(
            title: "Headings & Structure",
            rows: [
                .init(syntax: "# … ######", detail: "Headings 1–6"),
                .init(syntax: "> quote", detail: "Blockquote, [!NOTE] for callouts"),
                .init(syntax: "- / * / +", detail: "Bulleted list"),
                .init(syntax: "1. / 1)", detail: "Ordered list"),
                .init(syntax: "- [ ] / - [x]", detail: "Task list, click to toggle"),
                .init(syntax: "``` / ~~~", detail: "Fenced code block"),
                .init(syntax: "$$", detail: "Math block"),
                .init(syntax: "---", detail: "Horizontal rule"),
                .init(syntax: "[TOC]", detail: "Live table of contents"),
                .init(syntax: "---\ntitle: …\n---", detail: "Front matter metadata"),
            ]
        ),
        ReferenceSection(
            title: "Tables",
            rows: [
                .init(syntax: "| A | B |", detail: "Header row"),
                .init(syntax: "| --- | :-: |", detail: "Delimiter; colons align"),
                .init(syntax: "| 1 | 2 |", detail: "Body rows; edit via Paragraph → Edit Table"),
            ]
        ),
    ]
}
