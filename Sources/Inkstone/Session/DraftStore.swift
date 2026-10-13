import Foundation

/// A crash-recoverable copy of an unsaved document.
///
/// Autosave has two jobs that pull in opposite directions: a file-backed document
/// should be written back to its own path, while an untitled one has nowhere to go.
/// Both need the second behaviour as a safety net - if the process dies between the
/// last autosave and the next, the draft is what the user gets back. A draft is
/// therefore written for *every* dirty document, not just the untitled ones, and
/// cleared on save.
///
/// Drafts live in Application Support, not next to the document: a `.md` file
/// appearing in the user's folder is a surprise, and a half-written one in a synced
/// folder is worse.
struct Draft: Sendable {
    /// Where the document lives, or `nil` for one that was never saved.
    var sourceURL: URL?
    /// Stable per-document identity - the draft key for a document with no file.
    var documentID: String?
    /// The document's title at the time of the last write, for the recovery prompt.
    var title: String
    var markdown: String
    var savedAt: Date
}

@MainActor
@Observable
final class DraftStore {
    private(set) var drafts: [Draft] = []

    /// Drafts older than this are not worth offering: a week-old unsaved note is
    /// almost certainly something the user abandoned on purpose.
    private static let maximumAge: TimeInterval = 60 * 60 * 24 * 7

    private let directory: URL
    /// Set by the tests and by `reset()`; writes are best-effort and never fatal.
    private(set) var lastWriteFailed = false

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )
        let fallback = support[0].appendingPathComponent("Inkstone/Drafts", isDirectory: true)
        let base = directory ?? fallback
        self.directory = base
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true
        )
        drafts = readAll()
    }

    // MARK: - Writing

    /// Mirrors a dirty document. Cheap enough to call on every autosave tick.
    func write(_ draft: Draft) {
        let file = url(for: draft)
        do {
            try draft.markdown.write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.modificationDate: draft.savedAt], ofItemAtPath: file.path
            )
            lastWriteFailed = false
            upsert(draft)
        } catch {
            // A failed draft must never interrupt typing: the worst case is losing the
            // crash-recovery copy, which is exactly what it is for.
            lastWriteFailed = true
            AppLogger.error("Draft write failed: \(error)", category: "Drafts")
        }
    }

    /// Drops the mirror. Called on every successful save, including autosave.
    ///
    /// Both identities are cleared: the file path when there is one, and the
    /// per-document id, which is the only key an untitled document has. The old
    /// path-only clear hashed an empty string for untitled documents and removed a
    /// file that never existed, so a just-saved document came back as a phantom
    /// recovery draft on the next launch.
    func clear(sourceURL: URL?, documentID: String?) {
        if let sourceURL {
            try? FileManager.default.removeItem(
                at: url(for: Draft(sourceURL: sourceURL, documentID: documentID, title: "", markdown: "", savedAt: .distantPast))
            )
        }
        if let documentID, sourceURL == nil {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent("untitled-" + documentID + ".md")
            )
        }
        drafts.removeAll { draft in
            (sourceURL != nil && draft.sourceURL == sourceURL)
                || (documentID != nil && draft.documentID == documentID)
        }
    }

    // MARK: - Recovery

    /// Drafts worth offering back, newest first.
    var recoverable: [Draft] {
        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        let usable = drafts.filter { $0.savedAt >= cutoff && !$0.markdown.isEmpty }
        return usable.sorted { $0.savedAt > $1.savedAt }
    }

    /// Whether a draft is newer than the file it mirrors.
    ///
    /// The usual case after a crash: the file on disk is the last manual save and the
    /// draft holds everything typed since. Comparing timestamps is what stops the
    /// recovery prompt from appearing for a document the user already saved elsewhere.
    func isNewer(_ draft: Draft, thanFileAt fileURL: URL) -> Bool {
        guard let saved = modificationDate(of: fileURL) else { return true }
        return draft.savedAt > saved
    }

    private func modificationDate(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    // MARK: - Identity

    /// A stable name for a document.
    ///
    /// The path is hashed rather than percent-encoded: a document name can contain
    /// anything a filesystem allows, and the draft name only has to be unique and
    /// recoverable, which the index file supplies. An untitled document keys on its
    /// minted per-document id - a content hash changed with every edit and left a
    /// new orphan file per autosave tick, and Swift's `hashValue` is seeded per
    /// process, so the name never matched again after a relaunch.
    private func url(for draft: Draft) -> URL {
        if draft.sourceURL == nil, let documentID = draft.documentID {
            return directory.appendingPathComponent("untitled-" + documentID + ".md")
        }
        return directory.appendingPathComponent(Self.identifier(for: draft) + ".md")
    }

    static func identifier(for draft: Draft) -> String {
        guard let path = draft.sourceURL?.standardizedFileURL.path else {
            return "untitled-" + (draft.documentID ?? "unknown")
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(path.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01b3
        }
        return "doc-" + String(hash, radix: 36)
    }

    /// The index that maps a draft back to the file it mirrors.
    ///
    /// Derived from the store's own directory, not from Application Support directly:
    /// a store pointed somewhere else has to read its own index, or every draft looks
    /// like it came from nowhere.
    private var indexURL: URL { directory.appendingPathComponent("index") }

    private func readAll() -> [Draft] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
        var paths: [String: String] = [:]
        let contents = try? String(contentsOf: indexURL, encoding: .utf8)
        for line in contents?.split(separator: "\n") ?? [] {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            paths[parts[0]] = parts[1]
        }
        var out: [Draft] = []
        for file in files where file.pathExtension == "md" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let savedAt = attributes?[.modificationDate] as? Date ?? .distantPast
            let identifier = file.deletingPathExtension().lastPathComponent
            let source = paths[identifier].map { URL(fileURLWithPath: $0) }
            let documentID = identifier.hasPrefix("untitled-")
                ? String(identifier.dropFirst("untitled-".count))
                : nil
            out.append(
                Draft(
                    sourceURL: source,
                    documentID: documentID,
                    title: source?.lastPathComponent ?? "Untitled",
                    markdown: text,
                    savedAt: savedAt
                )
            )
        }
        return out
    }

    private func recordPath(for draft: Draft) {
        guard let path = draft.sourceURL?.standardizedFileURL.path else { return }
        let identifier = Self.identifier(for: draft)
        let contents = try? String(contentsOf: indexURL, encoding: .utf8)
        var lines = contents?.split(separator: "\n").map(String.init) ?? []
        lines.removeAll { $0.hasPrefix(identifier + "\t") }
        lines.append(identifier + "\t" + path)
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(to: indexURL, atomically: true, encoding: .utf8)
    }

    private func upsert(_ draft: Draft) {
        recordPath(for: draft)
        drafts.removeAll { existing in
            existing.documentID != nil
                ? existing.documentID == draft.documentID
                : existing.sourceURL == draft.sourceURL
        }
        drafts.append(draft)
    }

    func reset() {
        for draft in drafts { try? FileManager.default.removeItem(at: url(for: draft)) }
        drafts = []
    }
}
