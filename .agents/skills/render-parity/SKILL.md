---
name: render-parity
description: Compare Inkstone's Markdown rendering against the VS Code markdown preview from layout geometry (对齐文档渲染 / 渲染对比 / 渲染差异 / VS Code 对齐). Use when the user asks to check rendering parity with VS Code, align rendering (对齐渲染), quantify rendering differences (量化渲染差异), diagnose why a document renders differently (排错), or mentions render-parity.
---

# Render parity

Input is a `.md` file or a directory of them. Output is a quantified divergence
report in points — no screenshots, no pixel analysis. Two uses:

- **Alignment**: run before and after a rendering change; the flag list is the
  remaining work; zero flags means aligned.
- **Troubleshooting**: the report carries block kind, source text and per-metric
  deltas, so a flag maps straight to a rendering code path.

## Alignment target

VS Code's built-in markdown preview — an open-source target
(`extensions/markdown-language-features` in microsoft/vscode):

- **Engine**: markdown-it 14, default preset (CommonMark + tables +
  strikethrough), `html: true`, `linkify: true` with `fuzzyLink: false`,
  `breaks`/`typographer` off. Every fenced block gets the `hljs` class; the
  highlighter falls back to `escapeHtml` for unknown languages.
- **Styles**: the extension's `media/markdown.css` + `highlight.css`, read from
  the installed app
  (`/Applications/Visual Studio Code.app/.../markdown-language-features/media/`)
  — byte-identical to the repo's main branch. The workbench injects the theme
  colors as CSS variables; the baseline pins Light Modern's values
  (`editor.background #FFFFFF`, `editor.foreground #3B3B3B`,
  `textCodeBlock.background #F8F8F8`, `widget.border #E5E5E5`) and the settings
  defaults as inline styles on `<html>`: `--markdown-font-family:
  -apple-system, …`, `--markdown-font-size: 14px`, `--markdown-line-height:
  1.6`. The mono stack is pinned to Menlo (the App's face; the stack's first
  entry, SF Mono, is not installed system-wide for Chromium).
- **Page model**: `html, body { padding: 0 26px; padding-top: 1em }`, body
  `margin: 0`, **no max-width centering** — the content spans the webview minus
  the padding. `body.wordWrap` is on (`[markdown] editor.wordWrap: "on"`), so
  `pre` wraps per character.
- **Block model** (all measured on the reference render):
  - headings: weight 600, `margin-top: 24px` (`h1: 0`), `margin-bottom: 16px`,
    line-height 1.25; sizes 2 / 1.5 / 1.25 / 1 / 0.875 / 0.85 em; h1/h2 carry
    `padding-bottom: 0.3em` + a 1px bottom border (rgba(0,0,0,0.18)).
  - `p { margin: 0 0 16px }`; `ul/ol { padding-inline-start: 40px; margin:
    0 0 0.7em }`, `li` carries no margins, `li p { margin-bottom: 0.7em }`.
  - `blockquote { margin: 0; padding: 0 16px 0 10px; border-left: 5px
    currentColor }` — no top/bottom margins at all.
  - `hr { height: 1px; border-bottom: 1px; margin: 0.5em 0 }` — 2pt total.
  - tables shrink to fit (no `width` rule): `th, td { padding: 5px 10px }`, the
    UA's `th { font-weight: bold }` with a darker bottom rule
    (rgba(0,0,0,0.69)), row separators rgba(0,0,0,0.18), no outer border.
  - `code` renders mono at 1em with **no background, padding or border**; the
    cell's code spans likewise.
  - `pre`: 1px #E5E5E5 border, #F8F8F8 background, **no padding** — the
    padding rule (`pre:not(.hljs), pre.hljs code > div`) matches nothing the
    engine produces (every fenced block gets `hljs`, no inner div; measured on
    the reference render). Code rows pitch at `code { line-height: 1.357em }`
    = 19pt; the content box = `max(rows × 19 + 1.39, 22.4 strut)`.
  - task lists render as **literal `[x] ` text** (the engine ships no
    task-list plugin); front matter renders as `table.frontmatter` (dropped on
    both sides for now).

## Run it

Always from the repository root (the script path and the app binary are
repo-relative). The app side lives in the binary — build first or the dump
fails with "App binary not found":

```bash
just build

# One file or a directory (every .md under it, recursively):
uv run .agents/skills/render-parity/scripts/parity.py run \
    /Users/aaron/Documents/md-fixtures
```

`run` orchestrates three headless steps per file:

1. **Baseline** — markdown → HTML (markdown-it-py, the VS Code engine model)
   → headless Chromium with the VS Code preview CSS → `reference.json`
   (block/line boxes, list-item content edges, code-span boxes with their
   strut baselines, heading-rule positions).
2. **App dump** — `Inkstone --dump-layout <file> --width <W>` (Editor/LayoutDump.swift)
   → `app.json` (line fragments, paragraph geometry, decoration rects from the
   same helpers `BlockDecorator.paint` uses, engine baselines on ruled
   headings and chips).
3. **Compare** — align the two line sequences; report pitch, height, text
   column, block gaps, marker geometry, chip boxes, rule and row geometry;
   exit code 1 on flags.

Intermediate JSON/report files land in a temp work dir (printed at the end);
pass `--out dir` to keep them next to the document for inspection.

## Reading the report

- `lines[]` — per aligned line: `height`/`pitch`/`gap`/`left` as
  `[app, reference]` pt pairs, plus the line's source text. `pitch` covers
  rhythm (line spacing), `gap` only fires at block boundaries (margins), and
  `left` catches indent/nesting errors. Line pitch and text column compare
  only when both sides resolved the same row count; task rows skip the text
  column (the App paints a checkbox chip where the reference renders the
  literal `[x] ` glyphs).
- `markers[]` — per list item: `centerX` expected as `contentLeft − 1.0em`
  (Chromium's UA outside marker, ink-measured: a 5px disc centred 14pt in
  from the column at 14px body text), shape per the browser ladder (depth 1
  disc, 2 ring, 3+ square) and size in em.
- `chips[]` — per inline-code span: `w`/`h` and the baseline-relative
  position (`y − baseline` vs the reference's `y − strut baseline`); the
  engines place the glyphs at different heights inside an identical line box,
  so absolute y would flag every line.
- `boxes`/`boxGap` on fences/table block rows — the App's painted fill vs the
  baseline's `pre`/`table` element box (the reference shrunk by its computed
  borders), and the fill's margin-edge gap to the previous block. The vertical
  position is compared as a gap because absolute y drifts with every
  heading's element-box overhang upstream. Fence boxes use the `fenceGap`
  tolerance (the fill/border-box semantics differ by the strut slack and the
  border ring pair).
- `headingRules[]` — the ruled h1/h2's baseline→rule distance on both sides
  (engine-neutral); headings whose line carries an inline chip are skipped
  (the rule rides the chip there).
- `table rows` — per-row tops relative to each side's own box top (against
  the reference's `tr` rects).
- Flags use `line N`/`marker N`/`chip N` indices matching the arrays.

## Metric semantics (how the two sides are made comparable)

- **Gaps compare layout margin edges.** The reference's line rects are font
  content boxes (tighter than its line boxes), so the reference side uses the
  element border boxes (`ref.blocks[*].top/bottom`) and the App side its
  first-row top / last-row box bottom. The gap between consecutive blocks is
  then the collapsed CSS margin on both sides.
- **Ruled headings measure from the rule.** The engines place the same glyphs
  at different heights inside an identical clamped line box (TextKit 1 clamps
  from the descent side — `baseline = boxTop + H − maxVisibleDescent`, rounded
  to whole points; Chromium centres the strut) — so any gap after a ruled
  heading is measured from the rule on both sides (`prev_rule_edges`). Headings
  whose line carries an inline chip skip the comparison (the App's chip
  position is not calibrated against the reference's).
- **Chips measure from the baseline.** The chip's `y − baseline` vs the
  reference span's `y − strut baseline`, where the reference's strut baseline
  = block content top + row index × line height + half-leading + canvas
  ascent (canvas `fontBoundingBoxAscent` quantizes to whole CSS px — ±0.5pt
  noise; the tolerance is 1.0). Line rects cannot be used: an all-code row
  reports the mono box, not the strut's.
- **Dropped kinds** — `frontMatter`, `linkDefinition`, `htmlBlock` are out of
  scope (both sides model them differently); the App blocks are removed from
  the sequence and gaps polluted by a dropped block are not flagged. Task
  checkbox geometry is skipped for the same reason (literal `[x]` text in the
  reference).
- **Blank rows inside containers** (between list items, between an item's
  paragraphs, inside quotes) collapse to hairlines whose strut carries the
  paragraph margin; a pure blank line's margin rides on the NEXT separator
  newline (the blank row's only character).

## Interpreting → code paths

| Symptom | Likely location |
| --- | --- |
| pitch/gap deltas on paragraphs | the collapse model (`cssMarginTop`/`cssMarginBottom`/`appliedSpacingAfter`) and the boundary backfill in `Layout/AttributedBuilder.swift`; `blockMargin` in `Theme/EditorTheme.swift` |
| heading gap/rule deltas | `BlockStyle.heading` (the ruled after-spacing), `MarkerHider.lineSpacingAfterGlyphAt` (the descent correction), `headingMarginTop` |
| text column (`left`) deltas | `listIndent` (40pt), `markdownListItem`, quote indents (`quoteIndent` + `quoteBarWidth`) |
| marker center/size/shape | `BlockDecorator.listMarkerGeometry` (the 1.0em hang) |
| chip x/w/h/baseline | `BlockDecorator.inlineCodeChipRuns` (the engine-baseline anchor), `InlineStyle.code` |
| table width/row deltas | `TableGrid` (the shrink-to-fit columns, `plainCell`, the header's bold face), `theme.tableCellPadding(X)` |
| fence box height deltas | `fenceFillHeight` (the strut/slack bottom) and the paint's fill growth |
| line count differs | wrap width mismatch — the pipeline passes the reference's effective content width to the dump; check `meta.width` on both sides |

## Calibration notes

- The baseline is Chromium + the VS Code extension's own CSS — the same
  stylesheets the user's VS Code loads (verified byte-identical, app 1.143).
- Fonts match by construction: the body face is the system SF Pro on both
  sides (`-apple-system`); the mono stack is pinned to Menlo via
  `--vscode-editor-font-family` (the App's `codeFontName`).
- The engine descent model: TextKit 1 clamps a fixed line height from the
  descent side and rounds the descent to whole points — the descent of the
  row's largest **visible** run (the substituted CJK face for the system font
  descends only 0.14em via PingFang UI Display, vs Menlo's 0.236em). The
  ruled heading's after-spacing assumes the mono face (the largest a heading
  row mixes) and `MarkerHider.lineSpacingAfterGlyphAt` hands the difference
  back additively (negative delegate returns are clamped to 0 — measured; the
  delegate also fires BEFORE `shouldSetLineFragmentRect` for the same row, so
  the captured-baseline map is empty there and the row's substituted font
  attributes are read instead).
- Task-list checkboxes do not exist in the target (no plugin); table cells
  render their inline markdown (the App's `TableGrid.plainCell` mirrors the
  common constructs).

## Known-residual baseline (zero)

As of the last full run over `~/Documents/md-fixtures` the comparison reports
**0 flags** across all 23 fixtures: document-level geometry (fonts, headings,
paragraphs, lists, rules, inline code, fence heights, table columns and row
tops) and container/nested spacing are aligned. The mechanisms below are what
cleared the last residuals — regressions most likely re-enter through them.

Cleared on the way to zero (do not regress):

- **Gap below a quote block** — a blockquote's own margin is 0, but its LAST
  child's bottom margin collapses through it and sticks out: a quote ending
  in a paragraph leaves the `p` margin (16) below its last row
  (`cssMarginBottom` recurses into the last child for `.blockquote`). The
  quote's own rows apply no after-spacing (`sa=0`: the between-paragraph
  margins ride the blank struts), so nothing subtracts it back.
- **Margin above a quote block** — the mirror: its FIRST child's margin-top
  collapses through (`cssMarginTop` recurses into the first child). A quote
  opening with a heading starts one heading margin below the previous block;
  the boundary hairline carries `max(previous bottom, this)` because the
  quote's first row glues into it and its own spacing never applies.
- **Boundary hairlines vanish when their spacing ≤ 0** — a boundary backfill
  row with `rect.height == 0.01` (no spacing) produces no line fragment at
  all; with spacing > 0 (rect ≥ 16.01) it exists. A gap that measures 0.01
  across a block boundary means the hairline's `collapsedSpacing` went
  negative or zero — check `cssMarginBottom`/`appliedSpacingAfter` first.
- **Strut above a container-nested fence/indented code** — the collapsed
  margin from the previous SIBLING (inside an item a paragraph is `li p`
  0.7em; inside a quote it is the body `p` margin) rides the separator that
  opens the fence's first delimiter row (`leadingStrutSpacing` threaded
  through `emitChildContent` → `emitFenceLines`).
- **`NSTextStorage` normalizes a paragraph terminator's style to the
  paragraph's FIRST character's style on the next attribute pass** (copy
  into a fresh `NSTextStorage` triggers it; the live editor's storage does
  too). A strut written onto a `\n` whose paragraph opens with a differently-
  styled marker run silently reverts — the blank row's hidden `>` must carry
  the strut itself (as a fixed row height; a `spacingBefore` there belongs
  to the blank paragraph, whose first fragment glues into the row above, and
  never applies).
- **Table columns measure full-width CJK at exactly 1em**
  (`TableGrid.visibleWidth`) — `NSString.size` measures the system cascade
  (han 0.992em, kana 0.949em, hangul 0.865em) while the reference lays every
  full-width CJK glyph at 1em, and columns are content-sized. Code cells
  wrap-check with the MONO face (a body-font check overflowed the mono-sized
  column and grew a row a whole line), and a cell that fits its column never
  wraps (the widest cell must not round into a second line through
  `boundingRect`'s pixel snapping).
- **heading rule anchor** — the rule hangs off the ENGINE BASELINE (captured
  per line by `MarkerHider` from the `shouldSetLineFragmentRect` delegate) at
  the reference's baseline→rule distance `(H − asc − desc)/2 + 0.3em padding`,
  computed at build time in `BlockStyle.heading` into the plan
  (`md.headingRuleGap`). The padding part puts the border 0.3em below the
  content-box bottom, exactly where the reference's border-bottom sits.
- **heading rule → following content** — the ruled heading's after-spacing =
  `gap − mono descent + margin + 1` (the style assumes the mono face, the
  largest descent a ruled row mixes); `MarkerHider.lineSpacingAfterGlyphAt`
  trims the difference per row from the row's largest **visible** descent
  (the hidden markers do not count). The builder's collapse accounting keeps
  reporting the plain margin for the heading, so the padding and border ride
  through uniformly: the gap after the heading is `margin + 1 + padding`
  against the reference's identical structure.
- **fence fill height** — `max(rows × codeRowHeight + 1.39, strut)`, grown at
  the bottom in both the painter and the dump (`fenceFillHeight`): a
  single-row fence is strut-height (22.39), not code-row-height (measured
  22.39 / 39.39 / 58.39 for 1/2/3 rows).
- **fence fill has no padding** — the preview's padding rule matches nothing
  the engine produces; `codePadding*` are 0 in the VS Code theme.
- **table columns hug their content** — no proportional distribution; the
  floors are 0 (an empty cell is just the padding pair); the header row
  measures and paints bold; cells paint and measure their parsed inline text
  (`TableGrid.plainCell`); cells that are entirely a code span paint mono.
- **table row tops** compare against the reference's `tr` rects relative to
  each side's own box top.
- **blockquote** — `margin: 0` (the collapse gives the neighbours' margins),
  the bar 5px currentColor, the text column 15pt (bar + padding) in, the
  fill's right edge clamped by `quoteRightPadding` (16).
- **fence→fence row pitch** — 19.4 against the reference's 19.39 (the
  delimiter hairline pair + the collapsed margin + the previous fill's
  extension); the box-gap flag runs on the `fenceGap` tolerance.

Layout pitfalls that were found on the way and are easy to re-step into:

- `"\r\n"` is a single grapheme cluster in Swift — `split(separator: "\n")`
  never splits CRLF text. The parser's `splitLines` and the builder's
  `splitRawLines` both split on both terminators; do not reintroduce a plain
  `split` on source slices.
- TextKit applies `paragraphSpacingBefore` at a CRLF line's `\n` half even
  when the glyph row is a collapsed strut — strut styles must carry
  `paragraphSpacingBefore = 0` (their height comes from the fixed line
  height). The blank struts between a quote's paragraphs are the known
  exception still being chased.
- `NSTextStorage` normalizes a paragraph terminator's paragraph style to the
  paragraph's first character's style on the next attribute pass (a copy
  into a fresh `NSTextStorage` is enough). A strut on a `\n` whose paragraph
  opens with a differently-styled run reverts silently — style the run, not
  the terminator.
- A paragraph style's `spacingBefore` applies at the paragraph's FIRST
  fragment; a paragraph whose first glyphs glue backwards into the previous
  row never applies it — carry such margins as a fixed line height on the
  row's first character instead.
- `NSString.size` measures CJK through the system cascade (han 0.992em,
  kana 0.949em) while the layout substitutes PingFang UI and the reference
  lays full-width CJK at 1em — never mix `NSString.size` cell/column
  measurements with reference-derived widths (`TableGrid.visibleWidth`).
- `NSLayoutManager.boundingRect(forGlyphRange:)` pads CJK runs at
  attribute-run boundaries (~5.5pt over four glyphs) while the laid-out
  advances are exact — measure chip/run widths from glyph locations, not the
  bounding rect.
- `characterRange(forGlyphRange:)` answered from a fragment cache that is
  still in flux when called mid-layout (`lineSpacingAfterGlyphAt`) — it
  handed back ranges spanning whole paragraphs (`{0, 64}` for an
  8-character heading). Walk the row's characters off the storage text
  instead (`ruledHeadingRowChars`).
- `String.replacing(_:with:)`'s `$1` template does not expand in this Swift
  toolchain (it substitutes the literal `$1`) — use the closure form
  (`{ match in String(match[1]!.content) }`) or `NSRegularExpression`.
- A nested function inside `build()` cannot see sibling nested functions'
  helpers from the emitter methods — shared layout helpers go on
  `AttributedBuilder` as `static` (the theme travels as a parameter).

## Flags

`--tol-pitch 0.5 --tol-height 0.5 --tol-left 0.5 --tol-gap 1.5 --tol-marker 0.5
--tol-chip 1.5 --tol-chippos 1.0 --tol-headingrule 1.0 --tol-fencegap 4.0` (pt);
`--app` to point at a different Inkstone binary; `--out` to keep artifacts.
