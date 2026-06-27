import XCTest
@testable import App

//
// A deterministic stub engine for dispatcher tests. It records the order tasks start and stays
// "running" until the test explicitly completes the task, so the test controls exactly when a slot
// frees. This lets the dispatcher be exercised with no JSContext, mirroring the Android stub-engine
// dispatcher tests.
//
private final class StubEngine: TaskEngine {

    //
    // Shared coordinator that records start order and holds the callbacks needed to complete tasks.
    //
    let coordinator: StubCoordinator

    //
    // Constructs the stub engine bound to the shared coordinator.
    //
    init(coordinator: StubCoordinator) {
        self.coordinator = coordinator
    }

    //
    // Records the task as started and parks it; the coordinator completes it later on the test's
    // command, simulating a long-running task that keeps its slot busy.
    //
    func runTask(_ task: PooledTask, callbacks: EngineCallbacks) {
        coordinator.recordStart(task: task, callbacks: callbacks)
    }

    //
    // No-op disposal: the stub holds no native resources.
    //
    func dispose() {
    }
}

//
// Shared state across stub engines: it records the order tasks started and keeps each task's
// callbacks so the test can complete a chosen task and free its slot.
//
private final class StubCoordinator {

    //
    // A started task paired with the callbacks used to complete it.
    //
    struct Started {
        let task: PooledTask
        let callbacks: EngineCallbacks
    }

    //
    // Serialises access to the recorded state since the pool may start tasks from multiple threads.
    //
    private let lock = NSLock()

    //
    // The tasks that have started, in start order.
    //
    private(set) var started: [Started] = []

    //
    // Records a started task and its callbacks under the lock.
    //
    func recordStart(task: PooledTask, callbacks: EngineCallbacks) {
        lock.lock()
        started.append(Started(task: task, callbacks: callbacks))
        lock.unlock()
    }

    //
    // Returns the ordered list of started task ids for assertions.
    //
    func startedTaskIds() -> [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return started.map { entry in entry.task.taskId }
    }

    //
    // Completes the started task with the given id by invoking its success callback, freeing its slot.
    //
    func complete(taskId: String) {
        lock.lock()
        let match = started.first { entry in entry.task.taskId == taskId }
        lock.unlock()

        if let match = match {
            match.callbacks.onTaskSucceeded(match.task, outputsJson: "null")
        }
    }
}

//
// Captures pool delegate events for assertions.
//
private final class CapturingDelegate: EnginePoolDelegate {

    //
    // Ids of tasks reported as succeeded, in order.
    //
    private(set) var succeeded: [String] = []

    //
    // Ids of tasks reported as failed, in order.
    //
    private(set) var failed: [String] = []

    //
    // Records a success.
    //
    func poolDidSucceed(_ task: PooledTask, outputsJson: String) {
        succeeded.append(task.taskId)
    }

    //
    // Records a failure.
    //
    func poolDidFail(_ task: PooledTask, errorMessage: String) {
        failed.append(task.taskId)
    }

    //
    // Ignored by these dispatcher tests.
    //
    func poolDidEmitMessage(_ task: PooledTask, messageJson: String) {
    }
}

//
// Drives the EnginePool dispatcher with stub engines to assert FIFO ordering, idle-slot assignment,
// the concurrency cap, size-1 serial execution, and cancel-drops-pending behaviour.
//
final class EnginePoolTests: XCTestCase {

    //
    // The storage root passed to the pool; unused by the stub engines but required by the bridge.
    //
    private var storageRoot: URL!

    //
    // Creates a temporary storage root for the pool's host bridges.
    //
    override func setUpWithError() throws {
        storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    //
    // Removes the temporary storage root.
    //
    override func tearDownWithError() throws {
        if let storageRoot = storageRoot {
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }

    //
    // Builds a pool of the given size backed by stub engines sharing one coordinator.
    //
    private func makePool(size: Int, delegate: EnginePoolDelegate, coordinator: StubCoordinator) -> EnginePool {
        return EnginePool(
            delegate: delegate,
            storageRoot: storageRoot,
            poolSize: size,
            engineFactory: { _, _ in StubEngine(coordinator: coordinator) }
        )
    }

    //
    // Helper to build a task for a given id and source.
    //
    private func task(_ id: String, source: String = "db-1") -> PooledTask {
        return PooledTask(taskId: id, type: "noop", dataJson: "{}", source: source)
    }

    //
    // Concurrency cap: with pool size 2, only two of three queued tasks start until a slot frees.
    //
    func testConcurrencyCapAndIdleSlotReassignment() {
        let delegate = CapturingDelegate()
        let coordinator = StubCoordinator()
        let pool = makePool(size: 2, delegate: delegate, coordinator: coordinator)

        pool.addTask(task("t1"))
        pool.addTask(task("t2"))
        pool.addTask(task("t3"))

        // Only two slots, so only the first two tasks run; the third stays pending.
        XCTAssertEqual(coordinator.startedTaskIds(), ["t1", "t2"])

        // Completing t1 frees a slot; the dispatcher assigns the next pending task (t3) to it.
        coordinator.complete(taskId: "t1")
        XCTAssertEqual(coordinator.startedTaskIds(), ["t1", "t2", "t3"])
        XCTAssertEqual(delegate.succeeded, ["t1"])
    }

    //
    // Size-1 serial: with pool size 1, tasks run strictly one after another.
    //
    func testSizeOneSerialExecution() {
        let delegate = CapturingDelegate()
        let coordinator = StubCoordinator()
        let pool = makePool(size: 1, delegate: delegate, coordinator: coordinator)

        pool.addTask(task("t1"))
        pool.addTask(task("t2"))
        pool.addTask(task("t3"))

        // Only the first task runs; the rest wait for the single slot.
        XCTAssertEqual(coordinator.startedTaskIds(), ["t1"])

        coordinator.complete(taskId: "t1")
        XCTAssertEqual(coordinator.startedTaskIds(), ["t1", "t2"])

        coordinator.complete(taskId: "t2")
        XCTAssertEqual(coordinator.startedTaskIds(), ["t1", "t2", "t3"])
    }

    //
    // FIFO ordering: pending tasks dispatch in the order they were enqueued.
    //
    func testFifoOrdering() {
        let delegate = CapturingDelegate()
        let coordinator = StubCoordinator()
        let pool = makePool(size: 1, delegate: delegate, coordinator: coordinator)

        pool.addTask(task("a"))
        pool.addTask(task("b"))
        pool.addTask(task("c"))

        coordinator.complete(taskId: "a")
        coordinator.complete(taskId: "b")
        coordinator.complete(taskId: "c")

        XCTAssertEqual(coordinator.startedTaskIds(), ["a", "b", "c"])
    }

    //
    // Cancel drops pending: cancelling a source removes its still-pending tasks so they never start.
    //
    func testCancelDropsPendingTasks() {
        let delegate = CapturingDelegate()
        let coordinator = StubCoordinator()
        let pool = makePool(size: 1, delegate: delegate, coordinator: coordinator)

        pool.addTask(task("t1", source: "db-1"))
        pool.addTask(task("t2", source: "db-1"))
        pool.addTask(task("t3", source: "db-2"))

        // t1 runs; t2 and t3 are pending.
        XCTAssertEqual(coordinator.startedTaskIds(), ["t1"])

        // Cancel db-1: t2 (pending, db-1) must be dropped; t3 (db-2) still runs after t1.
        pool.cancelTasks(source: "db-1")
        coordinator.complete(taskId: "t1")

        XCTAssertEqual(coordinator.startedTaskIds(), ["t1", "t3"])
    }

    //
    // A task enqueued for an already-cancelled source is dropped immediately and never starts.
    //
    func testAddTaskForCancelledSourceDropped() {
        let delegate = CapturingDelegate()
        let coordinator = StubCoordinator()
        let pool = makePool(size: 2, delegate: delegate, coordinator: coordinator)

        pool.cancelTasks(source: "db-cancelled")
        pool.addTask(task("t1", source: "db-cancelled"))
        pool.addTask(task("t2", source: "db-live"))

        XCTAssertEqual(coordinator.startedTaskIds(), ["t2"])
    }
}
