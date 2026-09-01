import Foundation

//
// What one background automatic import pass should do, as answered by the plan-auto-import task.
//
// Nothing here is decided natively. The task reads the settings file and hands back the tasks the
// pass has to run, already built, so this is a carrier rather than a decision: the driver runs the
// steps in order and never assembles a task payload of its own. The counterpart of AutoImportPlan in
// the Android app, deliberately identical, because both are answered by the same worker task.
//
struct AutoImportPlan {

    //
    // One task the pass runs, with its input data already serialised to the JSON string the engine
    // pool takes.
    //
    struct Step {

        //
        // The task type to queue (for example "import-assets").
        //
        let type: String

        //
        // The task's input data as a JSON string, forwarded to the engine unchanged.
        //
        let dataJson: String
    }

    //
    // Whether a pass should run at all. False means automatic import is switched off.
    //
    let shouldRun: Bool

    //
    // The sandbox-relative path of the database the pass imports into. Carried for the log line that
    // says what is being backed up and where.
    //
    let databasePath: String

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
// What a finished pass says about what should happen next.
//
enum AutoImportPassOutcome {

    //
    // The pass ran (or tried to). Wait the gap and go again.
    //
    case ran

    //
    // Automatic import is switched off. Stop.
    //
    case stop
}

//
// Everything the driver needs that it cannot do itself: talking to the engine pool, waiting, and
// saying what happened.
//
// It is a protocol so the loop's decisions could be exercised without a running engine, and so the
// driver holds no reference to the plugin.
//
protocol AutoImportDriverHost: AnyObject {

    //
    // Runs the plan-auto-import task and returns what it says a pass should do. Throws when the task
    // fails, which the driver treats as a pass that did not work rather than as a reason to give up.
    //
    func readPlan() throws -> AutoImportPlan

    //
    // Runs one of the plan's steps and waits for it to finish. Returns true when it succeeded.
    //
    func runStep(_ step: AutoImportPlan.Step) throws -> Bool

    //
    // Waits for the given time, or until the driver is stopped. Returns false when the wait was cut
    // short by a stop, so the loop ends instead of starting another pass.
    //
    func pause(_ seconds: TimeInterval) -> Bool

    //
    // Reports what the background import is doing.
    //
    func report(_ message: String)

    //
    // Reports something that went wrong.
    //
    func reportError(_ message: String)
}

//
// The background automatic import on iOS: one pass at a time, and a loop above it.
//
// This is the counterpart of AutoImportDriver.java, with the same single serialised entry point for
// running a pass. It matters more here than on Android, because two different things ask for a pass:
// the loop that runs while the app is foregrounded, and the background processing task the system
// schedules when it chooses. Neither knows about the other, and there is no handover to get wrong,
// because two passes at once is not a state the code can reach.
//
// What iOS cannot do is keep the loop running while the app is off screen. A BGProcessingTask runs
// when the system decides, typically while the phone is charging and idle, and can be killed at any
// moment, so the honest description of iOS is that it catches up in the background when the system
// allows, rather than that it backs up continuously.
//
final class AutoImportDriver {

    //
    // The name this driver takes the shared pass lock under, so a skipped pass can say what it is
    // waiting behind.
    //
    static let passLockOwner = "import"

    //
    // The gap between passes when no plan has said what it should be, in seconds.
    //
    // Only reached when the very first plan read fails, because every plan carries a gap the settings
    // file resolves (see resolveAutoImportPauseMs in packages/api/src/lib/auto-import-mobile.ts). It
    // exists because a gap of zero is not a gap: the loop would ask for a pass, fail to read a plan,
    // and ask again as fast as the engine could answer.
    //
    private static let fallbackPause: TimeInterval = 30

    //
    // Everything the driver needs that it cannot do itself.
    //
    private weak var host: AutoImportDriverHost?

    //
    // The lock that keeps an import pass and a sync pass apart. An import holds the database write
    // lock and a chain of engine slots for the length of a run, and a sync waiting inside that is
    // what deadlocked the engine pool once already.
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
    // What the pass that just finished decided, handed to anyone who waited for it.
    //
    private var lastOutcome: AutoImportPassOutcome = .ran

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
    private var pauseBetweenPasses: TimeInterval = AutoImportDriver.fallbackPause

    //
    // Constructs a driver over the given host, sharing the given pass lock with the sync driver.
    //
    init(host: AutoImportDriverHost, sharedPassLock: BackgroundPassLock) {
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
    // foreground with automatic import still switched on.
    //
    func resume() {
        stateLock.lock()
        stoppedFlag = false
        stateLock.unlock()
    }

    //
    // Runs passes until a plan says automatic import is switched off, or until the driver is stopped.
    //
    // A pass that fails does not end the loop. The next one is scheduled anyway: an import can fail
    // for a reason that has since gone, and giving up would leave automatic import switched on in the
    // interface and doing nothing.
    //
    func runLoop() {
        while !isStopped {
            let outcome = runOnePass()
            if outcome == .stop {
                return
            }

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
    // Runs one pass, or waits for the one already running and reports what it decided.
    //
    // This is the only way a pass starts. The foreground loop asks repeatedly; the background
    // processing task asks once. Two passes at once is not a state the code can reach, so nothing
    // anywhere has to stop one before starting another.
    //
    @discardableResult
    func runOnePass() -> AutoImportPassOutcome {
        passCondition.lock()
        if passRunning {
            while passRunning {
                passCondition.wait()
            }
            let outcome = lastOutcome
            passCondition.unlock()
            return outcome
        }
        passRunning = true
        passCondition.unlock()

        let outcome = performPass()

        passCondition.lock()
        passRunning = false
        lastOutcome = outcome
        passCondition.broadcast()
        passCondition.unlock()

        return outcome
    }

    //
    // Asks what this pass should do and runs it.
    //
    private func performPass() -> AutoImportPassOutcome {
        guard let host = host else {
            return .stop
        }

        let plan: AutoImportPlan
        do {
            plan = try host.readPlan()
        }
        catch {
            // A plan that cannot be read is not an answer of "switched off". Treating it as one would
            // stop automatic import for good over a single failed task, so the pass counts as run and
            // the next one asks again.
            host.reportError("Could not work out what automatic import should do: \(error)")
            return .ran
        }

        // Clamped rather than taken as given: a gap of zero or less is a loop with no gap at all.
        stateLock.lock()
        pauseBetweenPasses = plan.pauseBetweenRuns > 0 ? plan.pauseBetweenRuns : AutoImportDriver.fallbackPause
        stateLock.unlock()

        if !plan.shouldRun {
            host.report("Automatic import is switched off.")
            return .stop
        }

        if !sharedPassLock.tryAcquire(AutoImportDriver.passLockOwner) {
            // A sync pass is in flight. Skipped rather than waited for, so this loop stays free to
            // notice automatic import being switched off; the next pass starts after the usual gap.
            host.report("Not importing yet: a sync pass is running.")
            return .ran
        }

        defer { sharedPassLock.release(AutoImportDriver.passLockOwner) }

        host.report("Automatic import running into \"\(plan.databasePath)\".")

        for step in plan.steps {
            if isStopped {
                return .ran
            }

            do {
                let succeeded = try host.runStep(step)
                if !succeeded {
                    // The rest of the pass is abandoned, not the loop: an import into a database that
                    // could not be created has nothing to import into, and the next pass starts from
                    // the plan again rather than from where this one gave up.
                    host.reportError("Automatic import step \"\(step.type)\" did not succeed.")
                    return .ran
                }
            }
            catch {
                host.reportError("Automatic import step \"\(step.type)\" failed: \(error)")
                return .ran
            }
        }

        return .ran
    }
}
