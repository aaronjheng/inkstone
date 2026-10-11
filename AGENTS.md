# Agents.md — Inkstone

Short rules, always in English.

- Never commit, push, branch, tag, or open PRs unless explicitly asked.
- Never add tests or test scaffolding unless explicitly asked.
- Never do GUI testing, screenshots, window inspection, or synthesized input.
- Build: `just build`; lint: `just lint`; format: `just format`.
- Only `Inkstone.xcodeproj`; `PBXFileSystemSynchronizedRootGroup` for new `.swift` files — zero pbxproj edits.
- No WebKit / HTML / CSS / JS / CodeMirror in this project.
- `Markdown/` only Foundation; `Editor/` uses `Layout/`; `MarkerHider` lives in `Editor/`.
- Buffer = source byte-for-byte; `.null` only for hidden markers; table `md.painted` closes.
