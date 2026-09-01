import Foundation

//
// What one background sync pass should do, as answered by the plan-sync task.
//
// Nothing here is decided natively. The task reads the settings file, asks the platform what kind of
// connection this is, applies the same rule the app's interface applies, and hands back the task the
// pass has to run, already built. The counterpart of SyncPlan.java, deliberately identical, because
// both are answered by the same worker task.
//
struct SyncPlan {

    //
    // One task the pass runs, with its input data already serialised to the JSON string the engine
    // pool takes.
    //
    struct Step {

        //
        // The task type to queue (for example "sync-database").
        //
        let type: String

        //
        // The task's input data as a JSON string, forwarded to the engine unchanged.
        //
        let dataJson: String
    }

    //
    // Whether a sync should run right now. False never ends the loop: every reason to refuse a sync
    // can go away without the app being touched.
    //
    let shouldRun: Bool

    //
    // The sandbox-relative path of the database the pass syncs. Empty when no sync is running.
    //
    let databasePath: String

    //
    // Why no sync is running, for the log. Empty when one is.
    //
    let reason: String

    //
    // How long to wait after this pass finishes before starting the next one, in seconds.
    //
    let pauseBetweenRuns: TimeInterval

    //
    // The tasks the pass runs, in order. Empty when shouldRun is false.
    //
    let steps: [Step]
}

//
// Everything the sync driver needs that it cannot do itself: talking to the engine pool, waiting, and
// saying what happened.
//
// It is a protocol so the loop's decisions can be exercised without a running engine, and so the
// driver holds no reference to the plugin.
//
protocol SyncDriverHost: AnyObject {

    //
    // Runs the plan-sync task and returns what it says a pass should do. Throws when the task fails,
    // which the driver treats as a pass that did not work rather than as a reason to give up.
    //
    func readPlan() throws -> SyncPlan

    //
    // Runs one of the plan's steps and waits for it to finish. Returns true when it succeeded.
    //
    func runStep(_ step: SyncPlan.Step) throws -> Bool

    //
    // Waits for the given time, or until the driver is stopped. Returns false when the wait was cut
    // short by a stop, so the loop ends instead of starting another pass.
    //
    func pause(_ seconds: TimeInterval) -> Bool

    //
    // Reports what the background sync is doing.
    //
    func report(_ message: String)

    //
    // Reports something that went wrong.
    //
    func reportError(_ message: String)
}

//
// The background sync on iOS: one pass at a time, and a loop above it.
//
// This is the counterpart of SyncDriver.java, with the same single serialised entry point for running
// a pass. It matters more here than on Android, because two different things ask for a pass: the loop
// that runs while the app is foregrounded, and the background processing task the system schedules
// when it chooses. Neither knows about the other, and there is no handover to get wrong, because two
// passes at once is not a state the code can reach.
//
// Nothing a plan says ends this loop. Every reason a sync is refused can go away without the app
// being touched: a phone moves onto Wi-Fi, a network comes back, a database gets an origin, the user
// switches syncing back on. A refused pass costs a settings file read.
//
// What iOS cannot do is keep the loop running while the app is off screen. A BGProcessingTask runs
// when the system decides, typically while the phone is charging and idle, and can be killed at any
// moment, so the honest description of iOS is that it catches up in the background when the system
// allows, rather than that it syncs continuously.
//
final class SyncDriver {

    //
    // The name this driver takes the shared pass lock under, so a skipped pass can say what it is
    // waiting behind.
    //
    static let passLockOwner = "sync"

    //
    // The gap between passes when no plan has said what it should be, in seconds.
    //
    // Only reached when the very first plan read fails, because every plan carries a gap the settings
    // file resolves (see resolveSyncPauseMs in packages/api/src/lib/sync-settings.ts). It exists
    // because a gap of zero is not a gap: the loop would ask for a pass, fail to read a plan, and ask
    // again as fast as the engine could answer.
    //
    private static let fallbackPause: TimeInterval = 5 * 60

    //
    // Everything the driver needs that it cannot do itself.
    //
    private weak var host: SyncDriverHost?

    //
    // The lock that keeps a sync pass and an import pass apart.
    //
    private let sharedPassLock: BackgroundPassLock

    //
    // Guards the pass bookkeeping below, and is what a second caller waits on while a pass runs.
    //
    private let passCondition = NSCondition()

    //
    // True while a pass is in flight, so a second request waits for it rather than starting another.
    //
    private var passRunning = false

    //
    // Guards the stopped flag and the pause below, both of which are read and written from the
    // foreground loop's thread and the plugin's.
    //
    private let stateLock = NSLock()

    //
    // True once the driver has been stopped.
    //
    private var stoppedFlag = false

    //
    // How long to wait before the next pass, as the last plan asked.
    //
    private var pauseBetweenPasses: TimeInterval = SyncDriver.fallbackPause

    //
    // Constructs a driver over the given host, sharing the given pass lock with the import driver.
    //
    init(host: SyncDriverHost, sharedPassLock: BackgroundPassLock) {
        self.host = host
        self.sharedPassLock = sharedPassLock
    }

    //
    // True once the driver has been stopped.
    //
    var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stoppedFlag
    }

    //
    // Stops the driver: no further passes start, and a loop waiting between passes ends rather than
    // running another. A pass already in flight is left to finish; the engine pool cancels the tasks
    // it queued by source, which is what actually stops the work.
    //
    func stop() {
        stateLock.lock()
        stoppedFlag = true
        stateLock.unlock()
    }

    //
    // Lets the driver run again after a stop, which is what happens when the app returns to the
    // foreground.
    //
    func resume() {
        stateLock.lock()
        stoppedFlag = false
        stateLock.unlock()
    }

    //
    // Runs passes until the driver is stopped.
    //
    // A pass that fails does not end the loop. Sync has more reasons to fail than import does, not
    // fewer: no network, a remote that is briefly unreachable, an expired credential. Every one of
    // them can be gone by the next pass.
    //
    func runLoop() {
        while !isStopped {
            runOnePass()

            if isStopped {
                return
            }

            stateLock.lock()
            let waitFor = pauseBetweenPasses
            stateLock.unlock()

            guard let host = host, host.pause(waitFor) else {
                return
            }
        }
    }

    //
    // Runs one pass, or waits for the one already running.
    //
    // This is the only way a pass starts. The foreground loop asks repeatedly; the background
    // processing task asks once. Two passes at once is not a state the code can reach, so nothing
    // anywhere has to stop one before starting another.
    //
    func runOnePass() {
        passCondition.lock()
        if passRunning {
            while passRunning {
                passCondition.wait()
            }
            passCondition.unlock()
            return
        }
        passRunning = true
        passCondition.unlock()

        performPass()

        passCondition.lock()
        passRunning = false
        passCondition.broadcast()
        passCondition.unlock()
    }

    //
    // Asks whether a sync should run and runs it.
    //
    private func performPass() {
        guard let host = host else {
            return
        }

        let plan: SyncPlan
        do {
            plan = try host.readPlan()
        }
        catch {
            // A plan that cannot be read is not an answer of "do not sync". The pass counts as run
            // and the next one asks again.
            host.reportError("Could not work out whether a sync should run: \(error)")
            return
        }

        // Clamped rather than taken as given: a gap of zero or less is a loop with no gap at all.
        stateLock.lock()
        pauseBetweenPasses = plan.pauseBetweenRuns > 0 ? plan.pauseBetweenRuns : SyncDriver.fallbackPause
        stateLock.unlock()

        if !plan.shouldRun {
            host.report("Not syncing: \(plan.reason)")
            return
        }

        if !sharedPassLock.tryAcquire(SyncDriver.passLockOwner) {
            // An import pass is in flight. Skipped rather than waited for: an import of a whole photo
            // library runs for the better part of an hour, and the sync it is holding up is one that
            // will be asked for again in a few minutes anyway.
            host.report("Not syncing yet: an import pass is running.")
            return
        }

        defer { sharedPassLock.release(SyncDriver.passLockOwner) }

        host.report("Syncing \"\(plan.databasePath)\".")

        for step in plan.steps {
            if isStopped {
                return
            }

            do {
                let succeeded = try host.runStep(step)
                if !succeeded {
                    // The rest of the pass is abandoned, not the loop, and the next pass starts from
                    // the plan again rather than from where this one gave up.
                    host.reportError("Sync step \"\(step.type)\" did not succeed.")
                    return
                }
            }
            catch {
                host.reportError("Sync step \"\(step.type)\" failed: \(error)")
                return
            }
        }
    }
}
