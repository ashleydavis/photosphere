import UIKit
import Capacitor

//
// Capacitor bridge view controller for the iOS app. In test mode it injects the host control
// bridge address into the WebView as globalThis.__PHOTOSPHERE_TEST__, read from the
// PHOTOSPHERE_TEST_* environment variables (passed via SIMCTL_CHILD_* on simulator launch).
// The frontend reads the global to open its test-driver WebSocket. Injection is retried at a
// few delays because the page may still be loading; the frontend also polls for the global,
// so a late injection is still picked up.
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
    private func injectTestConfig() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PHOTOSPHERE_TEST_MODE"] == "1" else {
            return
        }
        let host = environment["PHOTOSPHERE_TEST_HOST"] ?? "localhost"
        let port = environment["PHOTOSPHERE_TEST_PORT"] ?? "0"
        let script = "globalThis.__PHOTOSPHERE_TEST__ = { host: '\(host)', port: \(port) };"
        let delays: [Double] = [0.2, 0.6, 1.2, 2.5]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.webView?.evaluateJavaScript(script, completionHandler: nil)
            }
        }
    }
}
