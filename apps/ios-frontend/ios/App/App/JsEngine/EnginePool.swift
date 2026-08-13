import Foundation

//
// The single source of truth for the engine pool size. A size of 1 degrades the pool to serial
// execution and is a supported, tested configuration. Nothing else in the plugin reads or writes
// pool size; if a runtime/tunable source is wanted later it replaces this constant. Keep it in step
// with POOL_SIZE in the Android EnginePool.java.
//
// Five, because that is what the deepest chain of tasks needs plus one to spare. Automatic import is
// the deepest: the asset server holds a slot for the life of the app, auto-import holds one for as
// long as the setting is on, the import-assets task it queues holds a third, and the hash-file and
// upload-asset tasks that import queues in turn need a fourth. At four that chain fits exactly and
// nothing else can run beside it, so a sync waits and only one file is hashed at a time. The fifth
// is that headroom.
//
// A task that waits on a task it queued must never be able to use the last free slot, because both
// then wait forever and it looks from outside exactly like a slow import: the setting is on, the
// task is running, and the counts stay at zero. That is not theoretical; it is what this pool did at
// three.
//
let POOL_SIZE = 5

//
// A pool slot pairing one engine with its busy/idle state. The dispatcher assigns the next pending
// task to the first idle slot and marks it busy until that task's terminal callback fires.
//
private final class EngineSlot {

    //
    // The engine that runs tasks for this slot. Each slot owns exactly one engine/JSContext on its
    // own thread.
    //
    let engine: TaskEngine

    //
    // The task currently running on this slot, or nil when the slot is idle. Used both as the
    // busy flag and to map a completion back to its slot.
    //
    var runningTask: PooledTask?

    //
    // Constructs a slot wrapping one engine, initially idle.
    //
    init(engine: TaskEngine) {
        self.engine = engine
        self.runningTask = nil
    }
}

//
// Reports completion and streamed messages from the pool back to the plugin (or to a test). The
// pool itself stays free of Capacitor: the plugin implements this to turn pool events into
// notifyListeners calls, and tests implement it to capture events deterministically.
//
protocol EnginePoolDelegate: AnyObject {

    //
    // Called when a task finishes successfully. `outputsJson` is the handler's JSON outputs.
    //
    func poolDidSucceed(_ task: PooledTask, outputsJson: String)

    //
    // Called when a task fails. `errorMessage` is the failure text (including NOT IMPLEMENTED).
    //
    func poolDidFail(_ task: PooledTask, errorMessage: String)

    //
    // Called when a running task streams a progress message. `messageJson` is the raw JSON string.
    //
    func poolDidEmitMessage(_ task: PooledTask, messageJson: String)
}

//
// The engine pool and dispatcher. Holds N engine slots (POOL_SIZE), a shared pending-task FIFO, a
// running-task map (via the slots), a cancelled-source set, and the single owned sessionId. All
// shared state is guarded by one lock except the cancelled set, which is also mirrored into an
// atomic-style flag read lock-free by host.isCancelled from inside running tasks. The dispatcher
// assigns the next pending task to any idle slot and reassigns when a slot frees, giving true
// parallelism up to POOL_SIZE. Modelled on the desktop worker pools (idle/ready slot tracking,
// FIFO dispatch, per-engine lifecycle). The engine factory is injected so tests can supply stub
// engines with no JSContext.
//
final class EnginePool: EngineCallbacks {

    //
    // The single session id generated once at pool init and shared across every engine and task, so
    // the node-api write locks keyed on it stay consistent for the whole pool.
    //
    let sessionId: String

    //
    // The lock guarding the pending FIFO, the slots/running-task map, and the cancelled-source set.
    // Held only briefly; never held while calling into an engine or the delegate.
    //
    private let lock = NSLock()

    //
    // The pending-task FIFO. New tasks append to the end; the dispatcher pulls from the front.
    //
    private var pending: [PooledTask] = []

    //
    // The engine slots, one per pool position. Indexed only under the lock.
    //
    private var slots: [EngineSlot] = []

    //
    // The set of cancelled sources. cancelTasks adds to it; the dispatcher and running tasks consult
    // it. Mutated only under the lock.
    //
    private var cancelledSources: Set<String> = []

    //
    // Map of child taskId -> the engine that spawned it. A child task's outcome is routed back to its
    // origin engine (so an orchestrator handler awaiting it resolves) instead of to the WebView
    // delegate. Root tasks queued from the WebView are absent and keep going to the delegate. Mutated
    // only under the lock. Mirrors the Android EnginePool.childOriginByTaskId.
    //
    private var childOriginByTaskId: [String: TaskEngine] = [:]

    //
    // True once shutdown has begun. After this no new tasks are accepted or dispatched.
    //
    private var shuttingDown = false

    //
    // The delegate that turns pool events into plugin notifications (or captures them in tests).
    //
    private weak var delegate: EnginePoolDelegate?

    //
    // Constructs the pool: generates the shared sessionId and builds POOL_SIZE slots using the
    // injected engine factory. The factory receives a per-slot host bridge wired to this pool's
    // cancellation read and message sink, so every engine shares the pool's sessionId and routes
    // host calls back here. `poolSize` defaults to POOL_SIZE and is overridable for the size-1 test.
    //
    init(delegate: EnginePoolDelegate,
         storageRoot: URL,
         poolSize: Int = POOL_SIZE,
         engineFactory: (Int, HostBridge) -> TaskEngine) {
        self.sessionId = UUID().uuidString
        self.delegate = delegate

        for slotIndex in 0..<poolSize {
            let hostBridge = HostBridge(
                sessionId: sessionId,
                storageRoot: storageRoot,
                isCancelledProvider: { [weak self] taskId in
                    return self?.isCancelled(taskId: taskId) ?? false
                },
                messageSink: { [weak self] taskId, messageJson in
                    self?.handleSendMessage(taskId: taskId, messageJson: messageJson)
                },
                queueTaskSink: { [weak self] parentTaskId, childTaskId, type, dataJson, source in
                    self?.queueChildTask(
                        parentTaskId: parentTaskId,
                        child: PooledTask(taskId: childTaskId, type: type, dataJson: dataJson, source: source)
                    )
                }
            )
            let engine = engineFactory(slotIndex, hostBridge)
            slots.append(EngineSlot(engine: engine))
        }
    }

    //
    // Enqueues a task and kicks the dispatcher. Fire-and-forget: the task runs when an idle slot is
    // available.
    //
    func addTask(_ task: PooledTask) {
        lock.lock()
        if shuttingDown {
            lock.unlock()
            return
        }

        // Re-arm the source. Cancelling a source cancels the work in flight at that moment and
        // nothing more; it must not disable the source for future work. A task arriving here is a
        // fresh, deliberate request from the WebView, not a straggler of the cancelled batch, so it
        // clears the cancellation rather than being dropped by it.
        //
        // queueChildTask deliberately does NOT do this, and the asymmetry is the point: children are
        // spawned from inside a running handler, so a batch being cancelled right now can still be
        // producing them and they must still be dropped. Clearing in both places would break
        // cancellation outright.
        //
        // Without this, cancelling a source poisoned it for the life of the app: every later task
        // under that name was discarded before dispatch, with nothing rejected and nothing logged. A
        // second replication of the same database, or a second browse of an S3 bucket, simply did
        // nothing.
        cancelledSources.remove(task.source)

        pending.append(task)
        lock.unlock()

        dispatch()
    }

    //
    // Enqueues a child task spawned by a running handler and kicks the dispatcher, tagging it with the
    // origin engine (the slot running the parent) so the child's outcome routes back to that engine.
    // Mirrors the Android EnginePool.queueChildTask and the Electron main process handling a worker's
    // "queue-task" message. A child whose parent is no longer running, or whose source was already
    // cancelled, is dropped.
    //
    func queueChildTask(parentTaskId: String, child: PooledTask) {
        lock.lock()
        if shuttingDown {
            lock.unlock()
            return
        }
        // Kept, unlike addTask, which clears the source instead. A child comes from a handler that is
        // already running, so a batch being cancelled right now can still be producing children and
        // they must be dropped. This check is the reason the set exists.
        if cancelledSources.contains(child.source) {
            lock.unlock()
            return
        }

        var origin: TaskEngine?
        for slot in slots {
            if let running = slot.runningTask, running.taskId == parentTaskId {
                origin = slot.engine
                break
            }
        }
        guard let originEngine = origin else {
            // The parent already finished; there is nothing to deliver the child's result to.
            lock.unlock()
            return
        }

        childOriginByTaskId[child.taskId] = originEngine
        pending.append(child)
        lock.unlock()

        dispatch()
    }

    //
    // Cancels every task that shares the given source: adds the source to the cancelled set (so
    // host.isCancelled observes it for running tasks), drops all matching pending tasks from the
    // FIFO so they never dispatch, and forgets any child-origin mappings for those dropped tasks.
    //
    func cancelTasks(source: String) {
        lock.lock()
        cancelledSources.insert(source)
        pending.removeAll { task in
            if task.source == source {
                childOriginByTaskId.removeValue(forKey: task.taskId)
                return true
            }
            return false
        }
        lock.unlock()
    }

    //
    // Returns true if the running task's source has been cancelled. Reads the cancelled set under the
    // lock; the read is short and never re-enters the engine. Running handlers poll this through
    // host.isCancelled to stop promptly after a cancelTasks for their source.
    //
    func isCancelled(taskId: String) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        // Find the running task with this id and test whether its source is cancelled.
        for slot in slots {
            if let running = slot.runningTask, running.taskId == taskId {
                return cancelledSources.contains(running.source)
            }
        }

        // Unknown task ids are treated as not cancelled (it may have already completed).
        return false
    }

    //
    // The dispatcher: assigns pending tasks to idle slots up to the concurrency cap. Pulls the next
    // pending task that is not from a cancelled source and starts it on the first idle slot. Loops so
    // multiple idle slots fill in one pass, giving true parallelism up to POOL_SIZE. Called whenever
    // work is added or a slot frees.
    //
    private func dispatch() {
        while true {
            lock.lock()

            if shuttingDown {
                lock.unlock()
                return
            }

            // Find the first idle slot; stop if every engine is busy (concurrency cap reached).
            guard let idleSlot = slots.first(where: { slot in slot.runningTask == nil }) else {
                lock.unlock()
                return
            }

            // Pull the next pending task whose source is not cancelled, dropping cancelled ones.
            var nextTask: PooledTask?
            while !pending.isEmpty {
                let candidate = pending.removeFirst()
                if cancelledSources.contains(candidate.source) {
                    continue
                }
                nextTask = candidate
                break
            }

            guard let task = nextTask else {
                lock.unlock()
                return
            }

            // Mark the slot busy under the lock, then run outside the lock.
            idleSlot.runningTask = task
            let engine = idleSlot.engine
            lock.unlock()

            engine.runTask(task, callbacks: self)
        }
    }

    //
    // Frees the slot running the given task id (back to idle) so the dispatcher can reuse it. Called
    // from the terminal callbacks once a task settles.
    //
    private func freeSlot(for taskId: String) {
        lock.lock()
        for slot in slots {
            if let running = slot.runningTask, running.taskId == taskId {
                slot.runningTask = nil
                break
            }
        }
        lock.unlock()
    }

    //
    // Routes a streamed message from a running task to the delegate. Looks up the task by id so the
    // delegate receives the full PooledTask. The lookup is a short locked read and does not call back
    // into the engine.
    //
    private func handleSendMessage(taskId: String, messageJson: String) {
        lock.lock()
        var matched: PooledTask?
        for slot in slots {
            if let running = slot.runningTask, running.taskId == taskId {
                matched = running
                break
            }
        }
        lock.unlock()

        // Task messages (root AND child) go to the WebView delegate, matching Electron: the UI
        // consumes messages like import-pending (sent by the upload-asset subtask) and import-success
        // (sent by the import-assets root task). Only child COMPLETIONS route to the origin engine.
        if let task = matched {
            delegate?.poolDidEmitMessage(task, messageJson: messageJson)
        }
    }

    //
    // Tears down the pool: stops the dispatcher, drains the pending FIFO, disposes every engine, and
    // clears all shared state. Running engines observe shutdown via their own teardown; their late
    // terminal callbacks are ignored because the slots are cleared. Idempotent.
    //
    func shutdown() {
        lock.lock()
        if shuttingDown {
            lock.unlock()
            return
        }
        shuttingDown = true
        pending.removeAll()
        let enginesToDispose = slots.map { slot in slot.engine }
        for slot in slots {
            slot.runningTask = nil
        }
        cancelledSources.removeAll()
        childOriginByTaskId.removeAll()
        lock.unlock()

        for engine in enginesToDispose {
            engine.dispose()
        }
    }

    // MARK: EngineCallbacks

    //
    // Engine reported success: free the slot, forward the outputs to the delegate, then re-run the
    // dispatcher to fill the now-idle slot.
    //
    func onTaskSucceeded(_ task: PooledTask, outputsJson: String) {
        lock.lock()
        let origin = childOriginByTaskId.removeValue(forKey: task.taskId)
        lock.unlock()

        freeSlot(for: task.taskId)

        if let origin = origin {
            origin.deliverChildEvent(EnginePool.buildChildCompletedEvent(task: task, succeeded: true, errorMessage: nil, outputsJson: outputsJson), terminal: true)
        }
        else {
            delegate?.poolDidSucceed(task, outputsJson: outputsJson)
        }

        dispatch()
    }

    //
    // Engine reported failure (including NOT IMPLEMENTED): free the slot, route the message to the
    // origin engine (child) or the delegate (root), then re-run the dispatcher.
    //
    func onTaskFailed(_ task: PooledTask, errorMessage: String) {
        lock.lock()
        let origin = childOriginByTaskId.removeValue(forKey: task.taskId)
        lock.unlock()

        freeSlot(for: task.taskId)

        if let origin = origin {
            origin.deliverChildEvent(EnginePool.buildChildCompletedEvent(task: task, succeeded: false, errorMessage: errorMessage, outputsJson: nil), terminal: true)
        }
        else {
            delegate?.poolDidFail(task, errorMessage: errorMessage)
        }

        dispatch()
    }

    //
    // Engine streamed a progress message via EngineCallbacks (unused on iOS, where messages flow
    // through the host bridge messageSink instead): route to the WebView delegate for both root and
    // child tasks, matching Electron and handleSendMessage. The slot stays busy.
    //
    func onTaskMessage(_ task: PooledTask, messageJson: String) {
        delegate?.poolDidEmitMessage(task, messageJson: messageJson)
    }

    // MARK: Child-event JSON builders

    //
    // Builds the JSON for a child completion event delivered into the origin engine's
    // globalThis.__childEvent. The already-valid JSON fragments (the child's inputs and outputs) are
    // embedded raw; plain string fields are escaped. Mirrors the Android EnginePool.buildChildCompletedEvent.
    //
    private static func buildChildCompletedEvent(task: PooledTask, succeeded: Bool, errorMessage: String?, outputsJson: String?) -> String {
        var builder = "{\"kind\":\"completed\",\"result\":{"
        builder += "\"taskId\":\"" + HostBridge.jsonEscape(task.taskId) + "\","
        builder += "\"status\":\"" + (succeeded ? "succeeded" : "failed") + "\","
        builder += "\"type\":\"" + HostBridge.jsonEscape(task.type) + "\","
        builder += "\"inputs\":" + (task.dataJson.isEmpty ? "null" : task.dataJson)

        if succeeded {
            let outputs = (outputsJson == nil || outputsJson!.isEmpty) ? "null" : outputsJson!
            builder += ",\"outputs\":" + outputs
        }
        else {
            builder += ",\"errorMessage\":\"" + HostBridge.jsonEscape(errorMessage ?? "Unknown error") + "\""
        }

        builder += "}}"
        return builder
    }

}
