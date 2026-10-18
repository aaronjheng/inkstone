import AppKit

/// Process entry point.
///
/// An explicit `NSApplication` rather than `NSApplicationMain` because there is no
/// nib: the menu bar and the first window are built in code. The whole app is one
/// target, so the engine is already in this module and nothing needs importing.
@main
@MainActor
struct InkstoneApp {
    static func main() {
        // Headless layout dump: parse the arguments before any UI exists and
        // exit without NSApplication - the comparison pipeline drives this
        // (see Editor/LayoutDump.swift and .agents/skills/render-parity/).
        if CommandLine.arguments.contains("--dump-layout") {
            FontRegistration.registerBundledFonts()
            exit(LayoutDump.run(CommandLine.arguments))
        }
        // Theme fonts have to resolve before the first window is built.
        FontRegistration.registerBundledFonts()
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        // Called by hand rather than by the notification: `run()` is what posts it,
        // and the theme has to be in place before the first window is built.
        delegate.applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )
        application.run()
    }
}
