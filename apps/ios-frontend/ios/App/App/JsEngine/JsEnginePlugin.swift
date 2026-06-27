import Foundation
import Capacitor

//
// The "JsEngine" Capacitor plugin: the native owner of the embedded-engine pool on iOS. It exposes
// addTask / cancelTasks / shutdown to the WebView and emits taskCompleted / taskMessage events back.
// It owns the EnginePool (which owns the pending queue, running-task map, cancelled set, and the
// single sessionId) and translates pool events into Capacitor notifyListeners calls. Events are
// buffered per-taskId while no JS listener is registered yet and flushed on first registration, so a
// task dispatched during startup never loses its completion or messages.
//
@objc(JsEnginePlugin)
public class JsEnginePlugin: CAPPlugin, EnginePoolDelegate {

    //
    // The engine pool. Created lazily on the first addTask so the pool (and its JSContexts) only
    // spin up when background work is actually dispatched.
    //
    private var pool: EnginePool?

    //
    // Guards the lazy pool creation and the event buffer / listener-registered flags, so the plugin's
    // own bookkeeping is safe even though pool events arrive from multiple engine threads.
    //
    private let lock = NSLock()

    //
    // True once at least one JS listener has registered for taskCompleted/taskMessage. Until then,
    // events are buffered and flushed when the first listener attaches.
    //
    private var hasListeners = false

    //
    // Buffered taskCompleted payloads, keyed by taskId, captured before any listener was registered.
    //
    private var bufferedCompletions: [String: [String: Any]] = [:]

    //
    // Buffered taskMessage payloads in arrival order, captured before any listener was registered.
    //
    private var bufferedMessages: [[String: Any]] = []

    //
    // Resolves the storage root the host functions are sandboxed to. Uses the app's Documents
    // directory, the writable sandbox location the storage plan targets on iOS. All task-supplied
    // paths are resolved relative to this root and may never escape it.
    //
    private func storageRoot() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return documents.first ?? FileManager.default.temporaryDirectory
    }

    //
    // Returns the existing pool or lazily creates one wired to the JavaScriptCore engine factory.
    // Each slot gets its own JavaScriptCoreTaskEngine and host bridge. Called under the lock.
    //
    private func ensurePool() -> EnginePool {
        if let existing = pool {
            return existing
        }

        let root = storageRoot()
        let createdPool = EnginePool(
            delegate: self,
            storageRoot: root,
            engineFactory: { slotIndex, hostBridge in
                return JavaScriptCoreTaskEngine(label: "photosphere.jsengine.slot.\(slotIndex)", hostBridge: hostBridge)
            }
        )
        pool = createdPool
        return createdPool
    }

    //
    // addTask: receives { taskId, type, data, source }. Serialises `data` (arbitrary JSON) to a JSON
    // string, enqueues the task, and resolves immediately. The result is delivered later via the
    // taskCompleted event, matching the fire-and-forget Electron path.
    //
    @objc func addTask(_ call: CAPPluginCall) {
        guard let taskId = call.getString("taskId") else {
            call.reject("addTask requires a taskId")
            return
        }
        guard let type = call.getString("type") else {
            call.reject("addTask requires a type")
            return
        }
        guard let source = call.getString("source") else {
            call.reject("addTask requires a source")
            return
        }

        // `data` is arbitrary JSON; serialise it to a string so it crosses into the engine unchanged.
        let dataJson = serializeData(call.getValue("data"))

        let task = PooledTask(taskId: taskId, type: type, dataJson: dataJson, source: source)

        lock.lock()
        let pool = ensurePool()
        lock.unlock()

        pool.addTask(task)
        call.resolve()
    }

    //
    // cancelTasks: receives { source }. Adds the source to the cancelled set and drops matching
    // pending tasks via the pool, then resolves. Running tasks observe the cancellation via
    // host.isCancelled.
    //
    @objc func cancelTasks(_ call: CAPPluginCall) {
        guard let source = call.getString("source") else {
            call.reject("cancelTasks requires a source")
            return
        }

        lock.lock()
        let currentPool = pool
        lock.unlock()

        currentPool?.cancelTasks(source: source)
        call.resolve()
    }

    //
    // shutdown: tears down the pool, disposes contexts, clears the plugin's buffered state, and
    // resolves. After shutdown a later addTask lazily creates a fresh pool.
    //
    @objc func shutdown(_ call: CAPPluginCall) {
        lock.lock()
        let currentPool = pool
        pool = nil
        bufferedCompletions.removeAll()
        bufferedMessages.removeAll()
        lock.unlock()

        currentPool?.shutdown()
        call.resolve()
    }

    //
    // Capacitor calls this when a JS listener registers. On the first listener, flush any buffered
    // taskCompleted/taskMessage events so events that fired during startup are still delivered.
    //
    @objc override public func addListener(_ call: CAPPluginCall) {

        // Let Capacitor register and retain the listener first, then flush any buffered events.
        super.addListener(call)
        flushBuffersIfNeeded()
    }

    //
    // Flushes buffered events to the WebView once a listener exists, and marks listeners present so
    // later events go straight through. Safe to call repeatedly; only the first call flushes.
    //
    private func flushBuffersIfNeeded() {
        lock.lock()
        if hasListeners {
            lock.unlock()
            return
        }
        hasListeners = true
        let completionsToFlush = Array(bufferedCompletions.values)
        let messagesToFlush = bufferedMessages
        bufferedCompletions.removeAll()
        bufferedMessages.removeAll()
        lock.unlock()

        for payload in completionsToFlush {
            notifyListeners("taskCompleted", data: payload)
        }
        for payload in messagesToFlush {
            notifyListeners("taskMessage", data: payload)
        }
    }

    //
    // Serialises an arbitrary `data` value from the bridge into a JSON string for the engine. Objects
    // and arrays are serialised with JSONSerialization; primitives are wrapped via a one-element
    // array so even a bare number/string/bool round-trips to valid JSON. A nil or unserialisable
    // value becomes the JSON literal "null".
    //
    private func serializeData(_ value: Any?) -> String {
        guard let value = value, !(value is NSNull) else {
            return "null"
        }

        if JSONSerialization.isValidJSONObject(value) {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: []),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "null"
        }

        // Primitives are not valid top-level JSON objects for JSONSerialization, so wrap, serialise,
        // and strip the wrapping brackets to recover the bare JSON value.
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let wrapped = String(data: data, encoding: .utf8),
           wrapped.hasPrefix("["), wrapped.hasSuffix("]") {
            return String(wrapped.dropFirst().dropLast())
        }

        return "null"
    }

    //
    // Parses a JSON string back into a Foundation value (Dictionary/Array/primitive) for inclusion in
    // an event payload, so the WebView receives structured `outputs`/`inputs`/`message` rather than a
    // raw string. Returns NSNull for "null" or unparseable input.
    //
    private func parseJson(_ json: String) -> Any {
        guard let data = json.data(using: .utf8) else {
            return NSNull()
        }
        if let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return parsed
        }
        return NSNull()
    }

    //
    // Emits a taskCompleted event, or buffers it per-taskId if no listener has registered yet. The
    // payload matches the TypeScript ITaskCompletedEvent: { taskId, result: { taskId, status,
    // errorMessage?, outputs?, type, inputs } }.
    //
    private func emitTaskCompleted(taskId: String, payload: [String: Any]) {
        lock.lock()
        if !hasListeners {
            bufferedCompletions[taskId] = payload
            lock.unlock()
            return
        }
        lock.unlock()

        notifyListeners("taskCompleted", data: payload)
    }

    //
    // Emits a taskMessage event, or buffers it in order if no listener has registered yet. The
    // payload matches the TypeScript ITaskMessageEvent: { taskId, message }.
    //
    private func emitTaskMessage(taskId: String, payload: [String: Any]) {
        lock.lock()
        if !hasListeners {
            bufferedMessages.append(payload)
            lock.unlock()
            return
        }
        lock.unlock()

        notifyListeners("taskMessage", data: payload)
    }

    // MARK: EnginePoolDelegate

    //
    // Pool reported success: build a "succeeded" ITaskCompletedResult (outputs parsed from JSON) and
    // emit it as a taskCompleted event.
    //
    func poolDidSucceed(_ task: PooledTask, outputsJson: String) {
        let result: [String: Any] = [
            "taskId": task.taskId,
            "status": "succeeded",
            "outputs": parseJson(outputsJson),
            "type": task.type,
            "inputs": parseJson(task.dataJson)
        ]
        emitTaskCompleted(taskId: task.taskId, payload: ["taskId": task.taskId, "result": result])
    }

    //
    // Pool reported failure (including NOT IMPLEMENTED): build a "failed" ITaskCompletedResult with
    // the errorMessage and emit it as a taskCompleted event.
    //
    func poolDidFail(_ task: PooledTask, errorMessage: String) {
        let result: [String: Any] = [
            "taskId": task.taskId,
            "status": "failed",
            "errorMessage": errorMessage,
            "type": task.type,
            "inputs": parseJson(task.dataJson)
        ]
        emitTaskCompleted(taskId: task.taskId, payload: ["taskId": task.taskId, "result": result])
    }

    //
    // Pool streamed a progress message: parse the raw JSON message and emit it as a taskMessage event.
    //
    func poolDidEmitMessage(_ task: PooledTask, messageJson: String) {
        emitTaskMessage(taskId: task.taskId, payload: ["taskId": task.taskId, "message": parseJson(messageJson)])
    }
}
