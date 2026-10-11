import AppKit
import SwiftUI

/// The Settings window (⌘,), in the original's image: a toolbar of tabs, one per
/// concern, every control wired straight into `SettingsStore` - a change lands
/// in the JSON on disk and reaches every open window through `onChange`.
///
/// Only preferences the app actually consumes appear here; the full inventory
/// lives in `Docs/option-inventory.md`, and a switch that does nothing is worse
/// than a missing one.
@MainActor
final class PreferencesController: NSWindowController {
    static let shared = PreferencesController()

    private convenience init() {
        let window = NSWindow(contentViewController: PreferencesTabController())
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    /// Re-centres on first show; afterwards the user's placement wins.
    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The tab strip. `tabStyle = .toolbar` turns the tabs into the segmented
/// icon row that macOS preferences and the original both use.
private final class PreferencesTabController: NSTabViewController {
    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        tabStyle = .toolbar
        let store = AppStore.shared
        addPane("General", icon: "gearshape") {
            GeneralPane(store: store)
        }
        addPane("Appearance", icon: "paintbrush") {
            AppearancePane(store: store)
        }
        addPane("Editor", icon: "pencil") {
            EditorPane(store: store)
        }
        addPane("Markdown", icon: "number") {
            MarkdownPane(store: store)
        }
        addPane("Files", icon: "folder") {
            FilesPane(store: store)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func addPane<V: View>(_ title: String, icon: String, view: @escaping () -> V) {
        let hosting = NSHostingController(rootView: view().frame(width: 480))
        hosting.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: hosting)
        item.label = title
        item.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        addTabViewItem(item)
    }
}

/// One grouped settings form, in the System Settings idiom.
private struct PaneGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - General

private struct GeneralPane: View {
    let store: AppStore

    var body: some View {
        PaneGroup {
            Picker(
                "Autosave",
                selection: setting(
                    get: { $0.autoSaveInterval },
                    set: { $0.autoSaveInterval = $1 }
                )
            ) {
                Text("Off").tag(0.0)
                Text("Every second").tag(1.0)
                Text("Every 3 seconds").tag(3.0)
                Text("Every 5 seconds").tag(5.0)
                Text("Every 10 seconds").tag(10.0)
                Text("Every 30 seconds").tag(30.0)
                Text("Every minute").tag(60.0)
            }
            Stepper(
                "Reading speed: \(store.settings.settings.wordsPerMinute) wpm",
                value: setting(
                    get: { Double($0.wordsPerMinute) },
                    set: { $0.wordsPerMinute = Int($1) }
                ),
                in: 100...800,
                step: 10
            )
            Toggle(
                "Record recent files",
                isOn: setting(
                    get: { $0.recordRecentFiles },
                    set: { $0.recordRecentFiles = $1 }
                )
            )
            launchOptions
        }
    }

    /// The original's "启动选项": what a launch with no files from the Finder
    /// does. The folder row appears only for the option that needs one, the way
    /// the original reveals it.
    private var launchOptions: some View {
        Section {
            Picker(
                "On launch",
                selection: setting(
                    get: { $0.launchOption },
                    set: { $0.launchOption = $1 }
                )
            ) {
                ForEach(LaunchOption.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            if store.settings.settings.launchOption == .openSpecifiedFolder {
                HStack {
                    Text(
                        store.settings.settings.launchFolderPath.map {
                            (URL(fileURLWithPath: $0).lastPathComponent.isEmpty
                                ? $0 : URL(fileURLWithPath: $0).lastPathComponent)
                        } ?? "No folder chosen"
                    )
                    .foregroundStyle(
                        store.settings.settings.launchFolderPath == nil
                            ? Color.secondary : Color.primary
                    )
                    Spacer()
                    Button {
                        chooseFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.update { $0.launchFolderPath = url.path }
    }

    private func setting<V>(
        get: @escaping (EditorSettings) -> V, set: @escaping (inout EditorSettings, V) -> Void
    ) -> Binding<V> {
        Binding(
            get: { get(store.settings.settings) },
            set: { newValue in store.settings.update { set(&$0, newValue) } }
        )
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    let store: AppStore

    var body: some View {
        PaneGroup {
            Picker(
                "Theme",
                selection: Binding(
                    get: { store.themeManager.theme.identifier },
                    set: { store.themeManager.select(identifier: $0) }
                )
            ) {
                ForEach(store.themeManager.available, id: \.identifier) { theme in
                    Text(theme.displayName).tag(theme.identifier)
                }
            }
            Toggle(
                "Use custom font size",
                isOn: Binding(
                    get: { store.settings.settings.useCustomFontSize },
                    set: { on in
                        if on {
                            store.themeManager.setCustomFontSize(
                                store.settings.settings.customFontSize
                            )
                        } else {
                            store.themeManager.useThemeFontSize()
                        }
                    }
                )
            )
            Slider(
                value: Binding(
                    get: { store.settings.settings.customFontSize },
                    set: { store.themeManager.setCustomFontSize($0) }
                ),
                in: 10...28,
                step: 1
            ) {
                Text("Font size")
            } minimumValueLabel: {
                Text("10")
            } maximumValueLabel: {
                Text("28")
            }
            .disabled(!store.settings.settings.useCustomFontSize)
        }
    }
}

// MARK: - Editor

private struct EditorPane: View {
    let store: AppStore

    var body: some View {
        PaneGroup {
            Toggle("Show invisible characters", isOn: toggle(\.showInvisibleCharacters))
            Toggle("Auto-pair brackets", isOn: toggle(\.autoPairBrackets))
            Toggle("Auto-pair Markdown syntax", isOn: toggle(\.autoPairMarkdownSyntax))
            Toggle("Smart quotes", isOn: toggle(\.smartQuotes))
            Picker(
                "Indent size",
                selection: editor(
                    get: { Double($0.indentSize) },
                    set: { $0.indentSize = Int($1) }
                )
            ) {
                Text("2 spaces").tag(2.0)
                Text("4 spaces").tag(4.0)
                Text("8 spaces").tag(8.0)
            }
            Picker(
                "Code block indent",
                selection: editor(
                    get: { Double($0.codeIndentSize) },
                    set: { $0.codeIndentSize = Int($1) }
                )
            ) {
                Text("2 spaces").tag(2.0)
                Text("4 spaces").tag(4.0)
                Text("8 spaces").tag(8.0)
            }
        }
    }

    private func toggle(_ keyPath: WritableKeyPath<EditorSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings.settings[keyPath: keyPath] },
            set: { newValue in store.settings.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func editor<V>(
        get: @escaping (EditorSettings) -> V, set: @escaping (inout EditorSettings, V) -> Void
    ) -> Binding<V> {
        Binding(
            get: { get(store.settings.settings) },
            set: { newValue in store.settings.update { set(&$0, newValue) } }
        )
    }
}

// MARK: - Markdown

private struct MarkdownPane: View {
    let store: AppStore

    var body: some View {
        PaneGroup {
            Toggle("Strict Markdown", isOn: toggle(\.strictMarkdown))
            Toggle("Inline math ($…$)", isOn: toggle(\.enableInlineMath))
            Toggle("Subscript (~…~)", isOn: toggle(\.enableSubscript))
            Toggle("Superscript (^…^)", isOn: toggle(\.enableSuperscript))
            Toggle("Highlight (==…==)", isOn: toggle(\.enableHighlight))
            Toggle("Alert blocks", isOn: toggle(\.enableAlert))
            Toggle("Strikethrough (~~…~~)", isOn: toggle(\.enableStrike))
            Toggle(
                "Automatically link URLs",
                isOn: Binding(
                    get: { !store.settings.settings.noAutoLink },
                    set: { newValue in store.settings.update { $0.noAutoLink = !newValue } }
                )
            )
            Toggle("Emoji autocomplete (:)", isOn: toggle(\.emojiAutocomplete))
            Toggle("Ignore single line breaks", isOn: toggle(\.ignoreLineBreak))
        }
        .padded()
    }

    private func toggle(_ keyPath: WritableKeyPath<EditorSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings.settings[keyPath: keyPath] },
            set: { newValue in store.settings.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}

// MARK: - Files

private struct FilesPane: View {
    let store: AppStore

    var body: some View {
        PaneGroup {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files panel folder")
                    Text(
                        store.settings.settings.sidebarFolderPath
                            ?? "The open document's folder"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose…") { chooseFolder() }
                Button("Reset") {
                    store.settings.update { $0.sidebarFolderPath = nil }
                }
            }
            Toggle(
                "Show hidden files",
                isOn: Binding(
                    get: { store.settings.settings.showHiddenFiles },
                    set: { newValue in store.settings.update { $0.showHiddenFiles = newValue } }
                )
            )
        }
        .padded()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.update { $0.sidebarFolderPath = url.path }
    }
}

extension View {
    /// The grouped form style fills the tab; a fixed height keeps the window
    /// from jumping between panes of different length.
    fileprivate func padded() -> some View {
        frame(minHeight: 260, alignment: .top)
    }
}
