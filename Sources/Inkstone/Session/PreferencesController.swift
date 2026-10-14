import AppKit
import Observation
import SwiftUI

/// One pane of the Settings window, listed in its sidebar in Typora's order:
/// Files, Editor, Markdown, Appearance, General.
enum SettingsPane: Hashable, CaseIterable, Identifiable {
    case files
    case editor
    case markdown
    case appearance
    case general

    var id: Self { self }

    var title: String {
        switch self {
        case .files: "Files"
        case .editor: "Editor"
        case .markdown: "Markdown"
        case .appearance: "Appearance"
        case .general: "General"
        }
    }

    var systemImage: String {
        switch self {
        case .files: "doc"
        case .editor: "pencil"
        case .markdown: "number"
        case .appearance: "paintbrush"
        case .general: "gearshape"
        }
    }
}

/// One settings window's session. Browser semantics, as in Canoe: choosing a
/// pane truncates what was ahead, and re-choosing it is not a move.
@MainActor
@Observable
final class SettingsNavigationState {
    private var history: [SettingsPane] = [.files]
    private var historyIndex = 0

    /// Refreshed by every navigation so the AppKit toolbar can sync its title
    /// and button states.
    var onChange: (() -> Void)?

    var pane: SettingsPane { history[historyIndex] }
    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    func select(_ pane: SettingsPane) {
        guard pane != history[historyIndex] else { return }
        history.removeSubrange((historyIndex + 1)...)
        history.append(pane)
        historyIndex = history.count - 1
        onChange?()
    }

    func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        onChange?()
    }

    func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        onChange?()
    }
}

/// The Settings window (⌘,), in Typora's image: a sidebar with a search field
/// and one row per concern, and a scrollable detail pane whose sections carry
/// bold headers. Every control wires straight into `SettingsStore` - a change
/// lands in the JSON on disk and reaches every open window through `onChange`.
///
/// Only preferences the app actually consumes appear here; the full inventory
/// lives in `Docs/option-inventory.md`, and a switch that does nothing is worse
/// than a missing one.
@MainActor
final class PreferencesController: NSWindowController {
    static let shared = PreferencesController()

    private let navigation: SettingsNavigationState
    private let toolbarController: SettingsToolbarController

    private init() {
        let navigation = SettingsNavigationState()
        let sidebar = SettingsSidebarView().environment(navigation).focusEffectDisabled()
        let detail = SettingsDetailView().environment(navigation)
        let split = PreferencesSplitViewController(sidebar: sidebar, detail: detail)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = split
        window.tabbingMode = .disallowed
        // Content-layer fill behind a transparent titlebar, with the unified
        // toolbar drawing over the pane surfaces - Canoe's window recipe.
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 460)
        // Center BEFORE the autosave name: setFrameAutosaveName restores the
        // saved frame immediately, and a later center() would discard the
        // remembered position on every launch.
        window.center()
        window.setFrameAutosaveName("Inkstone Settings Window")
        let toolbarController = SettingsToolbarController(navigation: navigation)
        toolbarController.install(in: window)
        self.navigation = navigation
        self.toolbarController = toolbarController
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PreferencesController is created in code")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// A real `NSSplitViewController` so the sidebar item gets the full-height,
/// full-bleed sidebar treatment under the transparent titlebar.
private final class PreferencesSplitViewController: NSSplitViewController {
    init(sidebar: some View, detail: some View) {
        super.init(nibName: nil, bundle: nil)

        // sizingOptions must stay empty so SwiftUI never drives the window
        // size (the window owns its frame and minimum size instead).
        let sidebarHost = NSHostingController(rootView: sidebar)
        sidebarHost.sizingOptions = []
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 200
        sidebarItem.canCollapse = false

        let detailHost = NSHostingController(rootView: detail)
        detailHost.sizingOptions = []
        let detailItem = NSSplitViewItem(viewController: detailHost)
        detailItem.minimumThickness = 460

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// AppKit, not SwiftUI's `.toolbar`: that only reaches a window owned by a
/// SwiftUI `Scene`. Back/forward over the pane history, exactly as Canoe does.
@MainActor
final class SettingsToolbarController: NSObject, NSToolbarDelegate {
    private static let back = NSToolbarItem.Identifier("SettingsBack")
    private static let forward = NSToolbarItem.Identifier("SettingsForward")

    private let navigation: SettingsNavigationState
    private weak var window: NSWindow?
    private let backButton: NSButton
    private let forwardButton: NSButton

    init(navigation: SettingsNavigationState) {
        self.navigation = navigation
        // Two buttons, not a segmented control: that would draw a divider down the middle.
        backButton = Self.makeButton("chevron.backward", "Back")
        forwardButton = Self.makeButton("chevron.forward", "Forward")
        super.init()
        backButton.target = self
        backButton.action = #selector(goBack)
        forwardButton.target = self
        forwardButton.action = #selector(goForward)
    }

    func install(in window: NSWindow) {
        self.window = window
        window.toolbarStyle = .unified
        // `.automatic` draws a hairline once content scrolls under the bar, splitting the surface.
        window.titlebarSeparatorStyle = .none
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        // Labels would print "Back"/"Forward" under the chevrons and double the bar's height.
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        // Both, or a right-click still offers the display-mode items.
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar

        navigation.onChange = { [weak self] in self?.sync() }
        sync()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.back, Self.forward]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.back:
            item.view = backButton
            item.label = "Back"
        case Self.forward:
            item.view = forwardButton
            item.label = "Forward"
        default:
            return nil
        }
        // The one flag that seats an item ahead of the inline title rather than after it.
        item.isNavigational = true
        item.visibilityPriority = .high
        // The buttons take their enabled state from the history, not from responder validation.
        item.autovalidates = false
        return item
    }

    // MARK: - Private

    @objc private func goBack() { navigation.goBack() }
    @objc private func goForward() { navigation.goForward() }

    private func sync() {
        window?.title = navigation.pane.title
        backButton.isEnabled = navigation.canGoBack
        forwardButton.isEnabled = navigation.canGoForward
    }

    /// The directional pair, not `chevron.left/right`, so the control mirrors in RTL.
    private static func makeButton(_ symbol: String, _ label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let button = NSButton(image: image ?? NSImage(), target: nil, action: nil)
        button.bezelStyle = .toolbar
        button.setAccessibilityLabel(label)
        button.toolTip = label
        return button
    }
}

// MARK: - Sidebar

private struct SettingsSidebarView: View {
    @Environment(SettingsNavigationState.self) private var navigation

    var body: some View {
        List(selection: selection) {
            ForEach(SettingsPane.allCases) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .tag(pane)
            }
        }
        .listStyle(.sidebar)
        // No painted background: the sidebar split item's own material must
        // show through, so the sidebar stays a different surface from the
        // grouped detail pane.
    }

    /// `List` hands back an optional selection; routing it through `select`
    /// keeps the state the one owner of the pane.
    private var selection: Binding<SettingsPane?> {
        Binding(
            get: { navigation.pane },
            set: { if let pane = $0 { navigation.select(pane) } }
        )
    }
}

// MARK: - Detail

private struct SettingsDetailView: View {
    @Environment(SettingsNavigationState.self) private var navigation

    var body: some View {
        switch navigation.pane {
        case .files: FilesPane(store: AppStore.shared)
        case .editor: EditorPane(store: AppStore.shared)
        case .markdown: MarkdownPane(store: AppStore.shared)
        case .appearance: AppearancePane(store: AppStore.shared)
        case .general: GeneralPane(store: AppStore.shared)
        }
    }
}

/// Typora's section headers are bold body text, not the grouped-form caption
/// style.
private func sectionHeader(_ text: String) -> some View {
    Text(text).font(.system(size: 13, weight: .bold))
}

// MARK: - Files

private struct FilesPane: View {
    let store: AppStore

    var body: some View {
        Form {
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
                            chooseLaunchFolder()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                sectionHeader("Launch")
            }

            Section {
                HStack {
                    Text("Files panel folder")
                    Spacer()
                    Text(
                        store.settings.settings.sidebarFolderPath
                            ?? "The open document's folder"
                    )
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    Button("Choose…") { chooseSidebarFolder() }
                    Button("Reset") {
                        store.settings.update { $0.sidebarFolderPath = nil }
                    }
                }
                Toggle(
                    "Show hidden files",
                    isOn: setting(
                        get: { $0.showHiddenFiles },
                        set: { $0.showHiddenFiles = $1 }
                    )
                )
            } header: {
                sectionHeader("Files Panel")
            }

            Section {
                Toggle(
                    "Record recent files and folders",
                    isOn: setting(
                        get: { $0.recordRecentFiles },
                        set: { $0.recordRecentFiles = $1 }
                    )
                )
            } header: {
                sectionHeader("Recent")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseLaunchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.update { $0.launchFolderPath = url.path }
    }

    private func chooseSidebarFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.settings.update { $0.sidebarFolderPath = url.path }
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

// MARK: - Editor

private struct EditorPane: View {
    let store: AppStore

    var body: some View {
        Form {
            Section {
                Toggle("Show invisible characters", isOn: toggle(\.showInvisibleCharacters))
                Toggle("Auto-pair brackets", isOn: toggle(\.autoPairBrackets))
                Toggle("Auto-pair Markdown syntax", isOn: toggle(\.autoPairMarkdownSyntax))
                Toggle("Smart quotes", isOn: toggle(\.smartQuotes))
            } header: {
                sectionHeader("Editing")
            }

            Section {
                Picker(
                    "Indent size",
                    selection: setting(
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
                    selection: setting(
                        get: { Double($0.codeIndentSize) },
                        set: { $0.codeIndentSize = Int($1) }
                    )
                ) {
                    Text("2 spaces").tag(2.0)
                    Text("4 spaces").tag(4.0)
                    Text("8 spaces").tag(8.0)
                }
            } header: {
                sectionHeader("Indentation")
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(_ keyPath: WritableKeyPath<EditorSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings.settings[keyPath: keyPath] },
            set: { newValue in store.settings.update { $0[keyPath: keyPath] = newValue } }
        )
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

// MARK: - Markdown

private struct MarkdownPane: View {
    let store: AppStore

    var body: some View {
        Form {
            Section {
                Toggle("Strict Markdown", isOn: toggle(\.strictMarkdown))
                Toggle("Ignore single line breaks", isOn: toggle(\.ignoreLineBreak))
                Toggle(
                    "Automatically link URLs",
                    isOn: Binding(
                        get: { !store.settings.settings.noAutoLink },
                        set: { newValue in store.settings.update { $0.noAutoLink = !newValue } }
                    )
                )
            } header: {
                sectionHeader("Parsing")
            }

            Section {
                Toggle("Inline math ($…$)", isOn: toggle(\.enableInlineMath))
                Toggle("Subscript (~…~)", isOn: toggle(\.enableSubscript))
                Toggle("Superscript (^…^)", isOn: toggle(\.enableSuperscript))
                Toggle("Highlight (==…==)", isOn: toggle(\.enableHighlight))
                Toggle("Alert blocks", isOn: toggle(\.enableAlert))
                Toggle("Strikethrough (~~…~~)", isOn: toggle(\.enableStrike))
                Toggle("Emoji autocomplete (:)", isOn: toggle(\.emojiAutocomplete))
            } header: {
                sectionHeader("Syntax Extensions")
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(_ keyPath: WritableKeyPath<EditorSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.settings.settings[keyPath: keyPath] },
            set: { newValue in store.settings.update { $0[keyPath: keyPath] = newValue } }
        )
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    let store: AppStore

    var body: some View {
        Form {
            Section {
                Picker(
                    "Light Mode",
                    selection: Binding(
                        get: { store.settings.settings.themeIdentifier },
                        set: { store.themeManager.selectLightTheme(identifier: $0) }
                    )
                ) {
                    ForEach(store.themeManager.available, id: \.identifier) { theme in
                        Text(theme.displayName).tag(theme.identifier)
                    }
                }
                Picker(
                    "Dark Mode",
                    selection: Binding(
                        get: { store.settings.settings.darkThemeIdentifier },
                        set: { store.themeManager.selectDarkTheme(identifier: $0) }
                    )
                ) {
                    Text("Same as Light Mode").tag(String?.none)
                    ForEach(store.themeManager.available, id: \.identifier) { theme in
                        Text(theme.displayName).tag(Optional(theme.identifier))
                    }
                }
            } header: {
                sectionHeader("Theme")
            }

            Section {
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
            } header: {
                sectionHeader("Font Size")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralPane: View {
    let store: AppStore

    var body: some View {
        Form {
            Section {
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
            } header: {
                sectionHeader("Saving")
            }

            Section {
                Stepper(
                    "Reading speed: \(store.settings.settings.wordsPerMinute) wpm",
                    value: setting(
                        get: { Double($0.wordsPerMinute) },
                        set: { $0.wordsPerMinute = Int($1) }
                    ),
                    in: 100...800,
                    step: 10
                )
            } header: {
                sectionHeader("Reading")
            }
        }
        .formStyle(.grouped)
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
