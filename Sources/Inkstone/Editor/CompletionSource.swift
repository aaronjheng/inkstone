import AppKit

/// One completion candidate.
struct Completion {
    /// What the source will contain when the item is accepted, `:` for emoji.
    var insert: String
    /// What is shown, and what the filter runs against.
    var label: String
    var detail: String = ""

    /// Prefix after the accepted text, so `:smile:` lands on a closing colon.
    var suffix: String = ""
}

/// The completion sources the original offers, and the rules for when each applies.
///
/// Pure text in, candidates out: the trigger that opens the popup lives in
/// `CompletionController`, which is a view concern, and the data lives here so a
/// candidate list can be reasoned about without a window.
enum CompletionSource {
    /// `:smi` -> the emoji shortcodes whose name starts with it.
    static func emoji(matching query: String, limit: Int = 12) -> [Completion] {
        guard !query.isEmpty else { return [] }
        let needle = query.lowercased()
        var out: [Completion] = []
        for name in EmojiCatalog.shortcodes where name.hasPrefix(needle) {
            out.append(
                Completion(
                    insert: ":" + name + ":",
                    label: ":" + name + ":",
                    detail: EmojiCatalog.glyph(for: name)
                )
            )
            if out.count >= limit { break }
        }
        // Exact matches first, then the shortest name: `:smile` should beat
        // `:smile_with_something` without the user having to type further.
        return out.sorted {
            $0.label.count == $1.label.count ? $0.label < $1.label : $0.label.count < $1.label.count
        }
    }

    /// A path that exists, for `![](` or `[](`.
    ///
    /// Only siblings of the document and its enclosing folder: a completion list that
    /// walks the whole disk is not a completion list.
    static func paths(
        matching query: String, in directory: URL?, limit: Int = 12
    ) -> [Completion] {
        guard let directory else { return [] }
        let fm = FileManager.default
        guard
            let names = try? fm.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        let needle = query.lowercased()
        var out: [Completion] = []
        for name in names.sorted() {
            guard name.lowercased().hasPrefix(needle) || needle.isEmpty else { continue }
            if name.hasPrefix(".") { continue }
            let values = try? directory.appendingPathComponent(name)
                .resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            out.append(
                Completion(
                    insert: name + (isDirectory ? "/" : ""),
                    label: name,
                    detail: isDirectory ? "folder" : "file"
                )
            )
            if out.count >= limit { break }
        }
        return out
    }
}

/// The `:shortcode:` table lives in `Markdown/Model/Emoji.swift`: the layout
/// pass renders glyphs and HTML export writes them, and neither layer may
/// reach up into `Editor/`.
