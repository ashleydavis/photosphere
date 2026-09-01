import UIKit
import Capacitor
import BackgroundTasks

//
// The identifier of the background processing task that lets automatic import catch up while the app
// is not on screen.
//
// It must match the entry in Info.plist's BGTaskSchedulerPermittedIdentifiers: the system refuses to
// register a handler for an identifier the app has not declared, and refuses at launch, so a
// mismatch crashes the app rather than quietly doing nothing.
//
let autoImportBackgroundTaskIdentifier = "au.com.codecapers.photosphere.auto-import"

//
// The identifier of the background processing task that lets syncing catch up while the app is not on
// screen.
//
// Its own task rather than a second thing the import's task does, because the two are separately
// useful: a phone with nothing new to import may still have edits to push, and a phone with no origin
// has photos to import and nothing to sync. It must match the entry in Info.plist's
// BGTaskSchedulerPermittedIdentifiers for the same reason the import's must.
//
let backgroundSyncBackgroundTaskIdentifier = "au.com.codecapers.photosphere.background-sync"

//
// The earliest the system is asked to run the next background pass, in seconds.
//
// A request, not a schedule. iOS runs a processing task when it decides to, typically while the phone
// is charging and idle, and may not run one for a long time. That is the platform, not a setting: a
// phone in a pocket all day may import nothing until the app is opened.
//
private let autoImportBackgroundTaskEarliestDelay: TimeInterval = 15 * 60

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // The handler has to be registered before the app finishes launching, whether or not automatic
        // import is switched on: registration is not the same as scheduling, and the system will not
        // accept one afterwards. Nothing is scheduled here, so a phone that never switches automatic
        // import on never asks the system for anything.
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: autoImportBackgroundTaskIdentifier, using: nil) { task in
                AppDelegate.runAutoImportBackgroundTask(task)
            }
            BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundSyncBackgroundTaskIdentifier, using: nil) { task in
                AppDelegate.runBackgroundSyncTask(task)
            }
        }

        return true
    }

    //
    // Runs exactly one automatic import pass on behalf of the system, and asks for the next one.
    //
    // One pass, because the system decides when this runs and how long it may take: a handler that
    // tried to loop would be killed part way through. The expiration handler stops the driver, which
    // cancels the import through the same path switching automatic import off uses.
    //
    @available(iOS 13.0, *)
    private static func runAutoImportBackgroundTask(_ task: BGTask) {
        // Asked for before the work starts, not after: a handler killed on expiry never reaches the
        // end, and without this there would be no next request and the background import would stop
        // for good.
        scheduleAutoImportBackgroundTask()

        task.expirationHandler = {
            JsEnginePlugin.stopAutoImport()
        }

        DispatchQueue.global(qos: .background).async {
            let keepRunning = JsEnginePlugin.runOneBackgroundImportPass()

            if !keepRunning {
                // Automatic import has been switched off, so the request made above is withdrawn.
                // Switching it off has to leave nothing behind, and a background request the system is
                // still holding is something behind.
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: autoImportBackgroundTaskIdentifier)
            }

            task.setTaskCompleted(success: true)
        }
    }

    //
    // Asks the system to run a background pass when it next sees fit.
    //
    @available(iOS 13.0, *)
    static func scheduleAutoImportBackgroundTask() {
        let request = BGProcessingTaskRequest(identifier: autoImportBackgroundTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: autoImportBackgroundTaskEarliestDelay)

        do {
            try BGTaskScheduler.shared.submit(request)
        }
        catch {
            print("[AutoImport] Could not ask for a background pass: \(error)")
        }
    }

    //
    // Runs exactly one background sync pass on behalf of the system, and asks for the next one.
    //
    // One pass, because the system decides when this runs and how long it may take: a handler that
    // tried to loop would be killed part way through. The expiration handler stops the driver, which
    // cancels the sync through the same path switching syncing off uses.
    //
    // Unlike the import's, this never withdraws its own request. A pass that syncs nothing is the
    // ordinary case (nothing changed, no Wi-Fi, syncing switched off for now), and every one of those
    // reasons can be gone by the next pass. The request is withdrawn when automatic import is switched
    // off, which is what takes the whole background feature away.
    //
    @available(iOS 13.0, *)
    private static func runBackgroundSyncTask(_ task: BGTask) {
        // Asked for before the work starts, not after: a handler killed on expiry never reaches the
        // end, and without this there would be no next request and background syncing would stop for
        // good.
        scheduleBackgroundSyncTask()

        task.expirationHandler = {
            JsEnginePlugin.stopSync()
        }

        DispatchQueue.global(qos: .background).async {
            JsEnginePlugin.runOneBackgroundSyncPass()
            task.setTaskCompleted(success: true)
        }
    }

    //
    // Asks the system to run a background sync pass when it next sees fit.
    //
    @available(iOS 13.0, *)
    static func scheduleBackgroundSyncTask() {
        let request = BGProcessingTaskRequest(identifier: backgroundSyncBackgroundTaskIdentifier)

        // Unlike the import's request, this one asks for a network. A sync with no network reaches
        // the origin's state file and stops, which is a pass that cost a wake-up and did nothing.
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: autoImportBackgroundTaskEarliestDelay)

        do {
            try BGTaskScheduler.shared.submit(request)
        }
        catch {
            print("[BackgroundSync] Could not ask for a background pass: \(error)")
        }
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // The foreground loop stops as the app leaves the screen, and the system is asked for a
        // background pass instead. A pass already in flight is left to finish or to be cancelled by
        // expiry, rather than raced against a second one: the driver's single entry point is what
        // makes that impossible rather than merely unlikely.
        JsEnginePlugin.stopForegroundAutoImport()
        JsEnginePlugin.stopForegroundSync()

        // Only when the user has switched automatic import on. A phone that has not asks the system
        // for nothing.
        if #available(iOS 13.0, *), JsEnginePlugin.autoImportOptedIn {
            AppDelegate.scheduleAutoImportBackgroundTask()
            AppDelegate.scheduleBackgroundSyncTask()
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // The WebView starts the foreground loop when it finds automatic import switched on, and this
        // starts it again when the app comes back to the screen without the WebView being rebuilt.
        // Only when the user has switched it on: nothing about the background import exists before
        // that. Starting a loop that is already running does nothing.
        if JsEnginePlugin.autoImportOptedIn {
            JsEnginePlugin.startForegroundAutoImport()
            JsEnginePlugin.startForegroundSync()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

}
