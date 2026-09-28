import UIKit
import WebKit
import Capacitor

//
// Capacitor bridge view controller for the iOS app. In test mode it injects the host control
// bridge address into the WebView as globalThis.__PHOTOSPHERE_TEST__, read from the
// PHOTOSPHERE_TEST_* environment variables (passed via SIMCTL_CHILD_* on simulator launch).
// The frontend reads the global to open its test-driver WebSocket.
//
class MainViewController: CAPBridgeViewController {

    //
    // Called once Capacitor has finished setting up the bridge. Triggers the test-config
    // injection.
    //
    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        injectTestConfig()
    }

    //
    // Injects globalThis.__PHOTOSPHERE_TEST__ into the WebView when launched in test mode.
    //
    // The global is registered as a user script that WebKit runs at the start of every document,
    // before any of the page's own scripts, which is how Capacitor injects its own globals. It used
    // to be set with evaluateJavaScript at fixed delays (0.2s to 2.5s) after this call, but this is
    // called from loadView, before viewDidLoad starts loading the page. On a cold, busy simulator the
    // page had not loaded by the last delay, so every injection landed on the empty document that
    // the page load then replaced, the global never existed in the page, and the app never connected
    // to the control bridge (ios-smoke-tests in Release run 36373793283 lost test 0 to two 120s
    // launches with an empty app.log).
    //
    private func injectTestConfig() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PHOTOSPHERE_TEST_MODE"] == "1" else {
            return
        }
        let host = environment["PHOTOSPHERE_TEST_HOST"] ?? "localhost"
        let port = environment["PHOTOSPHERE_TEST_PORT"] ?? "0"
        let script = "globalThis.__PHOTOSPHERE_TEST__ = { host: '\(host)', port: \(port) };"
        let userScript = WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        webView?.configuration.userContentController.addUserScript(userScript)
    }
}
