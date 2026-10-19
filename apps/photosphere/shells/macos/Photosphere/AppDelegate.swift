//
// Photosphere's MacOS shell: a window and Ziggy's web view in the window. Everything else is
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

    // Answers the requests the core's background work makes of the platform.
    private let hostRequests = PhotosphereHostRequests()

    // Creates the window and starts Ziggy, which draws the main menu.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = AppDelegate.windowSize()

        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let newWindow = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        newWindow.title = "Photosphere"
        newWindow.isReleasedWhenClosed = false
        // Lets toggle-fullscreen take the window full screen.
        newWindow.collectionBehavior.insert(.fullScreenPrimary)
        let newBridge = ZiggyBridge(frame: frame)
        newBridge.setHostRequestHandler(hostRequests)
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

// Answers the requests the core's background work makes of the platform: the connection type, and a notification permission a desktop
// has no need to ask for, so that is always granted. The computer is held from sleeping while a pass runs, and what the work reports goes
// to standard error, which is the app's log. The core calls from a worker thread and waits for the answer.
final class PhotosphereHostRequests: ZiggyHostRequestHandler {
    // Guards awakeHolds and awakeActivity, because the core's worker threads call in at the same time.
    private let awakeLock = NSLock()

    // How many holds on the computer staying awake are in place.
    private var awakeHolds = 0

    // The activity that keeps the computer from idle sleep, while there is a hold.
    private var awakeActivity: NSObjectProtocol?

    func handle(method: String, requestJson: String) throws -> String {
        switch method {
        case "requestNotificationPermission":
            return "{\"granted\":true}"
        case "networkConnectionType":
            // A desktop cannot tell Wi-Fi from a wired or a metered connection, which is what the page's own network status says too.
            return "\"unknown\""
        case "holdAwake":
            let request = try PhotosphereHostRequests.object(from: requestJson, method: method)
            guard let awake = request["awake"] as? Bool else {
                throw ZiggyHostRequestError("The request \(method) was not understood: \"awake\" is missing or is not true or false.")
            }
            try holdAwake(awake)
            return "null"
        case "backgroundLog":
            let request = try PhotosphereHostRequests.object(from: requestJson, method: method)
            guard let message = request["message"] as? String else {
                throw ZiggyHostRequestError("The request \(method) was not understood: \"message\" is missing or is not text.")
            }
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            return "null"
        default:
            throw ZiggyHostRequestError("The Photosphere MacOS app cannot do \"\(method)\".")
        }
    }

    // Takes or lets go of one hold on the computer staying awake. The first hold stops idle sleep and letting go of the last allows it again.
    private func holdAwake(_ awake: Bool) throws {
        awakeLock.lock()
        defer {
            awakeLock.unlock()
        }
        if awake {
            awakeHolds += 1
            if awakeHolds == 1 {
                awakeActivity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Photosphere is working in the background")
            }
            return
        }
        if awakeHolds == 0 {
            throw ZiggyHostRequestError("A hold on the computer staying awake was let go that was never taken.")
        }
        awakeHolds -= 1
        if awakeHolds == 0, let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
    }

    // Reads the JSON object a request carries.
    private static func object(from requestJson: String, method: String) throws -> [String: Any] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(requestJson.utf8))
        }
        catch {
            throw ZiggyHostRequestError("The request \(method) was not understood: \(error)")
        }
        guard let object = parsed as? [String: Any] else {
            throw ZiggyHostRequestError("The request \(method) was not understood: it is not a JSON object.")
        }
        return object
    }
}
