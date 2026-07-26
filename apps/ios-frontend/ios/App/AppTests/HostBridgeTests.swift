import XCTest
import JavaScriptCore
@testable import App

//
// Tests the native host bridge directly: sha256 reporting NOT IMPLEMENTED (hashing is not
// implemented natively), sendMessage capture through the message sink, and isCancelled reading
// the provider. Mirrors the Android host-bridge tests.
//
final class HostBridgeTests: XCTestCase {

    //
    // The temporary storage root the bridge is sandboxed to, created fresh per test.
    //
    private var storageRoot: URL!

    //
    // Creates a unique temporary storage root for the test.
    //
    override func setUpWithError() throws {
        storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    //
    // Removes the temporary storage root after each test.
    //
    override func tearDownWithError() throws {
        if let storageRoot = storageRoot {
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }

    //
    // sha256 is not implemented natively, so it must throw the exact NOT IMPLEMENTED error
    // rather than computing a hash.
    //
    func testSha256ReportsNotImplemented() {
        let bridge = HostBridge(
            sessionId: "session-1",
            storageRoot: storageRoot,
            isCancelledProvider: { _ in false },
            messageSink: { _, _ in },
            queueTaskSink: { _, _, _, _, _ in }
        )

        XCTAssertThrowsError(try bridge.sha256(path: "vector.txt")) { error in
            XCTAssertEqual("\(error)", "NOT IMPLEMENTED: native host function \"sha256\" is not implemented yet on ios. Implement it ASAP.")
        }
    }

    //
    // sendMessage installed in a JSContext must route the taskId and messageJson to the message sink.
    //
    func testSendMessageRoutesToSink() {
        var capturedTaskId: String?
        var capturedMessage: String?

        let bridge = HostBridge(
            sessionId: "session-1",
            storageRoot: storageRoot,
            isCancelledProvider: { _ in false },
            messageSink: { taskId, messageJson in
                capturedTaskId = taskId
                capturedMessage = messageJson
            },
            queueTaskSink: { _, _, _, _, _ in }
        )

        let context = JSContext()!
        bridge.install(into: context)
        context.evaluateScript("host.sendMessage('task-1', '{\"value\":42}')")

        XCTAssertEqual(capturedTaskId, "task-1")
        XCTAssertEqual(capturedMessage, "{\"value\":42}")
    }

    //
    // isCancelled installed in a JSContext must return the provider's boolean for the task.
    //
    func testIsCancelledReadsProvider() {
        let bridge = HostBridge(
            sessionId: "session-1",
            storageRoot: storageRoot,
            isCancelledProvider: { taskId in taskId == "cancelled-task" },
            messageSink: { _, _ in },
            queueTaskSink: { _, _, _, _, _ in }
        )

        let context = JSContext()!
        bridge.install(into: context)

        let cancelled = context.evaluateScript("host.isCancelled('cancelled-task')")
        let live = context.evaluateScript("host.isCancelled('live-task')")

        XCTAssertEqual(cancelled?.toBool(), true)
        XCTAssertEqual(live?.toBool(), false)
    }

    //
    // platform and sessionId must be exposed on the installed host object.
    //
    func testPlatformAndSessionId() {
        let bridge = HostBridge(
            sessionId: "session-xyz",
            storageRoot: storageRoot,
            isCancelledProvider: { _ in false },
            messageSink: { _, _ in },
            queueTaskSink: { _, _, _, _, _ in }
        )

        let context = JSContext()!
        bridge.install(into: context)

        XCTAssertEqual(context.evaluateScript("host.platform")?.toString(), "ios")
        XCTAssertEqual(context.evaluateScript("host.sessionId")?.toString(), "session-xyz")
    }

    //
    // queueTask installed in a JSContext must forward the child to the sink tagged with the current
    // (parent) task id when a task is running on the engine.
    //
    func testQueueTaskForwardsTaggedWithParentIdWhenTaskIsCurrent() {
        var captured: [String] = []

        let bridge = HostBridge(
            sessionId: "session-1",
            storageRoot: storageRoot,
            isCancelledProvider: { _ in false },
            messageSink: { _, _ in },
            queueTaskSink: { parentTaskId, childTaskId, type, dataJson, source in
                captured = [parentTaskId, childTaskId, type, dataJson, source]
            }
        )
        bridge.currentTaskId = "parent-1"

        let context = JSContext()!
        bridge.install(into: context)
        context.evaluateScript("host.queueTask('child-1', 'childType', '{}', 'src')")

        XCTAssertEqual(captured, ["parent-1", "child-1", "childType", "{}", "src"])
    }

    //
    // queueTask must be a no-op when no task is current, because there is no parent to route the
    // child's outcome back to.
    //
    func testQueueTaskIsIgnoredWithoutACurrentTask() {
        var called = false

        let bridge = HostBridge(
            sessionId: "session-1",
            storageRoot: storageRoot,
            isCancelledProvider: { _ in false },
            messageSink: { _, _ in },
            queueTaskSink: { _, _, _, _, _ in called = true }
        )

        let context = JSContext()!
        bridge.install(into: context)
        context.evaluateScript("host.queueTask('child-1', 'childType', '{}', 'src')")

        XCTAssertFalse(called)
    }
}
