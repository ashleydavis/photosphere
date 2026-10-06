//
// The Ziggy example's one iOS screen: Ziggy's web view fills it.
//

import UIKit
import ZiggyShellIOS

// Hosts Ziggy's web view as its whole view.
final class ViewController: UIViewController {
    // Ziggy's bridge, once the view has loaded.
    private(set) var bridge: ZiggyBridge?

    // Makes the web view the controller's view.
    override func loadView() {
        let newBridge = ZiggyBridge(frame: UIScreen.main.bounds)
        bridge = newBridge
        view = newBridge.webView
    }

    // Starts Ziggy once the web view is the controller's view.
    override func viewDidLoad() {
        super.viewDidLoad()
        guard let bridge = bridge else {
            fatalError("the view loaded without a bridge")
        }
        bridge.start()
    }
}
