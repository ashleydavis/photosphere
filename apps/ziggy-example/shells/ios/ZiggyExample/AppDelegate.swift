//
// The Ziggy example's iOS shell: the application delegate, which owns the window and the one view controller. Everything
// else is in ZiggyShellApple.
//

import UIKit

// Owns the window for the life of the application.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    // The window, once the application has launched.
    var window: UIWindow?

    // The view controller that hosts Ziggy's web view, once the application has launched.
    private var viewController: ViewController?

    // Creates the window and its view controller.
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let newWindow = UIWindow(frame: UIScreen.main.bounds)
        let newViewController = ViewController()
        newWindow.rootViewController = newViewController
        newWindow.makeKeyAndVisible()
        window = newWindow
        viewController = newViewController
        return true
    }

    // Destroys the core before the process ends.
    func applicationWillTerminate(_ application: UIApplication) {
        viewController?.bridge?.shutdown()
    }
}
