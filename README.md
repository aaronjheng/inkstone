# Inkstone

Native macOS Markdown editor — a pure AppKit / Swift recreation of the
original Typora "what-you-see-is-what-you-get" experience.

- No WebKit, HTML, CSS, JS, CodeMirror, MathJax, or Mermaid.
- Layout by TextKit 1 + CoreText + Core Graphics.
- Source = buffer, byte for byte; zero-width glyphs hide markers.
- Folder tree, outline, source mode, find/replace, quick-open.

## Build

```bash
just build     # Xcode Release
just run       # build + open
just lint      # SwiftLint
just format    # swift-format
```

Only `Inkstone.xcodeproj`; new `.swift` files need zero pbxproj edits
(PBXFileSystemSynchronizedRootGroup).
