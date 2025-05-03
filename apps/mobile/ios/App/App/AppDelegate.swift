import UIKit
import Capacitor
import BackgroundTasks

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
  
  var window: UIWindow?
  
  let backgroundTaskId = "com.photosphere.codecapers:scan-files"

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    //
    // Clears storage on start:
    //
    //MediaUploader.instance.clearStorage()

    //
    // https://stackoverflow.com/a/68736333
    // https://stackoverflow.com/a/58101161
    // https://stackoverflow.com/a/61929751
    // https://developer.apple.com/documentation/backgroundtasks
    // https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler
    // https://stackoverflow.com/a/61480850
    // https://www.andyibanez.com/posts/modern-background-tasks-ios13/
    BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskId, using: nil) { task in
      
      //
      // This might only be allowed to run for 5 minutes!
      // Will it then run again later?
      //
      // https://stackoverflow.com/a/69532232
      //
      // TODO: I need to restructure the scanning code so that it can pickup where it left.
      //
      
      print("! Running background task")
      
      //
      // To run/debug this background task:
      //
      // - set a breakpoint after submitting the background task
      // - hit the breakpoint
      // - enter into the debugger:
      //     e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.ash.capacitor-file-scanning-prototype"]
      // - resume the debugger and the task should kick off.
      //
      // https://developer.apple.com/documentation/backgroundtasks/starting_and_terminating_tasks_during_development
      //

      // https://itnext.io/swift-ios-13-backgroundtasks-framework-background-app-refresh-in-4-steps-3da32e65bc3d
      task.expirationHandler = {
        print("! Task expired")
        task.setTaskCompleted(success: false) // This should reschdule the task.
      }
      
      Task {
        do {
          try await MediaUploader.instance.scanMedia();
          print("! Task completed")
          task.setTaskCompleted(success: true)
        }
        catch {
          print("! scanMedia failed with error: \(error)")
          task.setTaskCompleted(success: false) // This should reschedule the task.
        }
      }
    }
    
    // Uncomment this to debug background processing.
//    submitBackgroundProcessing()
    
    return true
  }
  
  func applicationWillResignActive(_ application: UIApplication) {
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
  }
  
  func applicationDidEnterBackground(_ application: UIApplication) {
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    
    print("App to background")
    
  }
  
  private func submitBackgroundProcessing() {
    let request = BGProcessingTaskRequest(identifier: backgroundTaskId)
    //TODO: Allow use to configure these options.
    // request.requiresExternalPower = true
    // request.requiresNetworkConnectivity = true
    do {
      try BGTaskScheduler.shared.submit(request)
    }
    catch {
      print(error)
    }

    print("Submitted task")

  }
  
  func applicationWillEnterForeground(_ application: UIApplication) {
    // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    print("App to foreground")
    
    //todo: if the task it not already running maybe start it?
      // record in settings if the task should already be running.
  }
  
  func applicationDidBecomeActive(_ application: UIApplication) {
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
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
