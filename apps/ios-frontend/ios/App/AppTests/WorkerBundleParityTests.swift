import XCTest
import JavaScriptCore
@testable import App

//
// JavaScriptCore parity-style test mirroring the QuickJS parity smoke: load worker.bundle.js into a
// JSContext, assert __photosphereWorker.runTask exists, and assert an unknown task type rejects with
// the "No handler registered for task type" error that lists the real handlers. The worker bundle is
// an app resource; whether it is reachable from the test target depends on its target membership, so
// every test skips gracefully (via XCTSkip) when the resource cannot be loaded rather than failing.
//
final class WorkerBundleParityTests: XCTestCase {

    //
    // Locates the worker bundle in the bundles visible to the test target. Tries the test bundle and
    // the main bundle, and both resource-name spellings, so the test works regardless of how the
    // resource was added. Returns nil when the resource is not reachable from the test target.
    //
    private func locateWorkerBundle() -> String? {
        let candidateBundles = [Bundle(for: WorkerBundleParityTests.self), Bundle.main]
        for bundle in candidateBundles {
            if let fullName = bundle.path(forResource: "worker.bundle.js", ofType: nil) {
                return fullName
            }
            if let splitName = bundle.path(forResource: "worker", ofType: "bundle.js") {
                return splitName
            }
        }
        return nil
    }

    //
    // Builds a JSContext, injects the setInterval/clearInterval no-ops the engine adds, installs a
    // minimal host, and evaluates the bundle. Throws XCTSkip when the bundle resource is unavailable.
    //
    private func makeLoadedContext() throws -> JSContext {
        guard let bundlePath = locateWorkerBundle() else {
            throw XCTSkip("worker.bundle.js is not a member of the test target; skipping parity test.")
        }

        let source = try String(contentsOfFile: bundlePath, encoding: .utf8)
        let context = JSContext()!

        // Match the engine: inject setInterval/clearInterval as no-ops before evaluating the bundle.
        let noopInterval: @convention(block) () -> JSValue = { JSValue(double: 0, in: context) }
        let noopClear: @convention(block) () -> Void = { }
        context.globalObject.setValue(JSValue(object: noopInterval, in: context), forProperty: "setInterval")
        context.globalObject.setValue(JSValue(object: noopClear, in: context), forProperty: "clearInterval")

        // Install a minimal host so runTask can build its context; these handlers do not need it.
        let bridge = HostBridge(
            sessionId: "parity-session",
            storageRoot: FileManager.default.temporaryDirectory,
            isCancelledProvider: { _ in false },
            messageSink: { _, _ in }
        )
        bridge.install(into: context)

        var thrown: JSValue?
        context.exceptionHandler = { _, exception in thrown = exception }
        context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: bundlePath))
        if let exception = thrown {
            XCTFail("evaluating worker.bundle.js threw: \(exception.toString() ?? "unknown")")
        }

        return context
    }

    //
    // The bundle must expose __photosphereWorker.runTask as a function after evaluation.
    //
    func testWorkerApiExists() throws {
        let context = try makeLoadedContext()
        let runTaskType = context.evaluateScript("typeof globalThis.__photosphereWorker.runTask")
        XCTAssertEqual(runTaskType?.toString(), "function")
    }

    //
    // Dispatching an unknown task type must reject with the registered-handlers error that lists real
    // handlers, proving the bundle's handlers registered. Drives the JS promise and waits for it to
    // settle by polling a JS-stored result.
    //
    func testUnknownTaskTypeRejectsWithHandlerList() throws {
        let context = try makeLoadedContext()

        // Store the settled outcome on a global the test can poll once the microtask queue drains.
        context.evaluateScript("globalThis.__parityResult = undefined;")
        context.evaluateScript("""
            globalThis.__photosphereWorker.runTask('t1', 'no-such-handler', '{}')
                .then(function (value) { globalThis.__parityResult = { ok: true, value: value }; })
                .catch(function (error) { globalThis.__parityResult = { ok: false, error: String(error && error.message ? error.message : error) }; });
        """)

        // JavaScriptCore drains the microtask queue synchronously, but spin the run loop briefly in
        // case any timer-backed continuation is involved before reading the stored result.
        let deadline = Date().addingTimeInterval(2.0)
        while context.objectForKeyedSubscript("__parityResult")?.isUndefined != false && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        let result = context.objectForKeyedSubscript("__parityResult")
        XCTAssertFalse(result?.isUndefined ?? true, "runTask promise did not settle")
        XCTAssertEqual(result?.objectForKeyedSubscript("ok")?.toBool(), false, "unknown handler should reject")

        let errorText = result?.objectForKeyedSubscript("error")?.toString() ?? ""
        XCTAssertTrue(errorText.contains("No handler registered for task type: no-such-handler"), "got: \(errorText)")
        XCTAssertTrue(errorText.contains("hello-world"), "registered handler list should include hello-world; got: \(errorText)")
    }
}
