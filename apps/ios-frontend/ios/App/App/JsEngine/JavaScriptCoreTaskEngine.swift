import Foundation
import JavaScriptCore

//
// Upper bound (in real milliseconds) on how long the timer pump waits between firing virtual-clock
// timers. Pacing the pump by the virtual time a timer advanced keeps the virtual clock tracking real
// time (so a fast interval cannot race a real-time timeout guard ahead), while this cap keeps a
// newly-armed short timer from waiting a full long interval and bounds an idle long-running task's
// re-check latency.
//
// One millisecond, not the two hundred it was. This delay is paid whenever a timer is pending, and
// something almost always has one: the AWS SDK arms a request timeout around every call it makes,
// and the loop advances the task's promises a step at a time. Measured on the Android engine, whose
// loop works the same way, a file took nineteen seconds of which the upload was under two tenths of
// a second, and the rest was the loop parking between awaits.
let TIMER_PUMP_MAX_DELAY_MS = 1

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
    // False while the current task's promise is unsettled. The embedded engine has no real timer loop,
    // so the virtual-clock timers backing setTimeout/setInterval (install-globals.ts) only fire when
    // the native side calls globalThis.__pumpTimers. While a task is unsettled the engine pumps those
    // timers so setTimeout/sleep-based code makes progress (the import write-batch wait loop, retry
    // backoff, the asset-server cancellation poll); without it such code hangs forever. Only ever
    // read/written on engineQueue.
    //
    private var runningTaskSettled = true

    //
    // The monotonic time (uptime nanoseconds) the timer pump last ran. Each pump advances the engine's
    // virtual clock by the real time elapsed since this, so setTimeout/setInterval fire at real-time
    // rate and a large timeout guard never fires prematurely. Reset when a task starts. Only touched on
    // engineQueue.
    //
    private var lastPumpUptimeNs: UInt64 = 0

    //
    // True while a timer pump is already queued on the engine queue, so concurrent triggers (task
    // start, child events, TCP events) do not stack multiple pump chains. Only touched on engineQueue.
    //
    private var timerPumpScheduled = false

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

        // JSContext provides no setInterval/clearInterval natively. Inject both as no-ops here so
        // any timer code degrades to a no-op rather than throwing before the bundle evaluates; the
        // bundle itself (install-globals.ts) then overwrites both with real, idle-driven-queue
        // implementations, same as setTimeout/queueMicrotask.
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

        // The same drain-on-the-engine-queue wiring for the UDP and TLS layers: LAN-share discovery
        // (UDP) and its TLS server/client push inbound events that must be delivered into the JS shims on
        // the JSContext thread via globalThis.__udpEvent / globalThis.__tlsEvent.
        hostBridge.udp.onEventAvailable = { [weak self] in
            self?.engineQueue.async {
                self?.drainUdpEvents()
            }
        }
        hostBridge.tls.onEventAvailable = { [weak self] in
            self?.engineQueue.async {
                self?.drainTlsEvents()
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

            // Point the host bridge at the running task so host.queueTask knows which task is the
            // parent when the handler enqueues a child task.
            self.hostBridge.currentTaskId = task.taskId

            // Reset the per-task exception handler so an uncaught synchronous throw inside runTask is
            // captured and turned into a task failure rather than silently swallowed.
            var syncException: JSValue?
            context.exceptionHandler = { _, exception in
                syncException = exception
            }

            // Track whether a terminal callback has already fired so a settled promise reports once.
            var settled = false

            // The task's promise is now in flight; let the timer pump advance setTimeout/setInterval
            // until it settles. Reset the pump's real-time baseline so the first advance is measured from now.
            self.runningTaskSettled = false
            self.lastPumpUptimeNs = DispatchTime.now().uptimeNanoseconds

            // onFulfilled receives the resolved JSON string (the handler outputs) and reports success.
            let onFulfilled: @convention(block) (JSValue) -> Void = { resolved in
                if settled {
                    return
                }
                settled = true
                self.runningTaskSettled = true
                let outputsJson = resolved.isUndefined || resolved.isNull ? "null" : (resolved.toString() ?? "null")
                callbacks.onTaskSucceeded(task, outputsJson: outputsJson)
            }

            // onRejected receives the rejection reason and reports failure with its message text.
            let onRejected: @convention(block) (JSValue) -> Void = { reason in
                if settled {
                    return
                }
                settled = true
                self.runningTaskSettled = true
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
                    self.runningTaskSettled = true
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

                // The handler is now awaiting; start pumping its virtual-clock timers so setTimeout /
                // sleep based progress happens (the promise is otherwise driven only by microtasks and
                // native events).
                self.scheduleTimerPump()
            }
            else if !settled {
                // runTask should always return a promise; if it returned a plain value, treat it as the
                // resolved outputs so the task still completes rather than hanging.
                settled = true
                self.runningTaskSettled = true
                let outputsJson = promise?.toString() ?? "null"
                callbacks.onTaskSucceeded(task, outputsJson: outputsJson)
            }
        }
    }

    //
    // Advances the embedded engine's virtual-clock timers while the current task is unsettled. The
    // engine has no real timer loop, so setTimeout/setInterval callbacks are queued in JS and only run
    // when globalThis.__pumpTimers is invoked. This fires the earliest pending timer, lets JavaScriptCore
    // drain the microtasks it schedules, then re-queues itself until the task settles or no timer remains.
    //
    // The next pump is delayed by the virtual milliseconds the fired timer advanced (capped), so the
    // virtual clock roughly tracks real time. Without this a fast interval (e.g. a LAN-share 1s broadcast)
    // would fire back-to-back and race the virtual clock far ahead of real time, tripping a real-time
    // timeout guard (e.g. the 60s share timeout) seconds into a transfer that has not actually stalled.
    // The cap keeps a newly-armed timer from waiting a full long interval, and bounds how long an idle
    // long-running task waits before re-checking. Runs only on engineQueue, so the JSContext stays
    // single-threaded.
    //
    private func scheduleTimerPump(afterMs: Int = 0) {
        if timerPumpScheduled || runningTaskSettled || disposed {
            return
        }
        timerPumpScheduled = true

        let delay: DispatchTimeInterval = afterMs <= 0 ? .microseconds(0) : .milliseconds(afterMs)
        engineQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else {
                return
            }
            self.timerPumpScheduled = false
            if self.runningTaskSettled || self.disposed {
                return
            }
            guard let context = self.context else {
                return
            }

            // Advance the virtual clock by the real time elapsed since the last pump, firing every timer
            // that is now due (JavaScriptCore drains the microtasks each fired timer queues before the
            // evaluate returns). Bounding the advance to real elapsed time keeps the virtual clock from
            // racing ahead: a large timeout guard (a 90-minute retry timeout, a 60s share timeout) only
            // fires once that much real time has actually passed, never mid-operation.
            let now = DispatchTime.now().uptimeNanoseconds
            var budgetMs = Int((now &- self.lastPumpUptimeNs) / 1_000_000)
            self.lastPumpUptimeNs = now
            if budgetMs < 0 {
                budgetMs = 0
            }

            var nextTimerMs = -1
            while true {
                let fired = context.evaluateScript("(typeof globalThis.__pumpTimers === 'function') ? globalThis.__pumpTimers(\(budgetMs)) : false")
                if self.runningTaskSettled || self.disposed {
                    return
                }
                nextTimerMs = Int(context.objectForKeyedSubscript("__nextTimerMs")?.toInt32() ?? -1)
                if fired?.toBool() ?? false {
                    // A timer fired; it consumed part of the budget. Keep firing timers still due within
                    // the remaining budget.
                    let advanced = Int(context.objectForKeyedSubscript("__lastTimerAdvanceMs")?.toInt32() ?? 0)
                    budgetMs -= max(advanced, 0)
                    if budgetMs <= 0 {
                        break
                    }
                }
                else {
                    // Nothing was due within the budget (the clock advanced by the whole budget).
                    break
                }
            }

            // Schedule the next pump when the next timer is due (in real time), capped so a newly-armed
            // timer is still caught promptly and an idle long-running task re-checks at a bounded rate.
            let nextDelay = nextTimerMs >= 0 ? min(nextTimerMs, TIMER_PUMP_MAX_DELAY_MS) : TIMER_PUMP_MAX_DELAY_MS
            self.scheduleTimerPump(afterMs: nextDelay)
        }
    }

    //
    // Delivers a child-task event from the pool into this engine's context by invoking
    // globalThis.__childEvent on the engine queue, so an orchestrator handler awaiting its subtasks
    // resolves. JavaScriptCore is event-driven (it pumps the microtask queue after the call), so no
    // idle-timeout run loop is needed here, unlike the Android QuickJS engine. `terminal` is accepted
    // for protocol parity; iOS needs no outstanding-children liveness tracking.
    //
    func deliverChildEvent(_ eventJson: String, terminal: Bool) {
        engineQueue.async { [weak self] in
            guard let self = self, let context = self.context else {
                return
            }
            guard let childEventFunction = context.globalObject.objectForKeyedSubscript("__childEvent"), !childEventFunction.isUndefined else {
                return
            }
            childEventFunction.call(withArguments: [eventJson])

            // Delivering the event may have armed a timer or unblocked timer-driven code, so resume the
            // pump (a no-op if one is already queued or the task has settled).
            self.scheduleTimerPump()
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

        // Handling a request may have armed a timer or unblocked timer-driven code, so resume the pump.
        self.scheduleTimerPump()
    }

    //
    // Drains the native UDP inbound event queue, delivering each event JSON into the JS dgram shim via
    // globalThis.__udpEvent. Runs on the engine queue (dispatched from the UdpHost callback), so the
    // JSContext is only ever touched from its owning thread.
    //
    private func drainUdpEvents() {
        guard let context = self.context else {
            return
        }
        guard let udpEventFunction = context.globalObject.objectForKeyedSubscript("__udpEvent"), !udpEventFunction.isUndefined else {
            return
        }
        while let eventJson = self.hostBridge.udp.pollInboundEvent() {
            udpEventFunction.call(withArguments: [eventJson])
        }
        self.scheduleTimerPump()
    }

    //
    // Drains the native TLS inbound event queue, delivering each event JSON into the JS tls shim via
    // globalThis.__tlsEvent. Runs on the engine queue (dispatched from the TlsHost callback), so the
    // JSContext is only ever touched from its owning thread.
    //
    private func drainTlsEvents() {
        guard let context = self.context else {
            return
        }
        guard let tlsEventFunction = context.globalObject.objectForKeyedSubscript("__tlsEvent"), !tlsEventFunction.isUndefined else {
            return
        }
        while let eventJson = self.hostBridge.tls.pollInboundEvent() {
            tlsEventFunction.call(withArguments: [eventJson])
        }
        self.scheduleTimerPump()
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
