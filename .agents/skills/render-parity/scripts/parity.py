# /// script
# requires-python = ">=3.12"
# dependencies = ["playwright", "markdown-it-py"]
# ///
"""Render-parity: compare Inkstone's Markdown rendering against the Typora
reference, headlessly, from layout geometry — no screenshots, no pixels.

Usage:
    uv run parity.py baseline <file.md> --out ref.json
    uv run parity.py compare ref.json app.json [--out report.json]
    uv run parity.py run <file.md|dir> [--app PATH] [--out dir]

`run` orchestrates one file or every .md under a directory: baseline render,
App dump (`Inkstone --dump-layout`), comparison, exit code 1 on divergence.

The baseline renders the document in headless Chromium with Typora's own
stylesheets (base.css + github.css from the Typora bundle) and reads layout
geometry through CDP — every block box, every line box, list-item content
edges, inline-code boxes. The App side runs the same document through the
editor's real builder and layout stack without opening a window
(`Inkstone --dump-layout`), exporting line fragments and decoration geometry
from the same helpers the paint path uses. The comparator aligns the two line
sequences and reports pitch, height, indent, block gaps, marker geometry and
chip boxes in points.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

TYPORA_CSS = [
    "/Applications/Typora.app/Contents/Resources/TypeMark/style/base.css",
    "/Applications/Typora.app/Contents/Resources/TypeMark/style/themes/github.css",
]
REPO = Path(__file__).resolve().parents[4]  # .agents/skills/render-parity/scripts → repo
APP_FONTS = REPO / "Sources/Inkstone/Fonts"
DEFAULT_APP_BIN = (
    REPO
    / ".build/xcode-derived/Build/Products/Release/Inkstone.app/Contents/MacOS/Inkstone"
)
VIEWPORT = 920  # 860 max-width + 2×30 padding; #write content width is derived, not assumed

_MD_IT: "MarkdownIt | None" = None


def _converter() -> "MarkdownIt":
    """The CommonMark converter behind the reference render.

    markdown-it-py follows CommonMark 0.31 — the rules the editor's own parser
    implements for list nesting, fence-in-item, setext-vs-rule precedence and
    quote continuation. python-markdown's legacy behaviour disagreed with all
    four and needed source-level patches (indent doubling, fence demotion,
    comment separators) that this swap deletes.
    """
    global _MD_IT
    if _MD_IT is None:
        from markdown_it import MarkdownIt

        _MD_IT = MarkdownIt("commonmark").enable(["table", "strikethrough"])
    return _MD_IT

# Tolerances in pt (1 CSS px = 1 pt at deviceScaleFactor 1).
TOLERANCES = {
    "pitch": 0.5,
    "height": 0.5,
    "left": 0.5,
    "gap": 1.5,
    "marker": 0.5,
    "chip": 1.0,
}

EXTRACT_JS = """
() => {
  const write = document.getElementById('write');
  // Adjacent sibling lists with different bullets (`* a` + blank + `+ b`):
  // CommonMark starts a new list per bullet, while the editor's parser
  // continues the list across the blank. Merge same-tag siblings so the DOM
  // matches the App's single list; type changes (ul -> ol) stay separate,
  // exactly like the App's parser.
  let mergedLists = true;
  while (mergedLists) {
    mergedLists = false;
    for (const el of write.querySelectorAll('ul, ol')) {
      const next = el.nextElementSibling;
      if (next && next.tagName === el.tagName) {
        while (next.firstChild) el.appendChild(next.firstChild);
        next.remove();
        mergedLists = true;
      }
    }
  }
  const wrect = write.getBoundingClientRect();
  const wcs = getComputedStyle(write);
  const out = {
    write: {
      left: wrect.left, top: wrect.top, width: wrect.width,
      clientWidth: write.clientWidth,
      paddingLeft: parseFloat(wcs.paddingLeft), paddingRight: parseFloat(wcs.paddingRight),
      fontSize: parseFloat(wcs.fontSize),
    },
    lines: [], codeSpans: [], listItems: [], tables: [], blockquotes: [], rules: [],
  };
  const kindOf = (el) => {
    const t = el.tagName;
    if (t === 'LI') return 'listItem';
    if (t === 'BLOCKQUOTE') return 'blockquote';
    if (/^H[1-6]$/.test(t)) return 'heading';
    if (t === 'PRE') return 'fences';
    if (t === 'TABLE' || t === 'TD' || t === 'TH') return 'table';
    return 'paragraph';
  };
  // Nearest enclosing block, with the App's kind semantics: a list item claims
  // everything inside it (quotes and headings included), then a blockquote,
  // then the bare block itself.
  const blockOf = (el) => {
    let e = el, listDepth = 0, li = null, task = false, bq = null, heading = null, pre = null, table = null, p = null;
    while (e && e !== write) {
      const t = e.tagName;
      if (t === 'UL' || t === 'OL') listDepth++;
      if (!li && t === 'LI') {
        li = e;
        task = !!li.querySelector('input[type=checkbox]');
      }
      // The OUTERMOST blockquote claims the row: the App's quote rows carry
      // the visual owner's block id, and the nested levels render as part of
      // the same block.
      if (t === 'BLOCKQUOTE') bq = e;
      if (!heading && /^H[1-6]$/.test(t)) heading = e;
      if (!pre && t === 'PRE') pre = e;
      if (!table && t === 'TABLE') table = e;
      if (!p && t === 'P') p = e;
      e = e.parentElement;
    }
    if (li) return { el: li, kind: task ? 'taskItem' : 'listItem', listDepth };
    if (bq) return { el: bq, kind: 'blockquote', listDepth };
    if (heading) return { el: heading, kind: 'heading', listDepth };
    if (pre) return { el: pre, kind: 'fences', listDepth };
    if (table) return { el: table, kind: 'table', listDepth };
    if (p) return { el: p, kind: 'paragraph', listDepth };
    return { el: write, kind: 'paragraph', listDepth };
  };
  const ids = new Map();
  const idOf = (el) => {
    if (!ids.has(el)) ids.set(el, ids.size);
    return ids.get(el);
  };
  const blocks = new Map();

  // Line boxes: every text node's client rects, grouped per block and per row.
  // PRE and TABLE subtrees are rejected: code blocks and cells are compared as
  // whole blocks, not as flowed lines.
  const walker = document.createTreeWalker(write, NodeFilter.SHOW_TEXT, {
    acceptNode(n) {
      let e = n.parentElement;
      while (e && e !== write) {
        const t = e.tagName;
        if (t === 'PRE' || t === 'TABLE' || t === 'SCRIPT' || t === 'STYLE') {
          return NodeFilter.FILTER_REJECT;
        }
        e = e.parentElement;
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  const raw = [];
  const range = document.createRange();
  while (walker.nextNode()) {
    const node = walker.currentNode;
    if (!node.textContent.trim()) continue;
    const info = blockOf(node.parentElement);
    const blockId = idOf(info.el);
    if (!blocks.has(blockId)) {
      const r = info.el.getBoundingClientRect();
      blocks.set(blockId, {
        id: blockId, kind: info.kind, listDepth: info.listDepth,
        top: r.top, bottom: r.bottom, left: r.left, right: r.right,
        text: (info.el.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 60),
      });
    }
    const inCode = (() => {
      let e = node.parentElement;
      while (e && e !== write) { if (e.tagName === 'CODE') return true; e = e.parentElement; }
      return false;
    })();
    range.selectNodeContents(node);
    for (const r of range.getClientRects()) {
      if (r.width <= 0.5 || r.height <= 0.5) continue;
      raw.push({ top: r.top, bottom: r.bottom, left: r.left, right: r.right,
                 block: blockId, kind: info.kind, listDepth: info.listDepth,
                 hasCode: inCode });
    }
  }
  raw.sort((a, b) => a.top - b.top || a.left - b.left);
  let current = null;
  for (const r of raw) {
    // 6px: an inline-code span's font box sits ~4px below the body text's on
    // the same line; below that the rows of one paragraph must not fuse.
    if (current && r.block === current.block && Math.abs(r.top - current.top) < 6) {
      current.top = Math.min(current.top, r.top);
      current.bottom = Math.max(current.bottom, r.bottom);
      current.left = Math.min(current.left, r.left);
      current.right = Math.max(current.right, r.right);
      current.hasCode = current.hasCode || r.hasCode;
    } else {
      if (current) out.lines.push(current);
      current = { ...r };
    }
  }
  if (current) out.lines.push(current);
  out.blocks = [...blocks.values()];
  // Thematic breaks have no text nodes; emit them so block pairing and the
  // gaps around them align with the App (whose hr rows carry geometry).
  let hrId = ids.size;
  const bare = (el, kind) => {
    const r = el.getBoundingClientRect();
    out.blocks.push({ id: hrId++, kind, listDepth: 0,
                      top: r.top, bottom: r.bottom, left: r.left, right: r.right });
  };
  for (const el of write.querySelectorAll('hr')) bare(el, 'hr');
  // A list item whose content is a raw-HTML element (`<br>`, a comment) has no
  // text node of its own, but the App emits the item's row — emit the element
  // box so the pairing does not shift by one for everything after it.
  for (const el of write.querySelectorAll('li')) {
    if (!el.textContent.trim()) {
      bare(el, el.querySelector('input[type=checkbox]') ? 'taskItem' : 'listItem');
    }
  }
  // The App scopes a nested fence/table to its own sub-block (`md.subKind`),
  // and the reference's element claims its rows in both models - emit every
  // pre/table element box.
  for (const el of write.querySelectorAll('pre')) bare(el, 'fences');
  for (const el of write.querySelectorAll('table')) bare(el, 'table');

  for (const el of write.querySelectorAll('code, tt')) {
    if (el.closest('pre') || el.closest('table')) continue;
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    out.codeSpans.push({
      x: r.left, y: r.top, w: r.width, h: r.height,
      radius: parseFloat(s.borderRadius) || 0,
      border: s.borderTopWidth, background: s.backgroundColor,
    });
  }
  for (const el of write.querySelectorAll('li')) {
    const r = el.getBoundingClientRect();
    let depth = 0, nearestList = null, e = el;
    while (e && e !== write) {
      const t = e.tagName;
      if (t === 'UL' || t === 'OL') {
        depth++;
        if (!nearestList) nearestList = t;
      }
      e = e.parentElement;
    }
    const ordered = nearestList === 'OL';
    const s = getComputedStyle(el);
    const input = el.querySelector('input[type=checkbox]');
    const inputRect = input ? input.getBoundingClientRect() : null;
    out.listItems.push({
      depth, ordered, task: !!input,
      contentLeft: r.left + (parseFloat(s.paddingLeft) || 0),
      top: r.top, bottom: r.bottom,
      checkbox: inputRect ? { x: inputRect.left, y: inputRect.top,
                               w: inputRect.width, h: inputRect.height,
                               checked: input.checked } : null,
    });
  }
  for (const el of write.querySelectorAll('table')) {
    const r = el.getBoundingClientRect();
    out.tables.push({ x: r.left, y: r.top, w: r.width, h: r.height });
  }
  for (const el of write.querySelectorAll('blockquote')) {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    out.blockquotes.push({
      x: r.left, y: r.top, w: r.width, h: r.height,
      borderLeft: parseFloat(s.borderLeftWidth), borderColor: s.borderLeftColor,
      color: s.color,
    });
  }
  for (const el of write.querySelectorAll('h1, h2')) {
    const s = getComputedStyle(el);
    if (parseFloat(s.borderBottomWidth) > 0) {
      const r = el.getBoundingClientRect();
      out.rules.push({ y: r.bottom - parseFloat(s.borderBottomWidth), w: r.width,
                       color: s.borderBottomColor });
    }
  }
  return out;
}
"""


def baseline(md_path: Path, out_path: Path, match_app_fonts: bool, keep_html: bool) -> dict:
    """Render the document in headless Chromium with Typora's CSS; dump geometry."""
    from playwright.sync_api import sync_playwright

    text = md_path.read_text(encoding="utf-8")
    # YAML front matter: the App models it as its own frontMatter block; the
    # converter would render it as a thematic break plus paragraphs. Strip it
    # (the comparator drops the App's frontMatter blocks too) so both sequences
    # align; the front-matter box itself is phase 2.
    text = re.sub(r"\A---[ \t]*\r?\n.*?\r?\n---[ \t]*(?:\r?\n|$)", "", text, flags=re.DOTALL)
    # A stray closing tag: the converter treats it as raw inline HTML and drops
    # it from the text, while the editor (and Typora) render it as literal
    # text. Escape closing tags that close nothing opened on their line.
    def _escape_stray_closing(line: str) -> str:
        m = re.search(r"</([a-zA-Z][^>]*)>([ \t]*)$", line)
        if not m:
            return line
        tag = m.group(1)
        if re.search(r"<" + re.escape(tag) + r"[\s>]", line[: m.start()]):
            return line
        return line[: m.start()] + "&lt;/" + tag + "&gt;" + m.group(2)

    text = "\n".join(
        _escape_stray_closing(line) for line in text.split("\n")
    )
    content = _converter().render(text)
    styles = []
    for css_path in TYPORA_CSS:
        styles.append(Path(css_path).read_text(encoding="utf-8"))
    if match_app_fonts:
        # The App bundles and registers Open Sans; Chromium must load the same
        # faces from the repo, and the mono stack must resolve to Menlo like the
        # App's (the user's Typora resolves it to Consolas via Office).
        faces = []
        for name, weight, style in [
            ("Regular", 400, "normal"),
            ("Bold", 700, "normal"),
            ("Italic", 400, "italic"),
            ("BoldItalic", 700, "italic"),
        ]:
            ttf = APP_FONTS / f"OpenSans-{name}.ttf"
            faces.append(
                "@font-face { font-family: 'Open Sans'; font-weight: %d; font-style: %s; "
                "src: url('file://%s'); }" % (weight, style, ttf)
            )
        styles.append("\n".join(faces))
        styles.append(':root { --monospace: "Menlo", monospace !important; }')

    # Task lists: the converter leaves `[x]` as literal text; Typora renders
    # a checkbox input at the item start (github.css styles it). Convert to the
    # same DOM shape so the geometry and the kind match the App.
    content = re.sub(
        r"(<li[^>]*>(?:<p>)?)\[([ xX])\] ",
        lambda m: (
            m.group(1)
            + '<input type="checkbox" class="task-list-item-checkbox" disabled'
            + (" checked" if m.group(2) != " " else "")
            + "> "
        ),
        content,
    )
    # Typora's document model wraps every list item's content in a paragraph;
    # CommonMark emits tight lists (bare text in li), which would skip the
    # `li p` spacing rules the App implements. Wrap to match the DOM shape.
    content = re.sub(
        r"<li>(?!<[pbouhl])",
        "<li><p>",
        content,
    )
    content = re.sub(r"</li>", "</p></li>", content)
    html = (
        "<!DOCTYPE html><html><head><meta charset='utf-8'><style>"
        + "\n".join(styles)
        + "</style></head><body><div id='write'>"
        + content
        + "</div></body></html>"
    )
    html_path = Path(tempfile.mkdtemp(prefix="render-parity-")) / "reference.html"
    html_path.write_text(html, encoding="utf-8")

    with sync_playwright() as p:
        try:
            browser = p.chromium.launch(channel="chrome")
        except Exception:
            browser = p.chromium.launch()  # bundled Chromium (`playwright install chromium`)
        page = browser.new_page(
            viewport={"width": VIEWPORT, "height": 1400}, device_scale_factor=1
        )
        page.goto(html_path.as_uri())
        page.evaluate("document.fonts.ready")
        page.wait_for_timeout(100)
        data = page.evaluate(EXTRACT_JS)
        browser.close()

    if keep_html:
        out_path.with_suffix(".html").write_text(html, encoding="utf-8")

    content_width = (
        data["write"]["clientWidth"]
        - data["write"]["paddingLeft"]
        - data["write"]["paddingRight"]
    )
    data["meta"] = {
        "source": md_path.name,
        "width": content_width,
        "viewport": VIEWPORT,
        "generator": "chromium-reference",
        "fonts": "matched" if match_app_fonts else "raw",
        "fontSize": data["write"]["fontSize"],
    }
    out_path.write_text(json.dumps(data, indent=1), encoding="utf-8")
    return data


def app_dump(md_path: Path, out_path: Path, app_bin: Path, width: float) -> None:
    """Run the built Inkstone binary in headless dump mode."""
    if not app_bin.exists():
        raise SystemExit(
            f"App binary not found at {app_bin} — build first (`just build`) "
            "or pass --app /path/to/Inkstone.app/Contents/MacOS/Inkstone"
        )
    result = subprocess.run(
        [str(app_bin), "--dump-layout", str(md_path), "--width", str(width), "--out", str(out_path)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        raise SystemExit(f"app dump failed ({result.returncode}): {result.stderr.strip()}")


# Block kinds whose lines are excluded from the line-level comparison on BOTH
# sides: tables are compared as whole blocks (cells are not flowed lines), and
# fenced code styling comes from CodeMirror in the reference editor — its boxes
# are phase 2.
SKIPPED_KINDS = {"table", "fences"}


def compare(ref_path: Path, app_path: Path, tolerances: dict[str, float]) -> tuple[list[str], dict]:
    """Block-aligned comparison: blocks pair first (kind + order), then lines
    compare WITHIN each block pair — a wrap difference in one block no longer
    cascades into every following block."""
    ref = json.loads(ref_path.read_text())
    app = json.loads(app_path.read_text())

    ref_lines_all = ref["lines"]
    app_lines_all = app["lines"]
    if not ref_lines_all or not app_lines_all:
        return ["empty document on at least one side"], {"meta": {}, "blocks": [], "flags": []}
    origin_y_ref = min(l["top"] for l in ref_lines_all)
    origin_x_ref = min(l["left"] for l in ref_lines_all)
    origin_y_app = min(l["top"] for l in app_lines_all)
    origin_x_app = min(l["left"] for l in app_lines_all)
    for l in ref_lines_all:
        l["top"] -= origin_y_ref
        l["bottom"] -= origin_y_ref
        l["left"] -= origin_x_ref
        l["right"] -= origin_x_ref
    for i, l in enumerate(app_lines_all):
        l["_index"] = i
        l["top"] -= origin_y_app
        l["bottom"] -= origin_y_app
        l["left"] -= origin_x_app
        l["right"] -= origin_x_app
    for section in ("blocks", "listItems", "codeSpans", "tables", "blockquotes"):
        for item in ref.get(section, []):
            for key in ("left", "x", "contentLeft"):
                if key in item:
                    item[key] -= origin_x_ref
            if "top" in item:
                item["top"] -= origin_y_ref
                item["bottom"] -= origin_y_ref
    for chip in app["chips"]:
        chip["x"] -= origin_x_app
        chip["y"] -= origin_y_app

    flags: list[str] = []
    report: dict = {"meta": {"ref": ref["meta"], "app": app["meta"]}, "blocks": [], "flags": flags}

    # --- reference blocks: element rects + their lines + text ---------------
    ref_blocks = sorted(ref["blocks"], key=lambda b: b["top"])
    for block in ref_blocks:
        block["lines"] = [l for l in ref_lines_all if l["block"] == block["id"]]

    # --- app blocks: kind runs over the line sequence -----------------------
    # indentedCode renders like a fence on both engines; frontMatter,
    # linkDefinition and htmlBlock are App-side constructs the plain converter
    # does not model (front matter becomes hr+paragraphs, definitions vanish,
    # comments render nothing) — dropped until their phase 2 exists.
    KIND_ALIAS = {"indentedCode": "fences"}
    DROPPED_KINDS = {"frontMatter", "linkDefinition", "htmlBlock"}
    app_blocks: list[dict] = []
    current: dict | None = None
    after_dropped = False
    marker_lines = {marker["line"] for marker in app["markers"]}
    # Task rows carry no listMarker decoration — their checkbox bar is the row's
    # identity, so split blocks there too (nested task items share the parent's
    # block id and would otherwise fuse into one block).
    checkbox_lines = {
        bar["line"] for bar in app.get("bars", []) if bar["kind"] == "taskCheckbox"
    }
    for line in app_lines_all:
        if line["bottom"] - line["top"] < 0.5:
            continue  # boundary hairlines are not blocks
        line = {**line, "kind": KIND_ALIAS.get(line["kind"], line["kind"])}
        if line["kind"] in DROPPED_KINDS:
            after_dropped = True
            continue
        starts = (
            current is None
            or line["block"] != current["block"]
            or line["kind"] != current["kind"]
            or line["i"] in marker_lines
            or line["i"] in checkbox_lines
        )
        if starts:
            if current:
                app_blocks.append(current)
            current = {
                "kind": line["kind"], "top": line["top"], "bottom": line["bottom"],
                "depth": line["depth"], "block": line["block"],
                "sub": line.get("sub"), "lines": [line],
                "text": line["text"], "afterDropped": after_dropped,
            }
            after_dropped = False
        else:
            current["bottom"] = line["bottom"]
            current["lines"].append(line)
            current["text"] += " " + line["text"]
    if current:
        app_blocks.append(current)

    # --- greedy block alignment by kind (1-lookahead resync) ----------------
    pairs: list[tuple[dict, dict]] = []
    i = j = 0
    while i < len(ref_blocks) and j < len(app_blocks):
        rb, ab = ref_blocks[i], app_blocks[j]
        if rb["kind"] == ab["kind"]:
            pairs.append((rb, ab))
            i += 1
            j += 1
            continue
        if i + 1 < len(ref_blocks) and ref_blocks[i + 1]["kind"] == ab["kind"]:
            flags.append(f"block unpaired on the reference side: {rb['kind']} '{rb.get('text', '')[:30]}'")
            i += 1
            continue
        if j + 1 < len(app_blocks) and app_blocks[j + 1]["kind"] == rb["kind"]:
            flags.append(f"block unpaired on the app side: {ab['kind']} '{ab.get('text', '')[:30]}'")
            j += 1
            continue
        flags.append(f"block kind differs: reference {rb['kind']} vs app {ab['kind']}")
        pairs.append((rb, ab))
        i += 1
        j += 1
    for rb in ref_blocks[i:]:
        flags.append(f"block unpaired on the reference side: {rb['kind']} '{rb.get('text', '')[:30]}'")
    for ab in app_blocks[j:]:
        flags.append(f"block unpaired on the app side: {ab['kind']} '{ab.get('text', '')[:30]}'")

    # --- per-block comparison ----------------------------------------------
    item_kinds = {"listItem", "taskItem"}
    report_blocks: list[dict] = []
    prev_pair: tuple[dict, dict] | None = None
    for rb, ab in pairs:
        row: dict = {"kind": ab["kind"],
                     "text": ab.get("text", "")[:40],
                     "refText": rb.get("text", "")[:40],
                     "lines": [len(rb["lines"]), len(ab["lines"])]}
        if len(rb["lines"]) != len(ab["lines"]) and rb["kind"] not in ("table", "fences"):
            row["wrap"] = "differs"
        # block box: the reference's ELEMENT rect (border box = the CSS margin
        # edge) vs the App's first-row top / last-row box bottom (the TextKit
        # fragment box, whose top already carries the paragraph spacing). Both
        # are margin edges, so the gap between consecutive blocks is the
        # collapsed margin on both sides — engine-neutral. (The reference's
        # line rects are FONT content boxes, ~3.6pt tighter than its line boxes;
        # comparing those against the App's line boxes flagged every paragraph
        # boundary with a constant offset.)
        ab_top = ab["lines"][0]["top"] if ab["lines"] else ab.get("top", 0)
        ab_bottom = ab["lines"][-1]["bottom"] if ab["lines"] else ab.get("bottom", 0)
        rb_top, rb_bottom = rb["top"], rb["bottom"]
        row["top"] = [round(ab_top, 2), round(rb_top, 2)]
        if prev_pair is not None:
            prb, pab, prb_bottom, pab_bottom = prev_pair
            gap_r = rb_top - prb_bottom
            gap_a = ab_top - pab_bottom
            # List-item rows carry the item spacing INSIDE their line
            # box (the App) vs OUTSIDE (the reference's li margins) —
            # the item pitch (top-to-top) is the engine-neutral metric.
            if ab["kind"] in item_kinds and rb["kind"] in item_kinds \
                and prb["kind"] in item_kinds and pab["kind"] in item_kinds:
                row["itemPitch"] = [round(ab_top - pab["lines"][0]["top"], 2),
                                    round(rb_top - prb["top"], 2)]
            elif prb["top"] - 0.5 <= rb["top"] and rb["bottom"] <= prb["bottom"] + 0.5:
                # The reference's element boxes NEST (a blockquote claims the
                # inner quote, a list item its children) — the margin between
                # a container and its own child is not a collapsed margin.
                pass
            elif ab.get("afterDropped"):
                # Dropped blocks (definitions, front matter) sit between the
                # pair on the App side; their height pollutes the gap.
                pass
            else:
                # Fences/table margins are P1 (the App's painted padding
                # sits outside the text rows); suppress the noisy gap
                # flags around them until that redesign.
                if ab["kind"] not in SKIPPED_KINDS \
                    and rb["kind"] not in SKIPPED_KINDS \
                    and pab["kind"] not in SKIPPED_KINDS \
                    and prb["kind"] not in SKIPPED_KINDS:
                    row["gap"] = [round(gap_a, 2), round(gap_r, 2)]
                    if abs(gap_a - gap_r) > tolerances["gap"]:
                        flags.append(
                            f"block '{ab.get('text', '')[:24]}': gap {gap_a:.2f} vs {gap_r:.2f}pt"
                        )
        # Line pitch and text column only compare when both sides resolved the
        # same number of rows — a row-count difference means the two engines
        # split the block differently (a blank row one keeps and the other
        # collapses), and index-parallel comparison would compare unrelated
        # rows.
        if len(rb["lines"]) == len(ab["lines"]):
            for k in range(1, len(ab["lines"])):
                pitch_r = rb["lines"][k]["top"] - rb["lines"][k - 1]["top"]
                pitch_a = ab["lines"][k]["top"] - ab["lines"][k - 1]["top"]
                if ab["kind"] in item_kinds and abs(pitch_a - pitch_r) > tolerances["pitch"]:
                    row.setdefault("pitch", []).append([k, round(pitch_a, 2), round(pitch_r, 2)])
                elif abs(pitch_a - pitch_r) > tolerances["pitch"]:
                    flags.append(
                        f"block '{ab.get('text', '')[:24]}' line {k}: pitch {pitch_a:.2f} vs {pitch_r:.2f}pt"
                    )
            # text column per line (skip rows that start with a code span: the
            # reference's chip padding pushes glyphs ~3pt right of the column)
            app_chip_lines = {chip["line"] for chip in app["chips"]}
            for k in range(len(ab["lines"])):
                rl, al = rb["lines"][k], ab["lines"][k]
                if al["_index"] in app_chip_lines:
                    continue
                if abs(al["left"] - rl["left"]) > tolerances["left"]:
                    flags.append(
                        f"block '{ab.get('text', '')[:24]}' line {k}: text column {al['left']:.2f} vs {rl['left']:.2f}pt"
                    )
        prev_pair = (rb, ab, rb_bottom, ab_bottom)
        report_blocks.append(row)
    report["blocks"] = report_blocks

    # --- list markers --------------------------------------------------------
    em = ref["meta"]["fontSize"]
    ref_items = [item for item in ref["listItems"] if not item.get("task")]
    app_markers = app["markers"]
    if len(ref_items) != len(app_markers):
        flags.append(f"marker count differs: reference {len(ref_items)} vs app {len(app_markers)}")
    report["markers"] = []
    for k in range(min(len(ref_items), len(app_markers))):
        item, marker = ref_items[k], app_markers[k]
        expected_center = item["contentLeft"] - 0.95 * em
        delta = marker["centerX"] - expected_center
        if item.get("ordered"):
            expected_shape, expected_size = "text", 0.0
        else:
            expected_shape, expected_size = (
                ("disc", 0.375 * em) if item["depth"] <= 1
                else ("ring", 0.4375 * em) if item["depth"] == 2
                else ("square", 0.375 * em)
            )
        row = {
            "i": k, "depth": item["depth"],
            "centerX": [round(marker["centerX"], 2), round(expected_center, 2)],
            "shape": [marker["shape"], expected_shape],
            "size": [round(marker["size"], 2), round(expected_size, 2)],
        }
        if abs(delta) > tolerances["marker"]:
            flags.append(f"marker {k}: center {marker['centerX']:.2f} vs {expected_center:.2f}pt")
        if marker["shape"] != expected_shape:
            flags.append(f"marker {k}: shape {marker['shape']} vs {expected_shape}")
        elif expected_size and abs(marker["size"] - expected_size) > tolerances["marker"]:
            flags.append(f"marker {k}: size {marker['size']:.2f} vs {expected_size:.2f}pt")
        report["markers"].append(row)

    # --- task checkboxes ------------------------------------------------------
    ref_tasks = [item for item in ref["listItems"] if item.get("checkbox")]
    app_checks = [bar for bar in app["bars"] if bar["kind"] == "taskCheckbox"]
    if len(ref_tasks) != len(app_checks):
        flags.append(f"checkbox count differs: reference {len(ref_tasks)} vs app {len(app_checks)}")
    report["checkboxes"] = []
    for k in range(min(len(ref_tasks), len(app_checks))):
        item, bar = ref_tasks[k], app_checks[k]
        box = item["checkbox"]
        report["checkboxes"].append({
            "i": k,
            "size": [round(bar["w"], 2), round(bar["h"], 2)],
            "refSize": [round(box["w"], 2), round(box["h"], 2)],
            "checked": bool(box["checked"]),
        })

    # --- inline-code chips -----------------------------------------------------
    ref_spans, app_chips = ref["codeSpans"], app["chips"]
    if len(ref_spans) != len(app_chips):
        flags.append(f"chip count differs: reference {len(ref_spans)} vs app {len(app_chips)}")
    report["chips"] = []
    for k in range(min(len(ref_spans), len(app_chips))):
        span, chip = ref_spans[k], app_chips[k]
        row = {"i": k}
        row["w"] = [round(chip["w"], 2), round(span["w"], 2)]
        row["h"] = [round(chip["h"], 2), round(span["h"], 2)]
        if abs(chip["w"] - span["w"]) > tolerances["chip"]:
            flags.append(f"chip {k}: width {chip['w']:.2f} vs {span['w']:.2f}pt")
        if abs(chip["h"] - span["h"]) > tolerances["chip"]:
            flags.append(f"chip {k}: height {chip['h']:.2f} vs {span['h']:.2f}pt")
        report["chips"].append(row)

    report["flags"] = flags
    return flags, report


def run(paths: list[Path], app_bin: Path, out_dir: Path, tolerances: dict[str, float]) -> int:
    md_files = []
    for path in paths:
        if path.is_dir():
            md_files += sorted(path.rglob("*.md"))
        else:
            md_files.append(path)
    if not md_files:
        raise SystemExit(f"no .md files under {paths}")

    work = out_dir or Path(tempfile.mkdtemp(prefix="render-parity-"))
    work.mkdir(parents=True, exist_ok=True)
    total_flags = 0
    for md in md_files:
        stem = md.stem.replace(" ", "_")
        ref_json = work / f"{stem}.ref.json"
        app_json = work / f"{stem}.app.json"
        print(f"== {md}")
        baseline(md, ref_json, match_app_fonts=True, keep_html=False)
        width = json.loads(ref_json.read_text())["meta"]["width"]
        app_dump(md, app_json, app_bin, width)
        flags, report = compare(ref_json, app_json, tolerances)
        report_path = work / f"{stem}.report.json"
        report_path.write_text(json.dumps(report, indent=1))
        print(f"   width {width:.0f}pt · blocks {len(report['blocks'])} · flags {len(flags)}")
        for flag in flags:
            print(f"   - {flag}")
        total_flags += len(flags)
    print(f"\n{total_flags} divergence(s) across {len(md_files)} file(s); artifacts in {work}")
    return 1 if total_flags else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p_base = sub.add_parser("baseline", help="reference geometry via headless Chromium")
    p_base.add_argument("md", type=Path)
    p_base.add_argument("--out", type=Path, default=Path("reference.json"))
    p_base.add_argument("--fonts", choices=["match", "raw"], default="match")
    p_base.add_argument("--keep-html", action="store_true")

    p_cmp = sub.add_parser("compare", help="compare two geometry dumps")
    p_cmp.add_argument("ref", type=Path)
    p_cmp.add_argument("app", type=Path)
    p_cmp.add_argument("--out", type=Path, default=None)
    for name, default in TOLERANCES.items():
        p_cmp.add_argument(f"--tol-{name}", type=float, default=default)

    p_run = sub.add_parser("run", help="baseline + app dump + compare")
    p_run.add_argument("paths", type=Path, nargs="+")
    p_run.add_argument("--app", type=Path, default=DEFAULT_APP_BIN)
    p_run.add_argument("--out", type=Path, default=None)
    for name, default in TOLERANCES.items():
        p_run.add_argument(f"--tol-{name}", type=float, default=default)

    args = parser.parse_args()
    if args.command == "baseline":
        data = baseline(args.md, args.out, args.fonts == "match", args.keep_html)
        print(json.dumps(data["meta"], indent=1))
        return 0
    if args.command == "compare":
        tolerances = {
            name: getattr(args, f"tol_{name}") for name in TOLERANCES
        }
        flags, report = compare(args.ref, args.app, tolerances)
        out = args.out or args.ref.with_suffix(".report.json")
        out.write_text(json.dumps(report, indent=1))
        for flag in flags:
            print(f"- {flag}")
        print(f"\n{len(flags)} divergence(s); report: {out}")
        return 1 if flags else 0
    if args.command == "run":
        tolerances = {
            name: getattr(args, f"tol_{name}") for name in TOLERANCES
        }
        return run(args.paths, args.app, args.out, tolerances)
    return 2


if __name__ == "__main__":
    sys.exit(main())
