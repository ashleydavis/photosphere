//
// Photosphere's one iOS screen: Ziggy's web view fills it.
//

import UIKit
import ZiggyShellIOS

// Hosts Ziggy's web view as its whole view.
final class ViewController: UIViewController {
    // Ziggy's bridge, once the view has loaded.
    private(set) var bridge: ZiggyBridge?

    // The background processing tasks, told when the core's background loops start and stop.
    private let backgroundPasses: BackgroundPasses

    init(backgroundPasses: BackgroundPasses) {
        self.backgroundPasses = backgroundPasses
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("ViewController is made in code")
    }

    // Makes the web view the controller's view, and gives the bridge what answers the core's host requests.
    override func loadView() {
        let newBridge = ZiggyBridge(frame: UIScreen.main.bounds)
        bridge = newBridge

        let exportRequests = ExportHostRequests(storageRoot: newBridge.dataDirectory, presenter: { [weak self] in
            self
        })
        do {
            try exportRequests.sweep()
        }
        catch {
            fatalError("could not remove the export temp files an earlier run left: \(error)")
        }
        let mediaLibraryRequests = MediaLibraryHostRequests(exportRoot: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        newBridge.setHostRequestHandler(PhotosphereHostRequests(otherHandlers: [
            "exportFile": exportRequests,
            "exportFiles": exportRequests,
            "exportTempFolder": exportRequests,
            "mediaLibraryList": mediaLibraryRequests,
            "mediaLibraryAlbums": mediaLibraryRequests,
            "mediaLibraryOpen": mediaLibraryRequests,
            "mediaLibraryClose": mediaLibraryRequests,
            "mediaLibraryDelete": mediaLibraryRequests,
        ]))
        newBridge.keepRunningChanged = { [weak self] keepRunning in
            self?.backgroundPasses.loopsRunningChanged(keepRunning)
        }
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
