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
        main.addItem(formatMenuItem(responder: responder))
        main.addItem(viewMenuItem(responder: responder, store: store))
        main.addItem(themesMenuItem(store: store))
        main.addItem(windowMenuItem())
        main.addItem(helpMenuItem())
        return main
    }

    /// Read from the bundle rather than written out: a literal here is how the
    /// menu ends up saying "About <旧名>" after the app is renamed.
    private static var applicationName: String {
        Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Inkstone"
    }

    // MARK: - Application

    @MainActor
    private static func applicationMenuItem(store: AppStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: applicationName)
        menu.addItem(
            withTitle: "About \(applicationName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""
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
        item.submenu = menu
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
            withTitle: "New Window", action: #selector(AppDelegate.newDocument(_:)), keyEquivalent: "n"
        ).keyEquivalentModifierMask = [.command, .option]
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
        for url in store.recentFiles {
            let entry = recent.addItem(
                withTitle: url.lastPathComponent, action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: ""
            )
            entry.target = responder
            entry.representedObject = url
        }
        if store.recentFiles.isEmpty {
            recent.addItem(withTitle: "No Recent Files", action: nil, keyEquivalent: "")
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
            withTitle: "Copy as Markdown", action: #selector(NSText.copy(_:)), keyEquivalent: "c"
        ).keyEquivalentModifierMask = [.command, .shift]
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
        let substitutions = menu.addItem(withTitle: "Substitutions", action: nil, keyEquivalent: "")
        substitutions.submenu = NSMenu(title: "Substitutions")
        substitutions.submenu?.addItem(
            withTitle: "Smart Quotes", action: nil, keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Toggle Source Mode", action: #selector(AppDelegate.toggleSourceMode(_:)), keyEquivalent: "."
        ).target = responder
        item.submenu = menu
        return item
    }

    // MARK: - Format

    /// Typora's default macOS bindings, action by action.
    ///
    /// `Open Folder` yields ⌘⌥O to the numbered-list command (Typora's own
    /// binding) and takes ⌘⇧O, which is where the original opens a folder
    /// quickly anyway; `Clear Format` (⌘\) is not bound because the sidebar
    /// already owns that key here.
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

        for level in 1...6 {
            entry("Heading \(level)", FormatAction.heading(level), String(level))
        }
        entry("Paragraph", .paragraph, "0")
        entry("Increase Heading Level", .increaseHeading, "=")
        entry("Decrease Heading Level", .decreaseHeading, "")
        menu.addItem(.separator())
        entry("Bold", .bold, "b")
        entry("Italic", .italic, "i")
        entry("Underline", .underline, "u")
        entry("Inline Code", .inlineCode, "`", [.command, .shift])
        entry("Strikethrough", .strikethrough, "`", [.control, .shift])
        entry("Inline Math", .inlineMath, "m", [.command, .shift])
        entry("Highlight", .highlight, "")
        entry("Link", .link, "k")
        entry("Image", .image, "i", [.command, .control])
        entry("Clear Format", .clearFormat, "")
        menu.addItem(.separator())
        entry("Code Block", .codeBlock, "c", [.command, .option])
        entry("Math Block", .mathBlock, "b", [.command, .option])
        entry("Quote", .quote, "q", [.command, .option])
        entry("Bullet List", .bulletList, "u", [.command, .option])
        entry("Numbered List", .orderedList, "o", [.command, .option])
        entry("Task List", .taskList, "x", [.command, .option])
        entry("Table", .table, "t", [.command, .option])
        menu.addItem(.separator())
        entry("Horizontal Rule", .horizontalRule, "")
        entry("Table of Contents", .tableOfContents, "")
        entry("YAML Front Matter", .frontMatter, "")
        item.submenu = menu
        return item
    }

    // MARK: - View

    @MainActor
    private static func viewMenuItem(responder: AppDelegate, store: AppStore) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        menu.addItem(
            withTitle: "Source Code Mode", action: #selector(AppDelegate.toggleSourceMode(_:)), keyEquivalent: "."
        ).target = responder
        menu.addItem(
            withTitle: "Focus Mode", action: #selector(AppDelegate.toggleFocusMode(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(
            withTitle: "Typewriter Mode", action: #selector(AppDelegate.toggleTypewriterMode(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(
            withTitle: "Readonly Mode", action: #selector(AppDelegate.toggleReadonlyMode(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(.separator())
        // The original toggles its sidebar with ⌘\; the two panels join that family.
        for (title, action, key, modifiers) in [
            ("Sidebar", #selector(AppDelegate.toggleSidebar(_:)), "\\", NSEvent.ModifierFlags.command),
            ("Files", #selector(AppDelegate.toggleFiles(_:)), "\\", [.command, .shift]),
            ("Outline", #selector(AppDelegate.toggleOutline(_:)), "\\", [.command, .option]),
        ] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = responder
        }
        // Image family actions: the image is drawn rather than attached (so the buffer
        // stays byte-identical and the source is still `![alt](path)`). The menu acts on
        // the file, not the node, so it uses the document's base folder.
        menu.addItem(
            withTitle: "Image › Delete", action: #selector(AppDelegate.imageDelete(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(
            withTitle: "Image › Rename", action: #selector(AppDelegate.imageRename(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(
            withTitle: "Image › Move…", action: #selector(AppDelegate.imageMove(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(
            withTitle: "Image › Scale 50%", action: #selector(AppDelegate.imageScaleHalf(_:)), keyEquivalent: ""
        ).target = responder
        menu.addItem(
            withTitle: "Quick Open…", action: #selector(AppDelegate.quickOpen(_:)), keyEquivalent: "p"
        ).target = responder
        menu.addItem(withTitle: "Status Bar", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Actual Size", action: #selector(AppDelegate.actualSize(_:)), keyEquivalent: "0"
        ).target = responder
        menu.addItem(
            withTitle: "Zoom In", action: #selector(AppDelegate.zoomIn(_:)), keyEquivalent: "+"
        ).target = responder
        menu.addItem(
            withTitle: "Zoom Out", action: #selector(AppDelegate.zoomOut(_:)), keyEquivalent: "-"
        ).target = responder
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"
        ).keyEquivalentModifierMask = [.command, .control]
        item.submenu = menu
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
        item.submenu = menu
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
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""
        )
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    @MainActor
    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(
            withTitle: "Markdown Reference", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: ""
        )
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }
}
