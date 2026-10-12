import Foundation

/// The license text shipped inside the app bundle, read from the `LICENSE`
/// resource at the repository root (added to the Inkstone target's resources).
///
/// Both the About panel (copyright line) and the License window read from
/// here, so the file is located and decoded once per launch.
enum AppLicense {
    /// Name of the bundled resource, without extension.
    static let resourceName = "LICENSE"

    /// Full license text, or `nil` when the resource is missing or unreadable.
    static let text: String? = load()

    /// The leading `Copyright (c) …` line, shown in the About panel. Empty
    /// when the resource is missing or does not start with a copyright notice.
    static var copyrightLine: String {
        guard let firstLine = text?.split(separator: "\n", maxSplits: 1).first else { return "" }
        let line = firstLine.trimmingCharacters(in: .whitespaces)
        return line.lowercased().hasPrefix("copyright") ? line : ""
    }

    private static func load() -> String? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: nil) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
