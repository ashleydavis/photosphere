import XCTest
@testable import App

//
// Tests for the background sync's decisions on iOS. The counterpart of SyncDriverTest.java, case for
// case, because the two drivers are answered by the same worker task and must decide the same things.
//
// The driver holds no platform at all: the plugin supplies the engine pool, the clock and the log
// through the SyncDriverHost protocol, and a recording double supplies them here.
//
final class SyncDriverTests: XCTestCase {

    //
    // A plan with one sync step, which is what an ordinary pass looks like.
    //
    private func runningPlan(pause: TimeInterval) -> SyncPlan {
        return SyncPlan(
            shouldRun: true,
            databasePath: "photosphere-default",
            reason: "",
            pauseBetweenRuns: pause,
            steps: [SyncPlan.Step(type: "sync-database", dataJson: "{}")])
    }

    //
    // A plan that says no sync should run, with the reason the log would carry.
    //
    private func refusedPlan(reason: String, pause: TimeInterval) -> SyncPlan {
        return SyncPlan(
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
    private final class RecordingHost: SyncDriverHost {

        //
        // The plan every pass is answered with.
        //
        var plan: SyncPlan

        //
        // Whether readPlan throws rather than answering.
        //
        var planReadThrows = false

        //
        // Whether runStep reports failure.
        //
        var stepFails = false

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
        weak var driverToStopWhilePaused: SyncDriver?

        //
        // Constructs a host answering with the given plan.
        //
        init(plan: SyncPlan) {
            self.plan = plan
        }

        func readPlan() throws -> SyncPlan {
            if planReadThrows {
                throw RecordedFailure()
            }
            return plan
        }

        func runStep(_ step: SyncPlan.Step) throws -> Bool {
            stepsRun.append(step.type)
            if stepThrows {
                throw RecordedFailure()
            }
            return !stepFails
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
        let driver = SyncDriver(host: host, sharedPassLock: BackgroundPassLock())

        driver.runOnePass()

        XCTAssertEqual(["sync-database"], host.stepsRun)
    }

    func testARefusedPassRunsNothingAndSaysWhy() {
        let host = RecordingHost(plan: refusedPlan(reason: "syncing is switched off", pause: 1))
        let driver = SyncDriver(host: host, sharedPassLock: BackgroundPassLock())

        driver.runOnePass()

        XCTAssertTrue(host.stepsRun.isEmpty, "a refused pass must run no steps")
        XCTAssertTrue(host.reports.joined().contains("syncing is switched off"), "the reason must reach the log")
    }

    func testARefusedPassDoesNotEndTheLoop() {
        // Every reason a sync is refused can go away without the app being touched: a phone moves
        // onto Wi-Fi, a network comes back, the user switches syncing on again.
        let host = RecordingHost(plan: refusedPlan(reason: "the connection is \"cellular\"", pause: 1))
        let driver = SyncDriver(host: host, sharedPassLock: BackgroundPassLock())
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertGreaterThanOrEqual(host.pauses.count, 1, "the loop must have gone on to wait for the next pass")
        XCTAssertTrue(driver.isStopped, "the loop must have ended by being stopped")
    }

    func testAFailedStepDoesNotEndTheLoop() {
        // Sync has more reasons to fail than import does, not fewer: no network, a remote that is
        // briefly unreachable, an expired credential.
        let host = RecordingHost(plan: runningPlan(pause: 1))
        host.stepFails = true
        let driver = SyncDriver(host: host, sharedPassLock: BackgroundPassLock())
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertEqual(1, host.pauses.count, "the failed pass must still be followed by a wait")
    }

    func testAStepThatThrowsDoesNotEndTheLoop() {
        let host = RecordingHost(plan: runningPlan(pause: 1))
        host.stepThrows = true
        let driver = SyncDriver(host: host, sharedPassLock: BackgroundPassLock())
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertEqual(1, host.pauses.count, "the failed pass must still be followed by a wait")
    }

    func testAPlanThatCannotBeReadDoesNotEndTheLoop() {
        let host = RecordingHost(plan: runningPlan(pause: 1))
        host.planReadThrows = true
        let driver = SyncDriver(host: host, sharedPassLock: BackgroundPassLock())
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertGreaterThanOrEqual(host.pauses.count, 1, "a plan that cannot be read must not stop syncing for good")
    }

    func testStoppingEndsTheLoop() {
        let host = RecordingHost(plan: runningPlan(pause: 1))
        let driver = SyncDriver(host: host, sharedPassLock: BackgroundPassLock())
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertTrue(driver.isStopped)
        XCTAssertEqual(1, host.stepsRun.count, "the loop must have run exactly one pass before it was stopped")
    }

    func testTheGapComesFromThePlanRatherThanFromTheDriver() {
        let host = RecordingHost(plan: runningPlan(pause: 90))
        let driver = SyncDriver(host: host, sharedPassLock: BackgroundPassLock())
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertEqual(90, host.pauses.first)
    }

    func testAGapOfZeroIsRefusedRatherThanWaitedOn() {
        // A gap of zero is a loop with no gap at all: it would ask for a pass the instant the last
        // one ended, which on a phone is a flat battery rather than a fast backup.
        let host = RecordingHost(plan: runningPlan(pause: 0))
        let driver = SyncDriver(host: host, sharedPassLock: BackgroundPassLock())
        host.driverToStopWhilePaused = driver

        driver.runLoop()

        XCTAssertGreaterThan(host.pauses.first ?? 0, 0, "the gap must have been replaced with a real one")
    }

    func testAPassIsSkippedWhileAnImportHoldsThePassLock() {
        // An import holds the database write lock and a chain of engine slots for the length of a
        // run. A sync started inside that would take a slot of its own and wait for a lock the import
        // is not going to release, which is what deadlocked the engine pool once already.
        let passLock = BackgroundPassLock()
        XCTAssertTrue(passLock.tryAcquire(AutoImportDriver.passLockOwner))

        let host = RecordingHost(plan: runningPlan(pause: 1))
        let driver = SyncDriver(host: host, sharedPassLock: passLock)

        driver.runOnePass()

        XCTAssertTrue(host.stepsRun.isEmpty, "no sync step may run while an import pass is in flight")
    }

    func testThePassLockIsGivenBackWhenAPassFinishes() {
        let passLock = BackgroundPassLock()
        let host = RecordingHost(plan: runningPlan(pause: 1))
        let driver = SyncDriver(host: host, sharedPassLock: passLock)

        driver.runOnePass()

        XCTAssertFalse(passLock.isHeld, "a pass that finished must not still hold the lock")
    }

    func testThePassLockIsGivenBackWhenAStepFails() {
        // A lock a failed pass kept would stop every import from then on, silently.
        let passLock = BackgroundPassLock()
        let host = RecordingHost(plan: runningPlan(pause: 1))
        host.stepFails = true
        let driver = SyncDriver(host: host, sharedPassLock: passLock)

        driver.runOnePass()

        XCTAssertFalse(passLock.isHeld)
    }

    func testThePassLockIsGivenBackWhenAStepThrows() {
        let passLock = BackgroundPassLock()
        let host = RecordingHost(plan: runningPlan(pause: 1))
        host.stepThrows = true
        let driver = SyncDriver(host: host, sharedPassLock: passLock)

        driver.runOnePass()

        XCTAssertFalse(passLock.isHeld)
    }

    func testASecondRequestWaitsForThePassInFlightRatherThanStartingAnother() {
        // On iOS the foreground loop and the system's background task both ask, and neither knows
        // about the other. Two passes at once has to be unreachable rather than unlikely.
        let stepStarted = expectation(description: "the first pass has started")
        let stepMayFinish = DispatchSemaphore(value: 0)

        final class BlockingHost: SyncDriverHost {

            //
            // The plan every pass is answered with.
            //
            let plan: SyncPlan

            //
            // Signalled when a step starts.
            //
            let stepStarted: XCTestExpectation

            //
            // Waited on inside a step, so a pass can be held open.
            //
            let stepMayFinish: DispatchSemaphore

            //
            // How many steps have run.
            //
            private(set) var stepCount = 0

            //
            // Guards the count above, which two threads reach.
            //
            private let countLock = NSLock()

            init(plan: SyncPlan, stepStarted: XCTestExpectation, stepMayFinish: DispatchSemaphore) {
                self.plan = plan
                self.stepStarted = stepStarted
                self.stepMayFinish = stepMayFinish
            }

            func readPlan() throws -> SyncPlan {
                return plan
            }

            func runStep(_ step: SyncPlan.Step) throws -> Bool {
                countLock.lock()
                stepCount += 1
                countLock.unlock()
                stepStarted.fulfill()
                _ = stepMayFinish.wait(timeout: .now() + 5)
                return true
            }

            func pause(_ seconds: TimeInterval) -> Bool {
                return false
            }

            func report(_ message: String) {
            }

            func reportError(_ message: String) {
            }

            //
            // How many steps ran, read under the lock.
            //
            func stepsRunCount() -> Int {
                countLock.lock()
                defer { countLock.unlock() }
                return stepCount
            }
        }

        let host = BlockingHost(plan: runningPlan(pause: 1), stepStarted: stepStarted, stepMayFinish: stepMayFinish)
        let driver = SyncDriver(host: host, sharedPassLock: BackgroundPassLock())

        let firstFinished = expectation(description: "the first caller has finished")
        DispatchQueue.global().async {
            driver.runOnePass()
            firstFinished.fulfill()
        }

        wait(for: [stepStarted], timeout: 5)

        let secondFinished = expectation(description: "the second caller has finished")
        DispatchQueue.global().async {
            driver.runOnePass()
            secondFinished.fulfill()
        }

        // Give the second caller time to get as far as it is going to get, which must be waiting
        // rather than running a pass of its own.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(1, host.stepsRunCount(), "the second request must not start a second pass")

        stepMayFinish.signal()
        wait(for: [firstFinished, secondFinished], timeout: 5)

        XCTAssertEqual(1, host.stepsRunCount(), "only one pass may ever have run")
    }
}
