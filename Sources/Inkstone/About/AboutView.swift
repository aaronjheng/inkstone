import AppKit
import SwiftUI

/// Sizes shared by the About and License windows.
enum AboutMetrics {
    /// Fixed size of the About panel (mark + version + License button).
    static let panelSize = NSSize(width: 320, height: 380)
    static let iconSide: CGFloat = 96
    /// Minimum size of the License window; it stays resizable from there.
    static let licenseMinSize = NSSize(width: 460, height: 420)
    /// Height of the transparent full-size titlebar both windows draw their
    /// content under, so the window title never overlaps the content.
    static let titlebarClearance: CGFloat = 28
}

/// Contents of the About panel opened from `Inkstone → About Inkstone`.
///
/// The system panel (`orderFrontStandardAboutPanel`) has no room for a
/// License button, so the app shows its own window instead: app mark,
/// version, one-line description, the License button, and the copyright line
/// taken from the bundled `LICENSE`.
struct AboutView: View {
    let onShowLicense: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: AboutMetrics.iconSide, height: AboutMetrics.iconSide)
                .clipShape(
                    RoundedRectangle(cornerRadius: AboutMetrics.iconSide * 0.23, style: .continuous)
                )

            VStack(spacing: 4) {
                Text(MenuBuilder.applicationName)
                    .font(.title2)
                    .bold()

                Text(Self.versionText)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("Native macOS Markdown editor")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            Spacer(minLength: 0)

            Button("License", systemImage: "doc.text", action: onShowLicense)
                .buttonStyle(.bordered)
                .keyboardShortcut("l", modifiers: .command)
                .help("Show the Inkstone license text")

            if !AppLicense.copyrightLine.isEmpty {
                Text(AppLicense.copyrightLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 20 + AboutMetrics.titlebarClearance)
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(width: AboutMetrics.panelSize.width, height: AboutMetrics.panelSize.height)
        .background(Color(nsColor: .controlBackgroundColor))
        // Window root: kill SwiftUI's focus chrome (the panel's only control
        // is the License button).
        .focusEffectDisabled()
    }

    /// `Version 1.0.0 (1.0.0)`, matching the system panel's wording, so a
    /// build number bump needs no code change.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }
}
