import AppKit

/// An inline image drawn from a file on disk.
///
/// The buffer keeps the `![](…)` source, so the image is not an attachment character:
/// the alt text is emitted as an ordinary run and this draws the picture over it. That
/// keeps the source invariant intact - saving writes the Markdown, not an object
/// placeholder - and it means a missing or unreadable file degrades to the alt text
/// rather than to a blank box.
///
/// Loading is lazy and cached by path, and the decoded size is capped: a 6000px photo
/// placed at its natural size would blow the text container's height by tens of
/// thousands of points and stall the layout.
@MainActor
final class InlineImagePainter {
    /// Largest edge, in points, an inline image may occupy.
    static let maximumWidth: CGFloat = 480
    private(set) var cache: [String: NSImage?] = [:]
    /// Set by the editor so a relative path resolves against the document.
    var baseDirectory: URL?
    var placeholderColor: NSColor = .tertiaryLabelColor

    /// Resolves a Markdown path against the document's folder.
    func resolve(_ path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let baseDirectory else { return nil }
        return URL(fileURLWithPath: path, relativeTo: baseDirectory).standardizedFileURL
    }

    /// The image for a path, decoded once.
    func image(for path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        let loaded: NSImage?
        if let url = resolve(path), let data = try? Data(contentsOf: url) {
            loaded = NSImage(data: data)
        } else {
            loaded = nil
        }
        cache[path] = loaded
        return loaded
    }

    /// Display size for the layout pass, served from the same cache painting uses.
    ///
    /// `AttributedBuilder` asks for this on every relayout - including every
    /// resize tick - so it must not hit the disk again; `image(for:)` decodes
    /// once and caches by path.
    func displaySize(of path: String) -> CGSize {
        guard let image = image(for: path) else { return .zero }
        return fittedSize(of: image)
    }

    func fittedSize(of image: NSImage) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return .zero }
        if size.width <= Self.maximumWidth { return size }
        let scale = Self.maximumWidth / size.width
        return CGSize(width: Self.maximumWidth, height: (size.height * scale).rounded())
    }

    /// Draws the image with its bottom-left at `origin`, which is in view coordinates.
    func draw(
        path: String, at origin: NSPoint, measureWidth: CGFloat, minimumHeight: CGFloat = 0
    ) {
        guard let image = image(for: path) else { return }
        var size = fittedSize(of: image)
        if minimumHeight > size.height { size.height = minimumHeight }
        var rect = NSRect(origin: origin, size: size)
        // Never wider than the text column, even if the image is.
        if measureWidth > 0, rect.width > measureWidth {
            let scale = measureWidth / rect.width
            rect.size = CGSize(width: measureWidth, height: (rect.height * scale).rounded())
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Drops every cached image, so an edited or moved file is picked up.
    func invalidate() { cache.removeAll() }
}
