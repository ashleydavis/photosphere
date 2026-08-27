import XCTest
import JavaScriptCore
import CommonCrypto
@testable import App

//
// Tests the native host bridge directly: sha256 hashing real files against known digests,
// sendMessage capture through the message sink, and isCancelled reading
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
    // Builds a bridge sandboxed to the test's storage root.
    //
    private func makeBridge() -> HostBridge {
        return HostBridge(
            sessionId: "session-1",
            storageRoot: storageRoot,
            isCancelledProvider: { _ in false },
            messageSink: { _, _ in },
            queueTaskSink: { _, _, _, _, _, _ in }
        )
    }

    //
    // A known input hashes to its published digest. Pinned against the standard vector rather than
    // against another run of the same code, because the whole value of this function is that it
    // agrees with what Node's crypto produced for every asset already in every database.
    //
    func testSha256MatchesTheKnownVectorForAbc() throws {
        try "abc".write(to: storageRoot.appendingPathComponent("abc.bin"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            try makeBridge().sha256(path: "abc.bin"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    //
    // An empty file hashes to the digest of no bytes, rather than to nil or an error. This catches
    // the streaming loop being skipped entirely.
    //
    func testSha256HandlesAnEmptyFile() throws {
        try Data().write(to: storageRoot.appendingPathComponent("empty.bin"))

        XCTAssertEqual(
            try makeBridge().sha256(path: "empty.bin"),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    //
    // A file bigger than one read buffer hashes the same as CommonCrypto's own digest over the same
    // bytes, which is what proves the streaming loop feeds every chunk in, in order.
    //
    func testSha256StreamsAFileLargerThanItsReadBuffer() throws {
        var contents = Data(count: (1024 * 1024 * 2) + 12345)
        for index in 0..<contents.count {
            contents[index] = UInt8(index % 251)
        }
        try contents.write(to: storageRoot.appendingPathComponent("large.bin"))

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        contents.withUnsafeBytes { rawBuffer in
            _ = CC_SHA256(rawBuffer.baseAddress, CC_LONG(rawBuffer.count), &digest)
        }
        let expected = digest.map { byte in
            String(format: "%02x", byte)
        }.joined()

        XCTAssertEqual(try makeBridge().sha256(path: "large.bin"), expected)
    }

    //
    // A missing file answers nil, the same as fsReadFile, which the shim turns into ENOENT.
    //
    func testSha256AnswersNilForAMissingFile() throws {
        XCTAssertNil(try makeBridge().sha256(path: "nothing-here.bin"))
    }

    //
    // Hashing goes through the same sandbox as every other path-taking host function, so a path
    // outside the storage root is refused rather than read.
    //
    func testSha256RefusesAPathOutsideTheSandbox() {
        XCTAssertThrowsError(try makeBridge().sha256(path: "../../etc/passwd"))
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
            queueTaskSink: { _, _, _, _, _, _ in }
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
            queueTaskSink: { _, _, _, _, _, _ in }
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
            queueTaskSink: { _, _, _, _, _, _ in }
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
            queueTaskSink: { parentTaskId, childTaskId, type, dataJson, source, priority in
                captured = [parentTaskId, childTaskId, type, dataJson, source, priority?.rawValue ?? "none"]
            }
        )
        bridge.currentTaskId = "parent-1"

        let context = JSContext()!
        bridge.install(into: context)
        context.evaluateScript("host.queueTask('child-1', 'childType', '{}', 'src', null)")

        // A null priority reaches the pool as nil, which is what makes the child run at its parent's.
        XCTAssertEqual(captured, ["parent-1", "child-1", "childType", "{}", "src", "none"])
    }

    //
    // A priority named by the handler crosses the bridge as itself, so a child can opt back down to
    // the background even when the task that queued it is interactive.
    //
    func testQueueTaskForwardsThePriorityTheHandlerNamed() {
        var captured: [String] = []

        let bridge = HostBridge(
            sessionId: "session-1",
            storageRoot: storageRoot,
            isCancelledProvider: { _ in false },
            messageSink: { _, _ in },
            queueTaskSink: { _, _, _, _, _, priority in
                captured = [priority?.rawValue ?? "none"]
            }
        )
        bridge.currentTaskId = "parent-1"

        let context = JSContext()!
        bridge.install(into: context)
        context.evaluateScript("host.queueTask('child-1', 'childType', '{}', 'src', 'background')")

        XCTAssertEqual(captured, ["background"])
    }

    //
    // A priority string that is not one of the two levels raises a JS exception rather than quietly
    // running the child in the background, so a typo is found rather than silently obeyed.
    //
    func testQueueTaskRejectsAnUnknownPriority() {
        var called = false

        let bridge = HostBridge(
            sessionId: "session-1",
            storageRoot: storageRoot,
            isCancelledProvider: { _ in false },
            messageSink: { _, _ in },
            queueTaskSink: { _, _, _, _, _, _ in called = true }
        )
        bridge.currentTaskId = "parent-1"

        let context = JSContext()!
        bridge.install(into: context)
        context.evaluateScript("host.queueTask('child-1', 'childType', '{}', 'src', 'urgent')")

        XCTAssertFalse(called)
        XCTAssertNotNil(context.exception)
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
            queueTaskSink: { _, _, _, _, _, _ in called = true }
        )

        let context = JSContext()!
        bridge.install(into: context)
        context.evaluateScript("host.queueTask('child-1', 'childType', '{}', 'src', null)")

        XCTAssertFalse(called)
    }
}
