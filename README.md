# Inkstone

Native macOS Markdown editor

## Features

- **Live WYSIWYG** — Markdown renders as you type; syntax markers collapse to zero-width glyphs and reappear under the caret, while the buffer stays byte-for-byte the source you typed
- **Faithful Round Trip** — custom CommonMark-adjacent parser with Typora extensions; tables, math blocks, HTML blocks, front matter metadata and a live `[TOC]` are painted in place over their real source
- **Focus & Typewriter Modes** — focus dims everything outside the current block; typewriter keeps the caret centred; readonly mode available
- **Input Rules & Completion** — auto-pairing of brackets and Markdown delimiters, smart punctuation, list continuation, Tab/Shift-Tab indent; `:shortcode` emoji rendered as glyphs, with path completion inside links
- **Table Editing** — insert/delete rows and columns, align columns, insert footnotes; subscript and superscript toggles in the Format menu
- **Pointer & Context Menu** — click task checkboxes to toggle, ⌘-click links to open (footnotes jump in place), right-click for Open/Copy link, quick formatting and table operations
- **Paste as Markdown** — clipboard HTML from browsers lands as Markdown source (headings, lists, tables, code, links); RTF reduces to its markers instead of leaking styled text into the buffer
- **Code Highlighting** — fenced blocks coloured by built-in tokenizers: C-like, shell, SQL, markup, CSS, YAML, INI
- **Files Panel** — folder tree of Markdown files with the current file marked; draggable divider
- **Outline Panel** — heading tree with jump-to-heading and the caret's section tracked live
- **Find & Replace** — case-sensitive, whole-word, and regex modes with a match counter
- **Quick Open** — fuzzy path search across folder roots
- **Source Mode** — a second syntax-coloured view kept in two-way sync with the rendered editor
- **Export & Print** — HTML styled by the current theme, OPML outline, Markdown, PDF; system print panel
- **Word Count** — words, characters, lines and reading-time estimate, CJK-aware; selection counts while text is selected
- **Themes** — six built-ins (GitHub, Newsprint, Night, Whitey, Gothic, Pixyll) plus JSON overrides with built-in fallback
- **Session & Recovery** — debounced autosave, crash-recovery drafts, recent files and folders, native window tabs
- **Settings** — five preference panes: General, Appearance, Editor, Markdown, Files

## Requirements

- macOS 27+
- Xcode 27+ (Swift 6.4)
- [Just](https://github.com/casey/just)

## Build & Run

```bash
# Build and open the app
just run

# Build release only
just build

# Install to ~/Applications
just install
```

## Development

```bash
# Lint
just lint
just lint-fix

# Format
just format
just format-check

# Clean build artifacts
just clean
```

Only `Inkstone.xcodeproj`; new `.swift` files need zero pbxproj edits (`PBXFileSystemSynchronizedRootGroup`).

## License

Inkstone is licensed under the [BSD-3-Clause License](https://opensource.org/licenses/BSD-3-Clause). See [LICENSE](LICENSE) for more details.
