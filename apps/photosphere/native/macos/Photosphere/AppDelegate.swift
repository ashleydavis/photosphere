//
// Photosphere's MacOS native app: a window and Ziggy's web view in the window. Everything else is
// in ZiggyNativeMacOS.
//

import AppKit
import ZiggyNativeMacOS

// Owns the window and Ziggy's bridge for the life of the application.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // The window, once the application has launched.
    private var window: NSWindow?

    // Ziggy's bridge, once the application has launched.
    private var bridge: ZiggyBridge?

    // Creates the window and starts Ziggy, which draws the main menu.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let (size, position) = AppDelegate.windowGeometry()

        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let newWindow = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        newWindow.title = "Photosphere"
        newWindow.isReleasedWhenClosed = false
        // Lets toggle-fullscreen take the window full screen.
        newWindow.collectionBehavior.insert(.fullScreenPrimary)
        let newBridge = ZiggyBridge(frame: frame)
        newWindow.contentView = newBridge.view
        if let position = position, let screen = NSScreen.main {
            // The position is of the window's content, measured from the top left of the main screen, so a recording of exactly
            // that area shows the app and none of the title bar.
            let content = NSRect(x: position.x, y: screen.frame.maxY - position.y - size.height, width: size.width, height: size.height)
            newWindow.setFrame(newWindow.frameRect(forContentRect: content), display: false)
        }
        else {
            newWindow.center()
        }
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

    // The window's content size and, when given, the position of its top left corner from the top left of the main screen: the
    // WxH or WxH+X+Y text of a -geometry=... argument when there is one, otherwise 900 by 800 in the middle of the screen.
    private static func windowGeometry() -> (CGSize, CGPoint?) {
        for argument in CommandLine.arguments {
            guard argument.hasPrefix("-geometry=") else {
                continue
            }
            let text = argument.dropFirst("-geometry=".count)
            let sizeAndPosition = text.split(separator: "+", omittingEmptySubsequences: false)
            let parts = sizeAndPosition[0].split(separator: "x", maxSplits: 1)
            guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
                sizeAndPosition.count == 1 || sizeAndPosition.count == 3 else {
                FileHandle.standardError.write(Data("ziggy native app: invalid -geometry argument: \(argument)\n".utf8))
                exit(1)
            }
            if sizeAndPosition.count == 1 {
                return (CGSize(width: width, height: height), nil)
            }
            guard let x = Double(sizeAndPosition[1]), let y = Double(sizeAndPosition[2]) else {
                FileHandle.standardError.write(Data("ziggy native app: invalid -geometry argument: \(argument)\n".utf8))
                exit(1)
            }
            return (CGSize(width: width, height: height), CGPoint(x: x, y: y))
        }
        return (CGSize(width: 900, height: 800), nil)
    }
}
