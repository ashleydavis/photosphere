import Foundation

//
// What one background prefetch pass should do, as answered by the plan-prefetch task.
//
// Nothing here is decided natively. The task reads the settings file, asks the platform what kind of
// connection this is, checks the database has an origin and is a partial replica, and hands back the
// task the pass has to run, already built. The counterpart of PrefetchPlan.java, deliberately
// identical, because both are answered by the same worker task.
//
struct PrefetchPlan {

    //
    // One task the pass runs, with its input data already serialised to the JSON string the engine
    // pool takes.
    //
    struct Step {

        //
        // The task type to queue (for example "prefetch-database").
        //
        let type: String

        //
        // The task's input data as a JSON string, forwarded to the engine unchanged.
        //
        let dataJson: String
    }

    //
    // Whether a prefetch should run right now. False never ends the loop: every reason to refuse can
    // go away without the app being touched. What ends this loop is a pass that finds nothing left to
    // fetch, which is the driver's decision rather than the plan's.
    //
    let shouldRun: Bool

    //
    // The sandbox-relative path of the database the pass fills in. Empty when no prefetch is running.
    //
    let databasePath: String

    //
    // Why no prefetch is running, for the log. Empty when one is.
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
// What running one step did, which is the whole of what the loop decides on.
//
// A carrier rather than a number, because "it worked" and "how much was left" are separate answers
// and a single count cannot say both: no files fetched is what a complete replica and a failed pass
// both look like from outside, and they lead to opposite decisions.
//
struct PrefetchStepResult {

    //
    // Whether the step succeeded. A step that failed leaves the loop running, because the file that
    // would not copy is tried again on the next pass.
    //
    let succeeded: Bool

    //
    // How many files the step copied down from the origin.
    //
    let filesFetched: Int

    //
    // How many files the step found missing and did not copy.
    //
    let filesStillMissing: Int
}

//
// What a finished pass says about what should happen next.
//
enum PrefetchPassOutcome {

    //
    // The pass ran (or tried to), and there may be more to do. Wait the gap and go again.
    //
    case ran

    //
    // The replica is complete: the pass fetched nothing and found nothing missing. Stop, and be
    // started again when a database is opened.
    //
    case stop
}

//
// Everything the prefetch driver needs that it cannot do itself: talking to the engine pool, waiting,
// and saying what happened.
//
// It is a protocol so the loop's decisions can be exercised without a running engine, and so the
// driver holds no reference to the plugin.
//
protocol PrefetchDriverHost: AnyObject {

    //
    // Runs the plan-prefetch task and returns what it says a pass should do. Throws when the task
    // fails, which the driver treats as a pass that did not work rather than as a reason to give up.
    //
    func readPlan() throws -> PrefetchPlan

    //
    // Runs one of the plan's steps and waits for it to finish, reporting what it did.
    //
    func runStep(_ step: PrefetchPlan.Step) throws -> PrefetchStepResult

    //
    // Waits for the given time, or until the driver is stopped. Returns false when the wait was cut
    // short by a stop, so the loop ends instead of starting another pass.
    //
    func pause(_ seconds: TimeInterval) -> Bool

    //
    // Reports what the background prefetch is doing.
    //
    func report(_ message: String)

    //
    // Reports something that went wrong.
    //
    func reportError(_ message: String)
}

//
// The background prefetch on iOS: one pass at a time, and a loop above it.
//
// This is the counterpart of PrefetchDriver.java, with the same single serialised entry point for
// running a pass. It matters more here than on Android, because two different things ask for a pass:
// the loop that runs while the app is foregrounded, and the background processing task the system
// schedules when it chooses. Neither knows about the other, and there is no handover to get wrong,
// because two passes at once is not a state the code can reach.
//
// It exists because the only thing that ever queued a prefetch was the end of a load-assets run, so a
// prefetch that failed part way was never tried again, and a sync cannot repair the replica it left
// behind: a sync copies what the difference between two merkle trees shows, and a partial replica's
// tree already matches its origin's, so a missing file is invisible to it.
//
// Unlike the sync loop, this one ends itself when a pass reports the replica complete. Asking again
// would mean walking every object at the origin every gap, which on a real library is thousands of
// listings and thousands of local existence checks, and opening a database starts it again.
//
final class PrefetchDriver {

    //
    // The gap between passes when no plan has said what it should be, in seconds.
    //
    // Only reached when the very first plan read fails, because every plan carries a gap the settings
    // file resolves. It exists because a gap of zero is not a gap: the loop would ask for a pass, fail
    // to read a plan, and ask again as fast as the engine could answer.
    //
    private static let fallbackPause: TimeInterval = 5 * 60

    //
    // Everything the driver needs that it cannot do itself.
    //
    private weak var host: PrefetchDriverHost?

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
    private var lastOutcome: PrefetchPassOutcome = .ran

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
    private var pauseBetweenPasses: TimeInterval = PrefetchDriver.fallbackPause

    //
    // Constructs a driver over the given host.
    //
    init(host: PrefetchDriverHost) {
        self.host = host
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
    // foreground, and after a replica it had finished is joined by another that is not filled in.
    //
    func resume() {
        stateLock.lock()
        stoppedFlag = false
        stateLock.unlock()
    }

    //
    // Runs passes until one reports the replica complete, or until the driver is stopped.
    //
    // A pass that fails does not end the loop. The next one is scheduled anyway: a file can fail to
    // copy for a reason that has since gone, and this loop exists precisely because a prefetch that
    // gave up was never tried again.
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
    func runOnePass() -> PrefetchPassOutcome {
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
    // Asks whether a prefetch should run and runs it.
    //
    private func performPass() -> PrefetchPassOutcome {
        guard let host = host else {
            return .ran
        }

        let plan: PrefetchPlan
        do {
            plan = try host.readPlan()
        }
        catch {
            // A plan that cannot be read is not an answer of "nothing left to fetch". Treating it as
            // one would stop the loop for good over a single failed task, so the pass counts as run
            // and the next one asks again.
            host.reportError("Could not work out whether a prefetch should run: \(error)")
            return .ran
        }

        // Clamped rather than taken as given: a gap of zero or less is a loop with no gap at all.
        stateLock.lock()
        pauseBetweenPasses = plan.pauseBetweenRuns > 0 ? plan.pauseBetweenRuns : PrefetchDriver.fallbackPause
        stateLock.unlock()

        if !plan.shouldRun {
            // Refused, not finished. The loop keeps asking, because everything that refuses a pass can
            // stop refusing without the app being touched.
            host.report("Not filling in a replica: \(plan.reason)")
            return .ran
        }

        host.report("Filling in \"\(plan.databasePath)\".")

        var anythingFetched = false
        var anythingLeft = false

        for step in plan.steps {
            if isStopped {
                return .ran
            }

            do {
                let result = try host.runStep(step)
                if !result.succeeded {
                    // The loop keeps going, which is what makes a failed prefetch retry, and is the
                    // whole reason this loop exists.
                    host.reportError("Prefetch step \"\(step.type)\" did not succeed.")
                    return .ran
                }

                if result.filesFetched > 0 {
                    anythingFetched = true
                }
                if result.filesStillMissing > 0 {
                    anythingLeft = true
                }
            }
            catch {
                host.reportError("Prefetch step \"\(step.type)\" failed: \(error)")
                return .ran
            }
        }

        if !anythingFetched && !anythingLeft {
            // Nothing fetched and nothing missing: the replica is complete and there is nothing left
            // to walk. Opening a database queues a prefetch again, which is what starts this loop over
            // when there is a reason to.
            host.report("\"\(plan.databasePath)\" is filled in; nothing left to fetch.")
            return .stop
        }

        return .ran
    }
}
