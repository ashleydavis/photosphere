//
// The Ziggy example's MacOS shell: a window and Ziggy's web view in the window. Everything else is
// in ZiggyShellMacOS.
//

import AppKit
import ZiggyShellMacOS

// Owns the window and Ziggy's bridge for the life of the application.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // The window, once the application has launched.
    private var window: NSWindow?

    // Ziggy's bridge, once the application has launched.
    private var bridge: ZiggyBridge?

    // Creates the window and starts Ziggy, which draws the main menu.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = AppDelegate.windowSize()

        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let newWindow = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        newWindow.title = "Ziggy example"
        newWindow.isReleasedWhenClosed = false
        // Lets toggle-fullscreen take the window full screen.
        newWindow.collectionBehavior.insert(.fullScreenPrimary)
        let newBridge = ZiggyBridge(frame: frame)
        newWindow.contentView = newBridge.webView
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window = newWindow
        bridge = newBridge
        newBridge.start()
    }

    // Closing the window ends the application.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // Destroys the core before the process ends.
    func applicationWillTerminate(_ notification: Notification) {
        bridge?.shutdown()
    }

    // The window size: the WxH or WxH+X+Y text of a -geometry=... argument when there is one (the position is ignored),
    // otherwise 900 by 800.
    private static func windowSize() -> CGSize {
        for argument in CommandLine.arguments {
            guard argument.hasPrefix("-geometry=") else {
                continue
            }
            let text = argument.dropFirst("-geometry=".count)
            let parts = text.split(separator: "x", maxSplits: 1)
            guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1].prefix(while: { $0.isNumber })) else {
                FileHandle.standardError.write(Data("ziggy shell: invalid -geometry argument: \(argument)\n".utf8))
                exit(1)
            }
            return CGSize(width: width, height: height)
        }
        return CGSize(width: 900, height: 800)
    }
}
