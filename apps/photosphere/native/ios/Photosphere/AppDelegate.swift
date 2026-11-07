//
// Photosphere's iOS native app: the application delegate, which owns the window and the one view controller. Everything else
// generic is in ZiggyNativeIOS.
//

import UIKit
import ZiggyNativeIOS

// Owns the window for the life of the application.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    // The window, once the application has launched.
    var window: UIWindow?

    // The view controller that hosts Ziggy's web view, once the application has launched.
    private var viewController: ViewController?

    // The background processing tasks. They find the bridge through the view controller.
    private lazy var backgroundPasses = BackgroundPasses(bridge: { [weak self] in
        self?.viewController?.bridge
    })

    // Creates the window and its view controller.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // The handlers have to be registered before the application finishes launching.
        backgroundPasses.register()

        let newWindow = UIWindow(frame: UIScreen.main.bounds)
        let newViewController = ViewController(backgroundPasses: backgroundPasses)
        newWindow.rootViewController = newViewController
        newWindow.makeKeyAndVisible()
        window = newWindow
        viewController = newViewController
        return true
    }

    // The loops stop being run by the app as it leaves the screen, and the system is asked for a background pass instead.
    func applicationWillResignActive(_ application: UIApplication) {
        backgroundPasses.willResignActive()
    }

    // The loops a background pass cancelled are started again.
    func applicationDidBecomeActive(_ application: UIApplication) {
        backgroundPasses.didBecomeActive()
    }

    // Destroys the core before the process ends.
    func applicationWillTerminate(_ application: UIApplication) {
        viewController?.bridge?.shutdown()
    }
}
