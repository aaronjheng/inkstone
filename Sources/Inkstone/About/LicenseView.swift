import AppKit
import SwiftUI

/// Contents of the License window opened from the About panel: the bundled
/// `LICENSE` text, selectable and copyable, with the whole text also available
/// on the pasteboard for pasting into a source-distribution form.
struct LicenseView: View {
    @State private var didCopy = false

    private let licenseText = AppLicense.text

    var body: some View {
        VStack(spacing: 0) {
            textArea
            footer
        }
        .frame(
            minWidth: AboutMetrics.licenseMinSize.width,
            minHeight: AboutMetrics.licenseMinSize.height
        )
        .background(Color(nsColor: .controlBackgroundColor))
        // Window root: SwiftUI's focus chrome would flash on the scroll view
        // taking focus.
        .focusEffectDisabled()
    }

    // MARK: - Text

    @ViewBuilder
    private var textArea: some View {
        ScrollView {
            Group {
                if let licenseText {
                    Text(licenseText)
                } else {
                    Text("The \(AppLicense.resourceName) resource is missing from this build of Inkstone.")
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(2)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        // The window's titlebar is full-size and transparent, so the first
        // lines of the text would sit under the window title. Reserving the
        // titlebar as a scroll-content margin keeps the clearance in place
        // while scrolling (plain padding would scroll away).
        .contentMargins(.top, AboutMetrics.titlebarClearance, for: .scrollContent)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Copy License Text", systemImage: didCopy ? "checkmark" : "doc.on.doc") {
                guard let licenseText else { return }
                copyToPasteboard(licenseText)
                didCopy = true
                Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    didCopy = false
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(licenseText == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
