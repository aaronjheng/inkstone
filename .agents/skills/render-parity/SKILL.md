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
  `left` catches indent/nesting errors.
- `markers[]` — per list item: `centerX` expected as `contentLeft − 0.95em`,
  shape per the browser ladder (depth 1 disc, 2 ring, 3+ square) and size in em.
- `chips[]` — per inline-code span: `x`/`w`/`h` absolute and `yOffset` relative
  to the owning line's center.
- Flags use `line N`/`marker N`/`chip N` indices matching the arrays.

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

As of the last full run the fixture reports ~105 flags. These categories are
KNOWN and accepted — a fresh run should be compared against them; only NEW
divergences (different blocks, larger deltas) are regressions:

- **chip x-in-line Δ~3pt** — the chip-box semantics: the App's chip protrudes
  3pt left of the text column, the reference's chip padding pushes glyphs 3pt
  right. Engine limitation (TextKit 1 cannot offset a run's glyphs). ~26 flags
  across all files.
- **CJK advance accumulation** — chip positions after long CJK runs drift
  6-12pt (TextKit vs Chromium text shaping). Part of the chip x flags.
- **task item pitch Δ~1.4pt** — the App's 9.4pt item spacing vs the
  reference's li p margin (~35 vs 33.6). Within tolerance; accepted.
- **tables** — the App's painted grid (row height now includes cell padding
  12 + border 1) vs the CSS table; the delimiter row's buffer box and the
  painted/buffer row relationship are still approximate. P1 redesign pending.
- **fence margins** — partially aligned (margin 15 + padding 8/6); residual
  deltas ~2-6pt around fenced blocks. P1 polish.
- **hr line missing from the App's line sequence** — the hr's 0.01pt
  fragment is compared as a whole block instead; phase 2.

## Flags

`--tol-pitch 0.5 --tol-height 0.5 --tol-left 0.5 --tol-gap 1.0 --tol-marker 0.5 --tol-chip 1.0` (pt);
`--app` to point at a different Inkstone binary; `--out` to keep artifacts.
