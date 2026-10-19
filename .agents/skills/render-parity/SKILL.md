---
name: render-parity
description: Compare Inkstone's Markdown rendering against the Typora reference from layout geometry (对齐文档渲染 / 渲染对比 / 渲染差异 / Typora 对齐). Use when the user asks to check rendering parity with Typora, align rendering (对齐渲染), quantify rendering differences (量化渲染差异), diagnose why a document renders differently (排错), or mentions render-parity.
---

# Render parity

Input is a `.md` file or a directory of them. Output is a quantified divergence
report in points — no screenshots, no pixel analysis. Two uses:

- **Alignment**: run before and after a rendering change; the flag list is the
  remaining work; zero flags means aligned.
- **Troubleshooting**: the report carries block kind, source text and per-metric
  deltas, so a flag maps straight to a rendering code path.

## Run it

Always from the repository root (the script path and the app binary are
repo-relative). The app side lives in the binary — build first or the dump
fails with "App binary not found":

```bash
just build

# One file or a directory (every .md under it, recursively):
uv run .agents/skills/render-parity/scripts/parity.py run \
    /Users/aaron/Documents/inkstone-tree-test
```

`run` orchestrates three headless steps per file:

1. **Baseline** — markdown → HTML → headless Chromium with Typora's own
   `base.css` + `github.css` (read from the Typora bundle) → `reference.json`
   (block/line boxes, list-item content edges, code-span boxes via CDP).
2. **App dump** — `Inkstone --dump-layout <file> --width <W>` (Editor/LayoutDump.swift)
   → `app.json` (line fragments, paragraph geometry, decoration rects from the
   same helpers `BlockDecorator.paint` uses).
3. **Compare** — align the two line sequences; report pitch, height, text
   column, block gaps, marker geometry, chip boxes; exit code 1 on flags.

Intermediate JSON/report files land in a temp work dir (printed at the end);
pass `--out dir` to keep them next to the document for inspection.

## Reading the report

- `lines[]` — per aligned line: `height`/`pitch`/`gap`/`left` as
  `[app, reference]` pt pairs, plus the line's source text. `pitch` covers
  rhythm (line spacing), `gap` only fires at block boundaries (margins), and
  `left` catches indent/nesting errors. Line pitch and text column compare
  only when both sides resolved the same row count; the item-internal pitch
  (the marker hider's 9.4pt vs the reference's 8pt `li p` margin) is reported
  on the block row, not flagged.
- `markers[]` — per list item: `centerX` expected as `contentLeft − 0.95em`,
  shape per the browser ladder (depth 1 disc, 2 ring, 3+ square) and size in em.
- `chips[]` — per inline-code span: `x`/`w`/`h` absolute and `yOffset` relative
  to the owning line's center.
- Flags use `line N`/`marker N`/`chip N` indices matching the arrays.

## Metric semantics (how the two sides are made comparable)

- **Gaps compare layout margin edges.** The reference's line rects are font
  content boxes (~3.6pt tighter than its line boxes), so the reference side
  uses the element border boxes (`ref.blocks[*].top/bottom`) and the App side
  its first-row top / last-row box bottom. The gap between consecutive blocks
  is then the collapsed CSS margin on both sides.
- **Reference blocks include `<pre>`, `<table>` and empty `<li>` element
  boxes** (their subtrees produce no text nodes); the App's `fences`,
  `indentedCode` (aliased to `fences`) and `table` blocks pair against them.
- **Dropped kinds** — `frontMatter`, `linkDefinition`, `htmlBlock` and
  `fences`-adjacent gap checks are out of scope (the baseline cannot model
  them); the App blocks are removed from the sequence and gaps polluted by a
  dropped block are not flagged.
- **Blank rows inside containers** (between list items, between an item's
  paragraphs, inside quotes) collapse to hairlines whose strut carries the
  paragraph margin; a pure blank line's margin rides on the NEXT separator
  newline (the blank row's only character).

## Interpreting → code paths

| Symptom | Likely location |
| --- | --- |
| pitch/gap deltas on paragraphs | boundary backfill in `Layout/AttributedBuilder.swift`, `blockMargin`/`listItemSpacing` in `Theme/EditorTheme.swift` |
| heading gap deltas | `headingMargin`, `markdownHeading` paragraph style |
| text column (`left`) deltas | `listIndent`, `markdownListItem`, quote indents |
| marker center/size/shape | `BlockDecorator.listMarkerGeometry` |
| chip x/w/h/yOffset | `BlockDecorator.inlineCodeChipRects`, `InlineStyle.code` |
| line count differs | wrap width mismatch — the pipeline passes the reference's effective content width to the dump; check `meta.width` on both sides |

## Calibration notes

- The baseline is Chromium + Typora's CSS, not Typora's own DOM. One known
  systemic offset measured against a real Typora capture: list-item pitch runs
  ~1.4pt tighter in the pure-CSS baseline (35.0pt measured in Typora vs 33.6pt
  from the CSS) — treat sub-2pt per-item drift in lists with suspicion before
  changing code.
- `--fonts match` (default) pins Open Sans (the App's bundled faces, loaded via
  @font-face) and Menlo (the App's mono) on the baseline, so font metrics do
  not pollute the diff. The user's Typora resolves `monospace` to Consolas —
  `--fonts raw` compares against that environment instead.
- Markdown conversion uses python-markdown; structures it does not model
  (task-list checkboxes, math) are phase 2 and may mis-report.

## Known-residual baseline (do not chase as new bugs)

As of the last full run over `~/Documents/md-fixtures` the fixture set reports
~7 flags. These categories are KNOWN and accepted — a fresh run should be
compared against them; only NEW divergences (different blocks, larger deltas)
are regressions:

- **chip box metrics** — body chips align (18.76 vs 18); the heading chip's
  width carries the CJK fallback advance (~5pt over 4 glyphs, TextKit vs
  Chromium shaping). 1 flag.
- **nested quote level margins** — the reference separates every quote level
  with the blockquote's own 12.8pt margin (pitch 38.4 between levels); the App
  glues the levels into one paragraph. The delegate handover covers every
  transition EXCEPT the one after the quote's first row (TextKit 1 drops the
  delegate spacing there when the paragraph carries `paragraphSpacingBefore`).
  2 pitch flags.
- **quote's list marker center** — a list inside a quote compounds the
  quote's inset into the item text column (49pt ✓), but the marker geometry
  still reads the un-compounded column (14.8 vs 33.8). 2 flags; the marker
  plan's width/origin needs the same inset offset.
- **raw HTML edge cases** — a stray closing tag is escaped for the baseline;
  deeper raw-HTML quirks (an unclosed fence the reference turns into a code
  block) still mispair. 2 flags in `special-chars.md`.

## Flags

`--tol-pitch 0.5 --tol-height 0.5 --tol-left 0.5 --tol-gap 1.0 --tol-marker 0.5 --tol-chip 1.0` (pt);
`--app` to point at a different Inkstone binary; `--out` to keep artifacts.
