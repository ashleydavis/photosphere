//
// The background processing tasks that let the automatic import, the sync and the prefetch of a partial replica catch up while the app
// is not on screen. iOS decides when a processing task runs, usually while the phone is charging and idle, and may not run one for a
// long time: that is the platform, not a setting.
//
// Each of the three has a task of its own, because they are separately useful: a phone with nothing new to import may still have edits
// to push, and a phone with no origin has photos to import and nothing to sync. The identifiers must match the entries in Info.plist's
// BGTaskSchedulerPermittedIdentifiers: the system refuses to register a handler for an identifier the app has not declared, and refuses
// at launch, so a mismatch crashes the app rather than quietly doing nothing.
//
// The loops themselves are the core's. When the system runs a task, this asks the core to start its background work, as the page's
// startBackgroundImport request does (starting loops that are running does nothing), and when the system's time for the task is up it
// cancels the loop that task stands for, through the same cancel-tasks message the page uses.
//

import BackgroundTasks
import Foundation
import UIKit
import ZiggyNativeIOS

// One of the background processing tasks.
private struct BackgroundPass {
    // The identifier the task is registered and scheduled under.
    let identifier: String

    // The source the core runs the matching loop and the tasks it starts under, so one cancellation stops the loop and the pass it is in.
    let source: String

    // Whether the task needs a network. The import's does not. A sync with no network reaches the origin's state file and stops, and a
    // prefetch gets every byte from the origin, so those are wake-ups that can do nothing without one.
    let requiresNetwork: Bool
}

// One run of a processing task, which is completed once however many times it is asked to be.
private final class BackgroundPassRun {
    // The system's task.
    private let task: BGTask

    // Guards finished.
    private let lock = NSLock()

    // Whether the system has been told the task is over.
    private var finished = false

    init(task: BGTask) {
        self.task = task
    }

    // Tells the system the task is over, the first time it is called.
    func complete(success: Bool) {
        lock.lock()
        defer {
            lock.unlock()
        }
        if finished {
            return
        }
        finished = true
        task.setTaskCompleted(success: success)
    }
}

// Registers, schedules and runs the background processing tasks.
final class BackgroundPasses {
    // The earliest the system is asked to run the next background pass, in seconds. A request, not a schedule.
    private static let earliestDelay: TimeInterval = 15 * 60

    // The three tasks.
    private let passes = [
        BackgroundPass(identifier: "au.com.codecapers.photosphere.auto-import", source: "auto-import", requiresNetwork: false),
        BackgroundPass(identifier: "au.com.codecapers.photosphere.background-sync", source: "background-sync", requiresNetwork: true),
        BackgroundPass(identifier: "au.com.codecapers.photosphere.background-prefetch", source: "background-prefetch", requiresNetwork: true),
    ]

    // Finds the bridge to the core. It is asked each time, because the tasks are registered before the screen that owns the bridge exists.
    private let bridge: () -> ZiggyBridge?

    // Whether the core's background loops are running, as the core last said. Read and written on the main thread only.
    private var loopsRunning = false

    // Whether the loops have to be started again when the app comes back to the screen, because the app went to the background with
    // them running or the system ran them while it was there. Read and written on the main thread only.
    private var startOnActivation = false

    init(bridge: @escaping () -> ZiggyBridge?) {
        self.bridge = bridge
    }

    // Registers the handlers. The system accepts them only before the app finishes launching, whether or not automatic import is
    // switched on: registration is not scheduling. Nothing is scheduled here, so a phone that never switches automatic import on never
    // asks the system for anything.
    func register() {
        for pass in passes {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: pass.identifier, using: nil) { task in
                self.run(pass, task: task)
            }
            if !registered {
                BackgroundPasses.fail("could not register the background task \(pass.identifier)")
            }
        }
    }

    // The core says the background loops are running or no longer are. Called on the main thread.
    func loopsRunningChanged(_ running: Bool) {
        loopsRunning = running
        // A loop that stops while the app is on screen was switched off by the user, so the passes the system is holding requests for
        // are withdrawn: switching it off has to leave nothing behind. A loop that stops in the background was cancelled by a pass
        // running out of time, and its request stays.
        if !running && UIApplication.shared.applicationState == .active {
            BGTaskScheduler.shared.cancelAllTaskRequests()
            startOnActivation = false
        }
    }

    // The app is leaving the screen: the system is asked for a background pass instead of the loops carrying on. Only when the loops
    // are running, which is only when the user has switched the work on. Called on the main thread.
    func willResignActive() {
        if !loopsRunning {
            return
        }
        for pass in passes {
            schedule(pass)
        }
        startOnActivation = true
    }

    // The app is back on the screen: the loops are started again if a pass in the background cancelled them. Starting loops that are
    // running does nothing. Called on the main thread.
    func didBecomeActive() {
        if !startOnActivation {
            return
        }
        startOnActivation = false
        startLoops { reason in
            if let reason = reason {
                BackgroundPasses.report("could not start the background work again: \(reason)")
            }
        }
    }

    // Asks the system to run a background pass when it next sees fit.
    private func schedule(_ pass: BackgroundPass) {
        let request = BGProcessingTaskRequest(identifier: pass.identifier)
        request.requiresNetworkConnectivity = pass.requiresNetwork
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: BackgroundPasses.earliestDelay)

        do {
            try BGTaskScheduler.shared.submit(request)
        }
        catch {
            BackgroundPasses.report("could not ask for the background pass \(pass.identifier): \(error)")
        }
    }

    // Runs on the system's queue: starts the core's loops on behalf of the system, and asks for the next pass.
    private func run(_ pass: BackgroundPass, task: BGTask) {
        // Asked for before the work starts, not after: a task ended on expiry never reaches the end, and without this there would be no
        // next request and the background work would stop for good.
        schedule(pass)

        let passRun = BackgroundPassRun(task: task)
        task.expirationHandler = { [weak self] in
            // The system's time is up. The loop this task stands for is cancelled, the same way the page cancels it, and the task is over.
            self?.bridge()?.send(channel: "cancel-tasks", data: pass.source)
            passRun.complete(success: false)
        }

        DispatchQueue.main.async {
            self.startOnActivation = true
            self.startLoops { reason in
                if let reason = reason {
                    BackgroundPasses.report("the core could not start the background work for \(pass.identifier): \(reason)")
                    passRun.complete(success: false)
                }
            }
        }
    }

    // Asks the core to start its background loops. Called on the main thread.
    private func startLoops(completion: @escaping (String?) -> Void) {
        guard let bridge = bridge() else {
            BackgroundPasses.fail("the background work was started with no bridge to the core")
        }
        bridge.request(channel: "startBackgroundImport", data: NSNull(), completion: completion)
    }

    // Writes a problem to standard error and carries on.
    private static func report(_ message: String) {
        FileHandle.standardError.write(Data("photosphere shell: \(message)\n".utf8))
    }

    // Writes a problem to standard error and stops the app.
    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("photosphere shell: \(message)\n".utf8))
        exit(1)
    }
}
