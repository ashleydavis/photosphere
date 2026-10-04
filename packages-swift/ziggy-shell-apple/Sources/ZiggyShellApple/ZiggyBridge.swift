//
// Ziggy's shell for MacOS and iOS. It owns the WKWebView, injects window.ziggy, loads the app's bundled page, calls the
// core through the C interface and moves messages between the page and the core.
//
// Messages from the core arrive on any thread, so each is copied and handed to the main queue, which delivers them to the
// page in the order they were handed over.
//

import Foundation
import WebKit
import CZiggy

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Hosts one web view and one Ziggy core for the app. The app creates it, puts webView on screen, calls start, and calls
// shutdown when the app is ending.
public final class ZiggyBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    // The web view that shows the app's page. The app puts it on screen.
    public let webView: WKWebView

    // The core's handle, from start until shutdown.
    private var core: UnsafeMutableRawPointer?

    // Set by shutdown. Read and written on the main thread only, so nothing is delivered to the page after it is set.
    private var destroyed: Bool

    // The directory in the app bundle that holds the bundled page, with index.html in it.
    private let uiDirectory: URL

    // The app's private data directory, which the core is given.
    private let dataDirectory: URL

    // Whether a test hooks build was started in test mode.
    private let testMode: Bool

    #if os(macOS)
    // The main menu, once the core exists. This holds it because a menu item's target is not retained.
    private var menu: ZiggyMenu?
    #endif

    // The name of the script message handler that the injected script posts through.
    private static let handlerName = "ziggy"

    // The name the os_version callback gives the operating system.
    #if os(macOS)
    private static let operatingSystemName = "macOS"
    #else
    private static let operatingSystemName = "iOS"
    #endif

    // Creates the web view with the injected script and the message handler. The page is not loaded and the core does not
    // exist until start. The page lives in the "ui" directory of the app's resources, and the injected script is the
    // app's "ziggy-inject.js" resource.
    public init(frame: CGRect) {
        let bundle = Bundle.main
        guard let bundleIdentifier = bundle.bundleIdentifier else {
            ZiggyBridge.fail("the app has no bundle identifier")
        }
        guard let resourceURL = bundle.resourceURL else {
            ZiggyBridge.fail("the app has no resources directory")
        }
        guard let scriptURL = bundle.url(forResource: "ziggy-inject", withExtension: "js") else {
            ZiggyBridge.fail("the app has no ziggy-inject.js resource")
        }
        let injectScript: String
        do {
            injectScript = try String(contentsOf: scriptURL, encoding: .utf8)
        }
        catch {
            ZiggyBridge.fail("could not read \(scriptURL.path): \(error)")
        }

        self.uiDirectory = resourceURL.appendingPathComponent("ui", isDirectory: true)

        let supportDirectory: URL
        do {
            supportDirectory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        catch {
            ZiggyBridge.fail("could not find the Application Support directory: \(error)")
        }
        let dataDirectory = supportDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        }
        catch {
            ZiggyBridge.fail("could not create \(dataDirectory.path): \(error)")
        }
        self.dataDirectory = dataDirectory

        self.testMode = ziggy_test_hooks_enabled() && ProcessInfo.processInfo.environment["ZIGGY_TEST_MODE"] != nil
        self.core = nil
        self.destroyed = false

        let configuration = WKWebViewConfiguration()
        let userScript = WKUserScript(source: injectScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(userScript)
        #if os(macOS)
        // Turns on the web inspector, and with it Inspect Element in the context menu. This key is not in the public API but
        // is how every WKWebView app on these SDKs does it. It is on in release builds too.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        self.webView = WKWebView(frame: frame, configuration: configuration)
        #if os(macOS) && swift(>=5.8)
        // The public switch for the same thing, which exists from macOS 13.3. It is compiled only by a toolchain whose SDK
        // has it, because Xcode 14.2's SDK does not.
        if #available(macOS 13.3, *) {
            self.webView.isInspectable = true
        }
        #endif

        super.init()

        configuration.userContentController.add(self, name: ZiggyBridge.handlerName)
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
    }

    // Creates the core and loads the app's page.
    public func start() {
        if core != nil || destroyed {
            ZiggyBridge.fail("start was called more than once")
        }
        let environment = ProcessInfo.processInfo.environment

        var config = ziggy_config()
        config.user_data = Unmanaged.passUnretained(self).toOpaque()
        config.deliver = { userData, message, messageLength in
            guard let userData = userData, let message = message else {
                ZiggyBridge.fail("the core delivered a message with no text")
            }
            let bridge = Unmanaged<ZiggyBridge>.fromOpaque(userData).takeUnretainedValue()
            // The bytes are valid only during this call, so they are copied into a string before it returns.
            let bytes = UnsafeBufferPointer(start: UnsafeRawPointer(message).assumingMemoryBound(to: UInt8.self), count: messageLength)
            let text = String(decoding: bytes, as: UTF8.self)
            DispatchQueue.main.async {
                bridge.deliverToPage(text)
            }
        }
        config.os_version = { userData, buffer, capacity in
            guard let buffer = buffer else {
                return -1
            }
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let text = "\"\(ZiggyBridge.operatingSystemName) \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)\""
            let bytes = Array(text.utf8)
            if bytes.count > capacity {
                return -1
            }
            memcpy(buffer, bytes, bytes.count)
            return bytes.count
        }
        config.quit = { userData in
            guard let userData = userData else {
                ZiggyBridge.fail("the core asked to quit with no bridge")
            }
            let bridge = Unmanaged<ZiggyBridge>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                bridge.quit()
            }
        }
        config.pick_paths = { userData, kind, title, initialName, buffer, capacity in
            guard let userData = userData, let buffer = buffer else {
                ZiggyBridge.fail("the core asked for a picker with no bridge or no buffer")
            }
            let bridge = Unmanaged<ZiggyBridge>.fromOpaque(userData).takeUnretainedValue()
            return ZiggyPicker.pickPaths(
                webView: bridge.webView,
                kind: kind,
                title: title.map { String(cString: $0) },
                initialName: initialName.map { String(cString: $0) },
                buffer: buffer,
                capacity: capacity
            )
        }
        #if os(macOS)
        config.menu_action = { userData, action in
            guard let userData = userData, let action = action else {
                ZiggyBridge.fail("the core chose a menu action with no bridge or no action")
            }
            let bridge = Unmanaged<ZiggyBridge>.fromOpaque(userData).takeUnretainedValue()
            // Copied before the hop, because the core's text is valid only during this call.
            let text = String(cString: action)
            DispatchQueue.main.async {
                guard let menu = bridge.menu else {
                    ZiggyBridge.fail("the core chose the menu action \(text) before there was a menu")
                }
                menu.perform(action: text)
            }
        }
        config.worker_threads = UInt32(ProcessInfo.processInfo.activeProcessorCount)
        config.max_concurrent_child_tasks = 10
        #else
        config.worker_threads = 5
        config.max_concurrent_child_tasks = 2
        #endif

        let appUrlPrefix = uiDirectory.absoluteString
        if !appUrlPrefix.hasSuffix("/") {
            ZiggyBridge.fail("the page directory address does not end in a slash: \(appUrlPrefix)")
        }
        let prefixText = ZiggyBridge.duplicate(appUrlPrefix)
        let dataText = ZiggyBridge.duplicate(dataDirectory.path)
        var portFileText: UnsafeMutablePointer<CChar>? = nil
        defer {
            free(prefixText)
            free(dataText)
            free(portFileText)
        }
        config.app_url_prefix = UnsafePointer(prefixText)
        config.data_dir = UnsafePointer(dataText)
        if testMode {
            config.test_mode = true
            if let portFile = environment["ZIGGY_TEST_PORT_FILE"] {
                portFileText = ZiggyBridge.duplicate(portFile)
                config.test_port_file = UnsafePointer(portFileText)
            }
        }
        guard let created = ziggy_create(&config) else {
            ZiggyBridge.fail("ziggy_create failed")
        }
        core = created

        #if os(macOS)
        var menuLength = 0
        guard let menuText = ziggy_menu_json(created, &menuLength) else {
            ZiggyBridge.fail("the core has no menu text")
        }
        menu = ZiggyMenu(bridge: self, menuJSON: Data(bytes: menuText, count: menuLength))
        #endif

        var components = URLComponents(url: uiDirectory.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)
        if testMode {
            components?.query = "testMode=1"
        }
        guard let pageURL = components?.url else {
            ZiggyBridge.fail("could not build the page address")
        }
        webView.loadFileURL(pageURL, allowingReadAccessTo: uiDirectory)
    }

    // Destroys the core once. After it returns the core runs nothing and nothing more is delivered to the page.
    public func shutdown() {
        guard let handle = core else {
            return
        }
        destroyed = true
        core = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ZiggyBridge.handlerName)
        ziggy_destroy(handle)
    }

    // Ends the app. Only the core's test control connection asks for this.
    private func quit() {
        #if os(macOS)
        NSApplication.shared.terminate(nil)
        #else
        // iOS has no way to quit an app, so the process ends once the core is destroyed.
        shutdown()
        exit(0)
        #endif
    }

    // Runs on the main thread: sends one message from the core to the page.
    private func deliverToPage(_ text: String) {
        // A message queued before shutdown is dropped here, because shutdown promises nothing is delivered after it.
        if destroyed {
            return
        }
        webView.evaluateJavaScript("window.__ziggyReceive(\(text));") { _, error in
            if let error = error {
                ZiggyBridge.report("delivering a message to the page failed: \(error)")
            }
        }
    }

    // A message from the page: hands it to the core.
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else {
            ZiggyBridge.fail("the page posted a message that is not a string")
        }
        post(text)
    }

    // Gives the core a JSON message, as if the page had posted it.
    func post(_ text: String) {
        // The page can still post while the app is ending. The core is gone by then, so there is nobody to give it to.
        guard let handle = core else {
            return
        }
        text.withCString { pointer in
            ziggy_post_message(handle, pointer, text.utf8.count)
        }
    }

    // Tells the core that an app-owned menu item was chosen, as the menu-action message the page's own code also gets.
    func postMenuAction(_ action: String) {
        let message: [String: Any] = [
            "channel": "menu-action",
            "data": [
                "action": action,
            ],
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        }
        catch {
            ZiggyBridge.fail("could not write the menu-action message: \(error)")
        }
        post(String(decoding: data, as: UTF8.self))
    }

    // Decides every navigation with the core's origin check.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if shouldLoad(navigationAction.request.url, isNewWindow: false) {
            decisionHandler(.allow)
        }
        else {
            decisionHandler(.cancel)
        }
    }

    // Decides window.open and target="_blank" with the same check. No new window is ever created.
    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        _ = shouldLoad(navigationAction.request.url, isNewWindow: true)
        return nil
    }

    // Reports a page that failed to load.
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        ZiggyBridge.report("the page failed to load: \(error)")
    }

    // Reports a page that failed part way through loading.
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        ZiggyBridge.report("the page failed while loading: \(error)")
    }

    // The web content process dying leaves a blank page that nothing can recover, so the app stops.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ZiggyBridge.fail("the web content process terminated")
    }

    // Asks the core what to do with an address. An external link is opened in the system browser here. Returns true when
    // the web view may load the address, which is only for the app's own page in an existing frame.
    private func shouldLoad(_ url: URL?, isNewWindow: Bool) -> Bool {
        guard let handle = core else {
            return false
        }
        guard let url = url else {
            ZiggyBridge.report("blocked a navigation with no address")
            return false
        }
        let text = url.absoluteString
        let verdict = text.withCString { pointer in
            ziggy_check_url(handle, pointer, text.utf8.count)
        }
        if Int(verdict) == Int(ZIGGY_URL_ALLOW) {
            return !isNewWindow
        }
        if Int(verdict) == Int(ZIGGY_URL_OPEN_EXTERNALLY) {
            openExternally(url)
            return false
        }
        ZiggyBridge.report("blocked a navigation to \(text)")
        return false
    }

    // Opens an address in the system browser.
    private func openExternally(_ url: URL) {
        #if os(macOS)
        if !NSWorkspace.shared.open(url) {
            ZiggyBridge.report("could not open \(url.absoluteString) in the system browser")
        }
        #else
        UIApplication.shared.open(url, options: [:]) { success in
            if !success {
                ZiggyBridge.report("could not open \(url.absoluteString) in the system browser")
            }
        }
        #endif
    }

    // Copies text into a new NUL terminated C string, which the caller frees.
    private static func duplicate(_ text: String) -> UnsafeMutablePointer<CChar> {
        guard let copy = strdup(text) else {
            ZiggyBridge.fail("out of memory")
        }
        return copy
    }

    // Writes a problem to standard error and carries on.
    static func report(_ message: String) {
        FileHandle.standardError.write(Data("ziggy shell: \(message)\n".utf8))
    }

    // Writes a problem to standard error and stops the app.
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ziggy shell: \(message)\n".utf8))
        exit(1)
    }
}
