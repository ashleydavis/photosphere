import XCTest
@testable import App

//
// Tests for the lock that keeps a background import pass and a background sync pass from running at
// the same time. The counterpart of BackgroundPassLockTest.java, case for case.
//
// What this stops is not a rare race. An import holds the database write lock and a chain of engine
// slots for the length of a run, and a sync started inside that takes a slot of its own and waits for
// a lock it will not get, which is how the engine pool deadlocked once already: silently, with the
// feature switched on and the counts at zero forever.
//
final class BackgroundPassLockTests: XCTestCase {

    func testNothingHoldsTheLockToStartWith() {
        let lock = BackgroundPassLock()

        XCTAssertFalse(lock.isHeld)
        XCTAssertNil(lock.holder)
    }

    func testTheFirstToAskGetsIt() {
        let lock = BackgroundPassLock()

        XCTAssertTrue(lock.tryAcquire(AutoImportDriver.passLockOwner))
        XCTAssertTrue(lock.isHeld)
        XCTAssertEqual(AutoImportDriver.passLockOwner, lock.holder)
    }

    func testTheSecondToAskIsRefusedRatherThanQueued() {
        // Refused rather than made to wait, so no loop is ever parked on it: a first backup of a
        // whole photo library runs for the better part of an hour.
        let lock = BackgroundPassLock()
        XCTAssertTrue(lock.tryAcquire(AutoImportDriver.passLockOwner))

        XCTAssertFalse(lock.tryAcquire(SyncDriver.passLockOwner))
    }

    func testTheHolderCannotTakeItTwice() {
        // A second acquisition by the same owner would mean a release somewhere was missed, and
        // allowing it would hide that rather than leaving it to be found.
        let lock = BackgroundPassLock()
        XCTAssertTrue(lock.tryAcquire(SyncDriver.passLockOwner))

        XCTAssertFalse(lock.tryAcquire(SyncDriver.passLockOwner))
    }

    func testReleasingLetsTheOtherLoopIn() {
        let lock = BackgroundPassLock()
        XCTAssertTrue(lock.tryAcquire(AutoImportDriver.passLockOwner))

        lock.release(AutoImportDriver.passLockOwner)

        XCTAssertFalse(lock.isHeld)
        XCTAssertTrue(lock.tryAcquire(SyncDriver.passLockOwner))
    }

    func testAReleaseByAnythingButTheHolderIsIgnored() {
        // Obeying it would let two passes run at once, which is the one thing this exists to prevent,
        // and it can only happen through a bug in a caller's defer block.
        let lock = BackgroundPassLock()
        XCTAssertTrue(lock.tryAcquire(AutoImportDriver.passLockOwner))

        lock.release(SyncDriver.passLockOwner)

        XCTAssertTrue(lock.isHeld)
        XCTAssertEqual(AutoImportDriver.passLockOwner, lock.holder)
        XCTAssertFalse(lock.tryAcquire(SyncDriver.passLockOwner))
    }

    func testReleasingWhenNothingHoldsItDoesNothing() {
        let lock = BackgroundPassLock()

        lock.release(SyncDriver.passLockOwner)

        XCTAssertFalse(lock.isHeld)
    }

    func testOnlyOneOfManyThreadsAskingAtOnceGetsIt() {
        // The two loops run on threads of their own and ask without any coordination between them.
        let lock = BackgroundPassLock()
        let askerCount = 8
        let acquired = NSMutableArray()
        let acquiredLock = NSLock()
        let allDone = expectation(description: "every asker has asked")
        allDone.expectedFulfillmentCount = askerCount

        for _ in 0..<askerCount {
            DispatchQueue.global().async {
                if lock.tryAcquire("asker") {
                    acquiredLock.lock()
                    acquired.add(true)
                    acquiredLock.unlock()
                }
                allDone.fulfill()
            }
        }

        wait(for: [allDone], timeout: 5)

        XCTAssertEqual(1, acquired.count, "exactly one asker may hold the lock")
    }
}
