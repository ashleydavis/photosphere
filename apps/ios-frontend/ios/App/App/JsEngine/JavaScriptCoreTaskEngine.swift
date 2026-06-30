import Foundation
import JavaScriptCore

//
// Errors raised while standing up or running a JavaScriptCore engine. These become the task's
// "failed" result message when they occur before or during a task.
//
enum JavaScriptCoreEngineError: Error, CustomStringConvertible {

    //
    // The bundled worker resource could not be located in the app bundle.
    //
    case bundleNotFound

    //
    // The worker bundle could not be read from disk.
    //
    case bundleUnreadable(String)

    //
    // Evaluating the worker bundle raised a JS exception (a syntax or bootstrap failure).
    //
    case bundleEvaluationFailed(String)

    //
    // The bundle did not expose `globalThis.__photosphereWorker.runTask` after evaluation.
    //
    case workerApiMissing

    //
    // A human-readable description used as the task's error message.
    //
    var description: String {
        switch self {
        case .bundleNotFound:
            return "JsEngine: worker.bundle.js was not found in the app bundle."
        case .bundleUnreadable(let detail):
            return "JsEngine: failed to read worker.bundle.js: \(detail)"
        case .bundleEvaluationFailed(let detail):
            return "JsEngine: evaluating worker.bundle.js failed: \(detail)"
        case .workerApiMissing:
            return "JsEngine: globalThis.__photosphereWorker.runTask is missing after evaluating the bundle."
        }
    }
}

//
// The real TaskEngine: owns one JSContext that has evaluated worker.bundle.js, installs the host
// bridge, and dispatches tasks to `__photosphereWorker.runTask`. One instance lives per pool slot
// and runs every task on its own serial DispatchQueue, since a JSContext must not be shared across
// threads. The engine awaits the JS promise returned by runTask via JS `.then`/`.catch` callbacks
// driven from Swift; JavaScriptCore pumps the microtask queue automatically on the context's thread.
//
final class JavaScriptCoreTaskEngine: TaskEngine {

    //
    // The serial queue this engine runs on. Owning a single serial queue guarantees the JSContext
    // is only ever touched from one thread, satisfying JavaScriptCore's threading requirement.
    //
    private let engineQueue: DispatchQueue

    //
    // The host bridge installed as `globalThis.host` in this engine's context. Held so the same
    // instance services synchronous host calls for the whole engine lifetime.
    //
    private let hostBridge: HostBridge

    //
    // The JavaScriptCore context that has evaluated the worker bundle. Created lazily on the engine
    // queue on first task so all JSContext access stays on that one thread.
    //
    private var context: JSContext?

    //
    // True once the engine has been disposed. After disposal the engine must not run further tasks.
    //
    private var disposed = false

    //
    // Constructs an engine for one pool slot. `label` names the engine's serial queue; `hostBridge`
    // is the host installed into its context.
    //
    init(label: String, hostBridge: HostBridge) {
        self.engineQueue = DispatchQueue(label: label)
        self.hostBridge = hostBridge
    }

    //
    // Locates the worker bundle in the app bundle. The resource ships as `worker.bundle.js`, which
    // some Xcode resource configurations expose under the full name and others split into a base name
    // plus an extension. Both spellings are tried so the lookup works regardless of how the file was
    // added to the target.
    //
    private func locateWorkerBundle() -> String? {

        // Preferred: the resource added with its full name and no separate extension.
        if let fullName = Bundle.main.path(forResource: "worker.bundle.js", ofType: nil) {
            return fullName
        }

        // Fallback: the resource split into base name "worker" with extension "bundle.js".
        if let splitName = Bundle.main.path(forResource: "worker", ofType: "bundle.js") {
            return splitName
        }

        return nil
    }

    //
    // Creates the JSContext, injects the two no-op interval shims the bundle does not install,
    // evaluates the worker bundle, and verifies the worker API is present. Runs on the engine queue.
    // Throws a JavaScriptCoreEngineError if the bundle is missing, unreadable, fails to evaluate, or
    // does not expose the worker API.
    //
    private func makeContext() throws -> JSContext {
        guard let bundlePath = locateWorkerBundle() else {
            throw JavaScriptCoreEngineError.bundleNotFound
        }

        let source: String
        do {
            source = try String(contentsOfFile: bundlePath, encoding: .utf8)
        }
        catch {
            throw JavaScriptCoreEngineError.bundleUnreadable("\(error)")
        }

        let newContext = JSContext()!

        // JSContext provides no setInterval/clearInterval and the bundle does not install them.
        // Inject both as no-ops before evaluating the bundle so any timer code degrades to a no-op
        // rather than throwing. setTimeout/queueMicrotask are installed by the bundle itself.
        let noopInterval: @convention(block) () -> JSValue = {
            return JSValue(double: 0, in: newContext)
        }
        let noopClearInterval: @convention(block) () -> Void = {
        }
        newContext.globalObject.setValue(JSValue(object: noopInterval, in: newContext), forProperty: "setInterval")
        newContext.globalObject.setValue(JSValue(object: noopClearInterval, in: newContext), forProperty: "clearInterval")

        // Install the host bridge before evaluating the bundle so any top-level host access during
        // bootstrap (and certainly runTask later) sees `globalThis.host`.
        hostBridge.install(into: newContext)

        // When the native TCP layer enqueues an inbound event (connection / data / close), drain and
        // deliver it on the engine queue so the JSContext is only ever touched from its owning thread.
        hostBridge.tcp.onEventAvailable = { [weak self] in
            self?.engineQueue.async {
                self?.drainTcpEvents()
            }
        }

        var evaluationException: JSValue?
        newContext.exceptionHandler = { _, exception in
            evaluationException = exception
        }

        newContext.evaluateScript(source, withSourceURL: URL(fileURLWithPath: bundlePath))

        if let exception = evaluationException {
            throw JavaScriptCoreEngineError.bundleEvaluationFailed(exception.toString() ?? "unknown error")
        }

        // Confirm the bundle exposed the worker API; without it runTask cannot be called.
        let worker = newContext.globalObject.objectForKeyedSubscript("__photosphereWorker")
        let runTask = worker?.objectForKeyedSubscript("runTask")
        if worker == nil || worker!.isUndefined || runTask == nil || runTask!.isUndefined {
            throw JavaScriptCoreEngineError.workerApiMissing
        }

        return newContext
    }

    //
    // Runs a single task on the engine queue: lazily creates the context on first use, calls
    // `__photosphereWorker.runTask(taskId, type, dataJson)`, and awaits the returned JS promise via
    // Swift-installed resolve/reject callbacks. On resolve the outputs JSON is reported through
    // onTaskSucceeded; on reject (including the NOT IMPLEMENTED case) the message is reported through
    // onTaskFailed. Exactly one terminal callback fires per task.
    //
    func runTask(_ task: PooledTask, callbacks: EngineCallbacks) {
        engineQueue.async { [weak self] in
            guard let self = self else {
                return
            }

            if self.disposed {
                callbacks.onTaskFailed(task, errorMessage: "JsEngine: engine was disposed before the task ran.")
                return
            }

            // Stand up the context on first use; a bootstrap failure fails the task loudly.
            if self.context == nil {
                do {
                    self.context = try self.makeContext()
                }
                catch {
                    callbacks.onTaskFailed(task, errorMessage: "\(error)")
                    return
                }
            }

            guard let context = self.context else {
                callbacks.onTaskFailed(task, errorMessage: "JsEngine: engine context is unavailable.")
                return
            }

            // Reset the per-task exception handler so an uncaught synchronous throw inside runTask is
            // captured and turned into a task failure rather than silently swallowed.
            var syncException: JSValue?
            context.exceptionHandler = { _, exception in
                syncException = exception
            }

            // Track whether a terminal callback has already fired so a settled promise reports once.
            var settled = false

            // onFulfilled receives the resolved JSON string (the handler outputs) and reports success.
            let onFulfilled: @convention(block) (JSValue) -> Void = { resolved in
                if settled {
                    return
                }
                settled = true
                let outputsJson = resolved.isUndefined || resolved.isNull ? "null" : (resolved.toString() ?? "null")
                callbacks.onTaskSucceeded(task, outputsJson: outputsJson)
            }

            // onRejected receives the rejection reason and reports failure with its message text.
            let onRejected: @convention(block) (JSValue) -> Void = { reason in
                if settled {
                    return
                }
                settled = true
                let message = self.errorMessage(from: reason)
                NSLog("%@", message)
                callbacks.onTaskFailed(task, errorMessage: message)
            }

            let fulfilledValue = JSValue(object: onFulfilled, in: context)!
            let rejectedValue = JSValue(object: onRejected, in: context)!

            let worker = context.globalObject.objectForKeyedSubscript("__photosphereWorker")!
            let promise = worker.invokeMethod("runTask", withArguments: [task.taskId, task.type, task.dataJson])

            // A synchronous throw from runTask (before it returns a promise) fails the task here.
            if let exception = syncException {
                if !settled {
                    settled = true
                    let message = self.errorMessage(from: exception)
                    NSLog("%@", message)
                    callbacks.onTaskFailed(task, errorMessage: message)
                }
                return
            }

            // Attach the Swift callbacks to the returned promise. JavaScriptCore drains the microtask
            // queue on this thread, so the settle callback fires once the handler promise resolves.
            if let promise = promise, promise.hasProperty("then") {
                promise.invokeMethod("then", withArguments: [fulfilledValue, rejectedValue])
            }
            else if !settled {
                // runTask should always return a promise; if it returned a plain value, treat it as the
                // resolved outputs so the task still completes rather than hanging.
                settled = true
                let outputsJson = promise?.toString() ?? "null"
                callbacks.onTaskSucceeded(task, outputsJson: outputsJson)
            }
        }
    }

    //
    // Drains the native TCP inbound event queue, delivering each event JSON into the JS net shim by
    // invoking globalThis.__tcpEvent. Runs on the engine queue (dispatched from the TcpHost callback),
    // so the JSContext is only ever touched from its owning thread. JavaScriptCore drains the microtask
    // queue after each call returns, so the express response kicked off by a delivered request completes.
    //
    private func drainTcpEvents() {
        guard let context = self.context else {
            return
        }
        guard let tcpEventFunction = context.globalObject.objectForKeyedSubscript("__tcpEvent"), !tcpEventFunction.isUndefined else {
            return
        }
        while let eventJson = self.hostBridge.tcp.pollInboundEvent() {
            tcpEventFunction.call(withArguments: [eventJson])
        }
    }

    //
    // Extracts a human-readable message from a JS error or rejection reason. Prefers the error's
    // `.message` property (so the verbatim NOT IMPLEMENTED text is preserved) and falls back to the
    // value's string form.
    //
    private func errorMessage(from value: JSValue) -> String {
        if value.isObject, let messageValue = value.objectForKeyedSubscript("message"), !messageValue.isUndefined, !messageValue.isNull {
            return messageValue.toString() ?? "Unknown error"
        }
        return value.toString() ?? "Unknown error"
    }

    //
    // Disposes the engine: marks it disposed and releases the JSContext on the engine queue so the
    // teardown happens on the same thread that created and used the context. Called once during pool
    // shutdown; after this the engine must not be reused.
    //
    func dispose() {
        hostBridge.tcp.shutdown()
        engineQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            self.disposed = true
            self.context = nil
        }
    }
}
