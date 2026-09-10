import XCTest
@testable import App

//
// Tests for the background prefetch's decisions on iOS. The counterpart of PrefetchDriverTest.java,
// case for case, because the two drivers are answered by the same worker task and must decide the
// same things.
//
// The decision that matters most is when to stop. This loop is the only thing that repairs a replica
// whose prefetch failed, so a loop that stops for the wrong reason leaves the replica unfinished with
// nothing left to notice, which is the failure the whole loop exists to remove.
//
// The driver holds no platform at all: the plugin supplies the engine pool, the clock and the log
// through the PrefetchDriverHost protocol, and a recording double supplies them here.
//
final class PrefetchDriverTests: XCTestCase {

    //
    // A plan with one prefetch step, which is what an ordinary pass looks like.
    //
    private func runningPlan(pause: TimeInterval) -> PrefetchPlan {
        return PrefetchPlan(
            shouldRun: true,
            databasePath: "photosphere-default",
            reason: "",
            pauseBetweenRuns: pause,
            steps: [PrefetchPlan.Step(type: "prefetch-database", dataJson: "{}")])
    }

    //
    // A plan that refuses a pass, with the reason the log would carry.
    //
    private func refusedPlan(reason: String, pause: TimeInterval) -> PrefetchPlan {
        return PrefetchPlan(
            shouldRun: false,
            databasePath: "",
            reason: reason,
            pauseBetweenRuns: pause,
            steps: [])
    }

    //
    // Something a recording host throws when it is asked to fail.
    //
    private struct RecordedFailure: Error {}

    //
    // A host that answers with the plan it is given, records what it was asked to do, and never
    // really waits.
    //
    private final class RecordingHost: PrefetchDriverHost {

        //
        // The plan every pass is answered with.
        //
        var plan: PrefetchPlan

        //
        // What running a step reports.
        //
        var stepResult = PrefetchStepResult(succeeded: true, filesFetched: 1, filesStillMissing: 1)

        //
        // Whether readPlan throws rather than answering.
        //
        var planReadThrows = false

        //
        // Whether runStep throws.
        //
        var stepThrows = false

        //
        // The steps that were run, in order.
        //
        private(set) var stepsRun: [String] = []

        //
        // The gaps that were waited, in order.
        //
        private(set) var pauses: [TimeInterval] = []

        //
        // Everything reported, so a test can check a refusal says why.
        //
        private(set) var reports: [String] = []

        //
        // Set to end the loop from inside a pause, standing in for the app leaving the foreground.
        //
        weak var driverToStopWhilePaused: PrefetchDriver?

        //
        // Constructs a host answering with the given plan.
        //
        init(plan: PrefetchPlan) {
            self.plan = plan
        }

        func readPlan() throws -> PrefetchPlan {
            if planReadThrows {
                throw RecordedFailure()
            }
            return plan
        }

        func runStep(_ step: PrefetchPlan.Step) throws -> PrefetchStepResult {
            stepsRun.append(step.type)
            if stepThrows {
                throw RecordedFailure()
            }
            return stepResult
        }

        func pause(_ seconds: TimeInterval) -> Bool {
            pauses.append(seconds)
            if let driver = driverToStopWhilePaused {
                driver.stop()
                return false
            }
            return true
        }

        func report(_ message: String) {
            reports.append(message)
        }

        func reportError(_ message: String) {
            reports.append(message)
        }
    }

    func testAPassRunsTheStepsThePlanAsksFor() {
        let host = RecordingHost(plan: runningPlan(pause: 1))
        let driver = PrefetchDriver(host: host)

        driver.runOnePass()

        XCTAssertEqual(["prefetch-database"], host.stepsRun)
    }

    func testAPassThatFetchedNothingAndFoundNothingMissingEndsTheLoop() {
        // The replica is complete. Walking every object at the origin again every gap is thousands of
        // listings on a real library, so the loop stops and is started again when a database is
        // opened.
        let host = RecordingHost(plan: runningPlan(pause: 1))
        host.stepResult = PrefetchStepResult(succeeded: true, filesFetched: 0, filesStillMissing: 0)
        let driver = PrefetchDriver(host: host)

        XCTAssertEqual(PrefetchPassOutcome.stop, driver.runOnePass())

        driver.runLoop()

        XCTAssertTrue(host.pauses.isEmpty, "nothing is waited for once the loop is over")
    }

    func testAPassThatLeftFilesMissingKeepsTheLoopGoing() {
        let host = RecordingHost(plan: runningPlan(pause: 9))
        host.stepResult = PrefetchStepResult(succeeded: true, filesFetched: 3, filesStillMissing: 5)
        let driver = PrefetchDriver(host: host)
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertEqual([9], host.pauses, "the next pass is scheduled")
    }

    func testAPassThatFetchedFilesAndLeftNoneKeepsTheLoopGoing() {
        // It did work and found nothing left, which is not the same as finding nothing to do: one
        // more pass confirms it, and that pass is the one that stops.
        let host = RecordingHost(plan: runningPlan(pause: 11))
        host.stepResult = PrefetchStepResult(succeeded: true, filesFetched: 4, filesStillMissing: 0)
        let driver = PrefetchDriver(host: host)
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertEqual([11], host.pauses)
    }

    func testAFailedStepKeepsTheLoopGoing() {
        // This is the whole reason the loop exists: a prefetch that failed used to be never tried
        // again, and the replica it left unfinished could not be repaired by a sync.
        let host = RecordingHost(plan: runningPlan(pause: 7))
        host.stepResult = PrefetchStepResult(succeeded: false, filesFetched: 0, filesStillMissing: 0)
        let driver = PrefetchDriver(host: host)
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertEqual([7], host.pauses, "a failed pass must never be read as a complete replica")
    }

    func testAStepThatThrowsKeepsTheLoopGoing() {
        let host = RecordingHost(plan: runningPlan(pause: 4))
        host.stepThrows = true
        let driver = PrefetchDriver(host: host)
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertEqual([4], host.pauses)
    }

    func testARefusedPassRunsNothingAndSaysWhy() {
        let host = RecordingHost(plan: refusedPlan(reason: "syncing is switched off", pause: 1))
        let driver = PrefetchDriver(host: host)

        driver.runOnePass()

        XCTAssertTrue(host.stepsRun.isEmpty, "a refused pass must run no steps")
        XCTAssertTrue(host.reports.joined().contains("syncing is switched off"), "the reason must reach the log")
    }

    func testARefusedPassDoesNotEndTheLoop() {
        // Every reason a pass is refused (syncing off, a cellular connection, no database, no origin,
        // a database that is not partial) can stop being true without the app being touched.
        let host = RecordingHost(plan: refusedPlan(reason: "the connection is \"cellular\"", pause: 13))
        let driver = PrefetchDriver(host: host)
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertEqual([13], host.pauses, "the loop waits and asks again")
        XCTAssertTrue(driver.isStopped, "the loop must have ended by being stopped")
    }

    func testAPlanThatCannotBeReadDoesNotEndTheLoop() {
        let host = RecordingHost(plan: runningPlan(pause: 3))
        host.planReadThrows = true
        let driver = PrefetchDriver(host: host)
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertGreaterThanOrEqual(host.pauses.count, 1, "a plan that cannot be read must not end the loop for good")
    }

    func testStoppingEndsTheLoop() {
        let host = RecordingHost(plan: runningPlan(pause: 5))
        let driver = PrefetchDriver(host: host)
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertEqual(1, host.pauses.count, "one pass runs, then the stop is noticed")
        XCTAssertTrue(driver.isStopped)
    }

    func testAStoppedDriverRunsNoFurtherPasses() {
        let host = RecordingHost(plan: runningPlan(pause: 1))
        let driver = PrefetchDriver(host: host)

        driver.stop()
        driver.runLoop()

        XCTAssertTrue(host.stepsRun.isEmpty, "a stopped driver runs no step")
        XCTAssertTrue(host.pauses.isEmpty, "and waits for nothing")
    }

    func testResumeLetsTheDriverRunAgain() {
        // Which is what happens when the app comes back to the screen, and what lets a loop that
        // finished a replica start again for the next partial one.
        let host = RecordingHost(plan: runningPlan(pause: 1))
        let driver = PrefetchDriver(host: host)

        driver.stop()
        driver.resume()
        driver.runOnePass()

        XCTAssertEqual(["prefetch-database"], host.stepsRun)
    }

    func testTheGapBetweenPassesComesFromThePlan() {
        let host = RecordingHost(plan: runningPlan(pause: 1234))
        let driver = PrefetchDriver(host: host)
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertEqual([1234], host.pauses)
    }
}
