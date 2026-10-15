import AppKit
import Foundation

/// Builds the menu bar in code.
///
/// The original's menu is a compiled `MainMenu.nib` with 184 action selectors. Building
/// it here keeps the actions and their enable state in one file with the logic that
/// backs them, and avoids a nib the project file has to track.
enum MenuBuilder {
    @MainActor
    static func build(store: AppStore, responder: AppDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(applicationMenuItem(store: store))
        main.addItem(fileMenuItem(responder: responder, store: store))
        main.addItem(editMenuItem(responder: responder, store: store))
        main.addItem(paragraphMenuItem(responder: responder))
        main.addItem(formatMenuItem(responder: responder))
        main.addItem(viewMenuItem(responder: responder, store: store))
        main.addItem(themesMenuItem(store: store))
        main.addItem(windowMenuItem())
        main.addItem(helpMenuItem(responder: responder))
        return main
    }

    /// Read from the bundle rather than written out: a literal here is how the
    /// menu ends up saying "About <旧名>" after the app is renamed.
    static var applicationName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Inkstone"
    }

    // MARK: - Application

    @MainActor
    private static func applicationMenuItem(store: AppStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: applicationName)
        menu.addItem(
            withTitle: "About \(applicationName)", action: #selector(AppDelegate.openAbout(_:)), keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Settings…", action: #selector(AppDelegate.openSettings(_:)), keyEquivalent: ","
        )
        menu.addItem(.separator())
        let servicesItem = menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let services = NSMenu(title: "Services")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide \(applicationName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"
        )
        let hideOthers = menu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit \(applicationName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        // The title must be set explicitly: `NSMenuItem()` defaults to
        // "NSMenuItem" and assigning a submenu never syncs it. The bar itself
        // displays the submenu's title and looks fine, but every `title ==`
        // menu lookup in AppDelegate silently failed on the mismatch.
        item.submenu = menu
        item.title = menu.title
        return item
    }

    // MARK: - File

    @MainActor
    private static func fileMenuItem(responder: AppDelegate, store: AppStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        menu.addItem(
            withTitle: "New", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n"
        ).target = responder
        menu.addItem(
            withTitle: "New Tab", action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "t"
        ).target = responder
        menu.addItem(
            withTitle: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n"
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.items.last?.target = responder
        menu.addItem(
            withTitle: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o"
        ).target = responder
        // ⌘⌥O belongs to the numbered-list command, as in the original; this
        // project's folder picker takes ⌘⇧O (where the original opens quickly).
        menu.addItem(
            withTitle: "Open Folder…", action: #selector(AppDelegate.openFolder(_:)), keyEquivalent: "o"
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.items.last?.target = responder
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close", action: #selector(AppDelegate.closeDocument(_:)), keyEquivalent: "w"
        ).target = responder
        menu.addItem(
            withTitle: "Save", action: #selector(AppDelegate.saveDocument(_:)), keyEquivalent: "s"
        ).target = responder
        menu.addItem(
            withTitle: "Save As…", action: #selector(AppDelegate.saveDocumentAs(_:)), keyEquivalent: "s"
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.items.last?.target = responder
        menu.addItem(
            withTitle: "Revert to Saved", action: #selector(AppDelegate.revertDocument(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(.separator())

        let recent = NSMenu(title: "Open Recent")
        recent.autoenablesItems = false
        for url in store.recentFiles {
            let entry = recent.addItem(
                withTitle: url.lastPathComponent, action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: ""
            )
            entry.target = responder
            entry.representedObject = url
            entry.isEnabled = true
        }
        if store.recentFiles.isEmpty {
            let empty = recent.addItem(withTitle: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        let recentItem = menu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Export…", action: #selector(AppDelegate.exportDocument(_:)), keyEquivalent: "e"
        ).target = responder
        menu.addItem(
            withTitle: "Print…", action: #selector(AppDelegate.printDocument(_:)), keyEquivalent: "p"
        ).target = responder
        menu.addItem(.separator())
        item.submenu = menu
        item.title = menu.title
        return item
    }

    // MARK: - Edit

    @MainActor
    private static func editMenuItem(responder: AppDelegate, store: AppStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        menu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(
            withTitle: "Copy as Markdown", action: #selector(AppDelegate.copyAsMarkdown(_:)), keyEquivalent: "c"
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.items.last?.target = responder
        menu.addItem(
            withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        )
        menu.addItem(
            withTitle: "Paste as Plain Text", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v"
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        menu.addItem(
            withTitle: "Select Line", action: #selector(NSText.selectLine(_:)), keyEquivalent: "l"
        ).keyEquivalentModifierMask = [.command]
        for (title, selector, key) in [
            ("Find…", #selector(AppDelegate.toggleFind(_:)), "f"),
            ("Find Next", #selector(AppDelegate.findNext(_:)), "g"),
            ("Find Previous", #selector(AppDelegate.findPrevious(_:)), "G"),
            ("Replace…", #selector(AppDelegate.toggleFind(_:)), "h"),
        ] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key)
            item.target = responder
        }
        menu.addItem(.separator())
        // A nil action renders disabled and reads as a broken feature; the smart-
        // quote behaviour itself lives in the Editor pane, so the stub goes.
        menu.addItem(
            withTitle: "Toggle Source Mode", action: #selector(AppDelegate.toggleSourceMode(_:)), keyEquivalent: "/"
        ).target = responder
        item.submenu = menu
        item.title = menu.title
        return item
    }

    // MARK: - Paragraph

    /// Typora's block-level menu: headings, block inserts, lists, indent.
    ///
    /// Inline styles stay in `formatMenuItem`; everything here rewrites whole
    /// lines via `FormatController`, except indent which the editor routes.
    @MainActor
    private static func paragraphMenuItem(responder: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Paragraph")

        func entry(
            _ title: String, _ action: FormatAction, _ key: String,
            _ modifiers: NSEvent.ModifierFlags = .command
        ) {
            let menuItem = menu.addItem(
                withTitle: title,
                action: #selector(AppDelegate.applyFormatting(_:)),
                keyEquivalent: key
            )
            menuItem.keyEquivalentModifierMask = modifiers
            menuItem.target = responder
            menuItem.representedObject = action.rawValue
        }

        for level in 1...6 {
            entry("Heading \(level)", FormatAction.heading(level), String(level))
        }
        entry("Paragraph", .paragraph, "0")
        entry("Increase Heading Level", .increaseHeading, "=")
        entry("Decrease Heading Level", .decreaseHeading, "-")
        menu.addItem(.separator())
        entry("Table", .table, "t", [.command, .option])
        entry("Code Fences", .codeBlock, "c", [.command, .option])
        entry("Math Block", .mathBlock, "b", [.command, .option])
        entry("Quote", .quote, "q", [.command, .option])
        entry("Ordered List", .orderedList, "o", [.command, .option])
        entry("Unordered List", .bulletList, "u", [.command, .option])
        entry("Task List", .taskList, "x", [.command, .option])
        menu.addItem(.separator())
        entry("Indent", .indent, "[", .command)
        entry("Outdent", .outdent, "]", .command)
        menu.addItem(.separator())
        entry("Horizontal Rule", .horizontalRule, "")
        entry("Table of Contents", .tableOfContents, "")
        entry("YAML Front Matter", .frontMatter, "")
        entry("Footnote", .footnote, "")
        menu.addItem(.separator())
        // Table cell operations live in a submenu here, as in the original's
        // table context menu: the Paragraph menu only inserts a table.
        let tableItem = NSMenuItem(title: "Edit Table", action: nil, keyEquivalent: "")
        let tableMenu = NSMenu(title: "Edit Table")
        func tableEntry(_ title: String, _ action: FormatAction) {
            let row = tableMenu.addItem(
                withTitle: title,
                action: #selector(AppDelegate.applyFormatting(_:)),
                keyEquivalent: ""
            )
            row.target = responder
            row.representedObject = action.rawValue
        }
        tableEntry("Insert Row Above", .tableRowAbove)
        tableEntry("Insert Row Below", .tableRowBelow)
        tableEntry("Delete Row", .tableDeleteRow)
        tableMenu.addItem(.separator())
        tableEntry("Insert Column Left", .tableColumnLeft)
        tableEntry("Insert Column Right", .tableColumnRight)
        tableEntry("Delete Column", .tableDeleteColumn)
        tableMenu.addItem(.separator())
        tableEntry("Align Left", .tableAlignLeft)
        tableEntry("Align Center", .tableAlignCenter)
        tableEntry("Align Right", .tableAlignRight)
        tableItem.submenu = tableMenu
        menu.addItem(tableItem)
        item.submenu = menu
        item.title = menu.title
        return item
    }

    // MARK: - Format

    /// Typora's inline-level menu: every entry wraps or unwraps the selection.
    @MainActor
    private static func formatMenuItem(responder: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Format")

        func entry(
            _ title: String, _ action: FormatAction, _ key: String,
            _ modifiers: NSEvent.ModifierFlags = .command
        ) {
            let menuItem = menu.addItem(
                withTitle: title,
                action: #selector(AppDelegate.applyFormatting(_:)),
                keyEquivalent: key
            )
            menuItem.keyEquivalentModifierMask = modifiers
            menuItem.target = responder
            menuItem.representedObject = action.rawValue
        }

        entry("Bold", .bold, "b")
        entry("Italic", .italic, "i")
        entry("Underline", .underline, "u")
        entry("Inline Code", .inlineCode, "`", [.command, .shift])
        entry("Strikethrough", .strikethrough, "`", [.control, .shift])
        entry("Inline Math", .inlineMath, "m", [.command, .shift])
        entry("Highlight", .highlight, "")
        entry("Subscript", .`subscript`, "")
        entry("Superscript", .superscript, "")
        menu.addItem(.separator())
        entry("Link", .link, "k")
        entry("Image", .image, "i", [.command, .control])
        entry("Clear Format", .clearFormat, "\\")
        item.submenu = menu
        item.title = menu.title
        return item
    }

    // MARK: - View

    @MainActor
    private static func viewMenuItem(responder: AppDelegate, store: AppStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        menu.addItem(
            withTitle: "Source Code Mode", action: #selector(AppDelegate.toggleSourceMode(_:)), keyEquivalent: "/"
        ).target = responder
        // Function-key equivalents: F8 is U+F70B, F9 is U+F70C.
        menu.addItem(
            withTitle: "Focus Mode", action: #selector(AppDelegate.toggleFocusMode(_:)),
            keyEquivalent: "\u{F70B}"
        ).target = responder
        menu.items.last?.keyEquivalentModifierMask = []
        menu.addItem(
            withTitle: "Typewriter Mode", action: #selector(AppDelegate.toggleTypewriterMode(_:)),
            keyEquivalent: "\u{F70C}"
        ).target = responder
        menu.items.last?.keyEquivalentModifierMask = []
        menu.addItem(
            withTitle: "Readonly Mode", action: #selector(AppDelegate.toggleReadonlyMode(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(.separator())
        // Typora toggles its sidebar with ⌘⇧L; this project's three panels keep
        // the ⌘\ family instead.
        for (title, action, key, modifiers) in [
            ("Sidebar", #selector(AppDelegate.toggleSidebar(_:)), "\\", NSEvent.ModifierFlags.command),
            ("Files", #selector(AppDelegate.toggleFiles(_:)), "\\", [.command, .shift]),
            ("Outline", #selector(AppDelegate.toggleOutline(_:)), "\\", [.command, .option]),
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = responder
        }
        menu.addItem(.separator())
        // The image actions act on the file the painter draws (so the buffer stays
        // byte-identical and the source is still `![alt](path)`); they get a real
        // submenu instead of titles with “›” baked in.
        let imageItem = menu.addItem(withTitle: "Image", action: nil, keyEquivalent: "")
        let imageMenu = NSMenu(title: "Image")
        for (title, action) in [
            ("Delete", #selector(AppDelegate.imageDelete(_:))),
            ("Rename…", #selector(AppDelegate.imageRename(_:))),
            ("Move…", #selector(AppDelegate.imageMove(_:))),
            ("Scale 50%…", #selector(AppDelegate.imageScaleHalf(_:))),
        ] {
            let entry = imageMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            entry.target = responder
        }
        imageItem.submenu = imageMenu
        // ⌘P belongs to Print; Quick Open was silently unreachable on the same
        // chord, and File precedes View in the bar.
        menu.addItem(
            withTitle: "Quick Open…", action: #selector(AppDelegate.quickOpen(_:)), keyEquivalent: "p"
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.items.last?.target = responder
        menu.addItem(.separator())
        // Typora leaves zoom unbound; ⌘0/⌘- already belong to Paragraph and
        // ⌘+ is not a menu key, so these stay clickable-only.
        menu.addItem(
            withTitle: "Actual Size", action: #selector(AppDelegate.actualSize(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(
            withTitle: "Zoom In", action: #selector(AppDelegate.zoomIn(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(
            withTitle: "Zoom Out", action: #selector(AppDelegate.zoomOut(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"
        ).keyEquivalentModifierMask = [.command, .control]
        // Checkmarks are rebuilt every time the menu opens (AppDelegate conforms
        // to NSMenuDelegate for exactly this).
        menu.delegate = responder
        item.submenu = menu
        item.title = menu.title
        return item
    }

    // MARK: - Themes

    @MainActor
    private static func themesMenuItem(store: AppStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Themes")
        for theme in store.availableThemes {
            let entry = menu.addItem(
                withTitle: theme.displayName,
                action: #selector(AppDelegate.selectTheme(_:)), keyEquivalent: ""
            )
            entry.target = NSApp.delegate as? AppDelegate
            entry.representedObject = theme.identifier
            entry.state = theme.identifier == store.theme.identifier ? .on : .off
        }
        menu.addItem(.separator())
        let useThemeSize = menu.addItem(
            withTitle: "Use Theme Font Size", action: #selector(AppDelegate.useThemeFontSize(_:)), keyEquivalent: ""
        )
        useThemeSize.target = NSApp.delegate as? AppDelegate
        useThemeSize.state = store.settings.settings.useCustomFontSize ? .off : .on
        menu.delegate = NSApp.delegate as? AppDelegate
        item.submenu = menu
        item.title = menu.title
        return item
    }

    // MARK: - Window and Help

    @MainActor
    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Show Previous Tab",
            action: #selector(AppDelegate.showPreviousTab(_:)),
            keyEquivalent: "["
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(
            withTitle: "Show Next Tab",
            action: #selector(AppDelegate.showNextTab(_:)),
            keyEquivalent: "]"
        ).keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        for number in 1...9 {
            let tabItem = menu.addItem(
                withTitle: "Show Tab \(number)",
                action: #selector(AppDelegate.showTab(_:)),
                keyEquivalent: "\(number)"
            )
            tabItem.keyEquivalentModifierMask = [.command]
            tabItem.representedObject = number
        }
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""
        )
        item.submenu = menu
        item.title = menu.title
        NSApp.windowsMenu = menu
        return item
    }

    @MainActor
    private static func helpMenuItem(responder: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(
            withTitle: "Markdown Reference", action: #selector(AppDelegate.openReference(_:)),
            keyEquivalent: ""
        ).target = responder
        item.submenu = menu
        item.title = menu.title
        NSApp.helpMenu = menu
        return item
    }
}
