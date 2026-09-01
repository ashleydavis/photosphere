import Foundation
import Capacitor
import BackgroundTasks
import PhotosUI
import UIKit
import UniformTypeIdentifiers

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
    // The in-flight pickFiles call awaiting the photo picker's result. Held so the PHPicker delegate
    // can resolve it once the user finishes picking. Only one pick runs at a time.
    //
    private var pendingPickCall: CAPPluginCall?

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
    // The source tag the background import queues its tasks under, so they can be cancelled as a
    // group when automatic import is switched off. Matches AUTO_IMPORT_TASK_SOURCE in
    // packages/api/src/lib/auto-import-mobile.ts.
    //
    static let autoImportTaskSource = "auto-import"

    //
    // The task type that says what a background import pass should do.
    //
    private static let planAutoImportTask = "plan-auto-import"

    //
    // The source tag the background sync queues its tasks under.
    //
    // Its own tag rather than the import's, so stopping one does not cancel the other: tasks are
    // cancelled by source, and a sync cancelled because an import was switched off would be a sync
    // that stopped for no reason the user could see. Matches BACKGROUND_SYNC_TASK_SOURCE in
    // JsEnginePlugin.java.
    //
    static let backgroundSyncTaskSource = "background-sync"

    //
    // The task type that says whether a background sync pass should run.
    //
    private static let planSyncTask = "plan-sync"

    //
    // The plugin instance the background import reaches the engine pool through. Set when the plugin
    // loads: the background processing task the system schedules has no plugin call of its own.
    //
    private static var activeInstance: JsEnginePlugin?

    //
    // The one driver for the life of the app.
    //
    // One instance, one serialised entry point for running a pass, and two callers: the foreground
    // loop and the system's background processing task. Neither knows about the other, which is what
    // makes two imports at once unreachable rather than merely unlikely.
    //
    private static var autoImportDriver: AutoImportDriver?

    //
    // The thread the foreground loop runs on, so it never blocks the WebView's.
    //
    private static var autoImportLoopThread: Thread?

    //
    // Guards the driver and the loop thread above.
    //
    private static let autoImportLock = NSLock()

    //
    // The one sync driver for the life of the app, and the thread its foreground loop runs on.
    //
    // The same arrangement as the import driver's, and for the same reason: two callers (the
    // foreground loop and the system's background processing task) and one serialised entry point
    // between them.
    //
    private static var syncDriver: SyncDriver?

    //
    // The thread the foreground sync loop runs on, so it never blocks the WebView's.
    //
    private static var syncLoopThread: Thread?

    //
    // Guards the sync driver and its loop thread above.
    //
    private static let syncLock = NSLock()

    //
    // What keeps an import pass and a sync pass from running at the same time. One instance, shared
    // by both drivers: an import holds the database write lock and a chain of engine slots for the
    // length of a run, and a sync waiting inside that is what deadlocked the engine pool once
    // already. See docs/mobile-background-tasks.md.
    //
    private static let sharedPassLock = BackgroundPassLock()

    //
    // The host the sync driver talks to the engine pool through.
    //
    // Its own object rather than the plugin itself, which is what the import driver uses: the two
    // protocols name the same methods, and one type answering both would have a sync's log lines
    // saying "AutoImport" and a sync's wait ending when the import loop stopped.
    //
    private static let syncDriverHost = SyncPluginHost()

    //
    // True once the user has switched automatic import on, and false again as soon as they switch it
    // off.
    //
    // Everything about the background import is behind this: the app delegate starts no loop and asks
    // the system for no background pass until it is true. A phone that never opts in is
    // indistinguishable from one running a build without any of this.
    //
    static var autoImportOptedIn = false

    //
    // Background tasks something is waiting on, keyed by task id.
    //
    // The pool reports outcomes to the WebView through an event, which is no use to a background
    // pass: the WebView may be suspended. Each background task registers here before it is queued and
    // is woken by the same delegate callback that emits the event.
    //
    private var backgroundWaitersByTaskId: [String: BackgroundTaskWaiter] = [:]

    //
    // Guards the waiter table above, which is written from the plugin's thread and read from the
    // engine threads that report outcomes.
    //
    private let backgroundWaiterLock = NSLock()

    //
    // One background task something is waiting on.
    //
    fileprivate final class BackgroundTaskWaiter {

        //
        // Signalled when the task finishes, either way.
        //
        let finished = DispatchSemaphore(value: 0)

        //
        // Whether the task succeeded.
        //
        var succeeded = false

        //
        // The task's outputs as a JSON string, when it succeeded.
        //
        var outputsJson: String?

        //
        // The error text, when it failed.
        //
        var errorMessage: String?
    }

    //
    // Something that went wrong while a background import pass was running.
    //
    enum AutoImportError: Error {

        //
        // A task the pass needed failed.
        //
        case taskFailed(String)

        //
        // The plan-auto-import task answered with something that is not a plan.
        //
        case malformedPlan

        //
        // The background import was stopped while a task was running.
        //
        case stopped
    }

    //
    // Resolves the storage root the host functions are sandboxed to. Uses the app's Documents
    // directory, the writable sandbox location on iOS. All task-supplied paths are resolved
    // relative to this root and may never escape it.
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
    // addTask: receives { taskId, type, data, source, priority }. Serialises `data` (arbitrary JSON)
    // to a JSON string, enqueues the task, and resolves immediately. The result is delivered later via
    // the taskCompleted event, matching the fire-and-forget Electron path. `priority` is optional and
    // says the user is waiting on this one; an unrecognised value rejects the call rather than quietly
    // running the task in the background.
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

        let priority: TaskPriority?
        do {
            priority = try taskPriority(fromWireName: call.getString("priority"))
        }
        catch let error as UnknownTaskPriorityError {
            call.reject(error.message)
            return
        }
        catch {
            call.reject("\(error)")
            return
        }

        let task = PooledTask(taskId: taskId, type: type, dataJson: dataJson, source: source, priority: priority)

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
    // pickFiles: presents the native multi-select photo picker for images and videos. Held call is
    // resolved by the PHPicker delegate once the user finishes; each chosen item is copied into the
    // sandbox import temp directory and its sandbox-relative path is returned.
    //
    @objc func pickFiles(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard #available(iOS 14.0, *) else {
                call.reject("pickFiles: the photo picker requires iOS 14 or newer")
                return
            }
            self.pendingPickCall = call

            var configuration = PHPickerConfiguration()
            configuration.selectionLimit = 0
            configuration.filter = .any(of: [.images, .videos])

            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = self

            guard let presenter = self.bridge?.viewController else {
                self.pendingPickCall = nil
                call.reject("pickFiles: no view controller available to present the picker")
                return
            }
            presenter.present(picker, animated: true)
        }
    }

    //
    // Copies one picked file (a temporary URL vended by PHPickerResult.loadFileRepresentation) into
    // the sandbox import temp directory under a fresh uuid name, returning its sandbox-relative path.
    //
    fileprivate func copyPickedFile(from url: URL, suggestedName: String?, mimeType: String?) throws -> String {
        let relativePath = ImportPicker.buildRelativePath(
            uuid: UUID().uuidString,
            displayName: suggestedName,
            fileExtension: url.pathExtension,
            mimeType: mimeType
        )

        let destination = storageRoot().appendingPathComponent(relativePath)
        let parent = destination.deletingLastPathComponent()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)

        return relativePath
    }

    //
    // load: Capacitor lifecycle hook invoked once when the plugin loads. Sweeps the export temp
    // directory so any decrypted copy orphaned by a process kill mid-sheet (which skips the completion
    // handler) is collected on the next launch rather than accumulating in app-private storage.
    //
    override public func load() {
        ExportTemp.sweep(root: storageRoot())

        // The background import reaches the engine pool through here, because the background
        // processing task the system schedules has no plugin call of its own to be handed one.
        JsEnginePlugin.activeInstance = self
    }

    //
    // startBackgroundImport: starts the loop that keeps automatic import running.
    //
    // On iOS that loop runs while the app is foregrounded. What happens when it is not is the
    // system's decision, through the background processing task the app delegate schedules, so this
    // is the whole of what the app can start for itself.
    //
    @objc func startBackgroundImport(_ call: CAPPluginCall) {
        JsEnginePlugin.autoImportOptedIn = true
        JsEnginePlugin.startForegroundAutoImport()

        // The sync loop starts with the import loop and stops with it, exactly as the two loops share
        // one foreground service on Android. Whether a sync actually runs is the plan-sync task's
        // decision, pass by pass, and it says no while syncing is switched off: starting the loop is
        // not the same as syncing being on.
        JsEnginePlugin.startForegroundSync()
        call.resolve()
    }

    //
    // stopBackgroundImport: stops the loop and cancels the import in flight.
    //
    // Safe to call when nothing is running, which is what a freshly launched app does when it finds
    // automatic import switched off.
    //
    @objc func stopBackgroundImport(_ call: CAPPluginCall) {
        JsEnginePlugin.autoImportOptedIn = false
        JsEnginePlugin.stopAutoImport()
        JsEnginePlugin.stopSync()

        // Switching automatic import off has to leave nothing behind, so the background passes the
        // system is still holding requests for are withdrawn as well.
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: autoImportBackgroundTaskIdentifier)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundSyncBackgroundTaskIdentifier)
        }

        call.resolve()
    }

    //
    // exportFile: hands one finished sandbox file out of the app. The download task has already
    // written the bytes at { path }; this presents a UIActivityViewController for that file and, once
    // the sheet is dismissed (shared or cancelled), deletes the temp copy and resolves { path } on a
    // completed share or { path: null } on cancel. A testOutcome short-circuits the non-automatable
    // sheet straight to the completion path.
    //
    @objc func exportFile(_ call: CAPPluginCall) {
        guard let path = call.getString("path") else {
            call.reject("exportFile requires a path")
            return
        }

        let root = storageRoot()
        let fileURL: URL
        do {
            fileURL = try PathSandbox.resolveWithin(root: root, candidate: path)
        }
        catch {
            call.reject("exportFile: \(error)")
            return
        }

        if let testOutcome = call.getString("testOutcome") {
            resolveExportFile(call, root: root, path: path, cancelled: testOutcome == "cancelled")
            return
        }

        DispatchQueue.main.async {
            let activityController = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activityController.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                guard let self = self else {
                    return
                }
                self.resolveExportFile(call, root: root, path: path, cancelled: !completed)
            }
            guard let presenter = self.bridge?.viewController else {
                self.resolveExportFile(call, root: root, path: path, cancelled: true)
                return
            }
            // On iPad the sheet is a popover and needs a source anchor.
            activityController.popoverPresentationController?.sourceView = presenter.view
            presenter.present(activityController, animated: true)
        }
    }

    //
    // exportFiles: batch form of exportFile presenting a single UIActivityViewController for several
    // finished sandbox files; deletes each temp copy on dismissal and resolves { paths } on a
    // completed share or { paths: null } on cancel.
    //
    @objc func exportFiles(_ call: CAPPluginCall) {
        guard let paths = call.getArray("paths", String.self) else {
            call.reject("exportFiles requires a paths array")
            return
        }

        let root = storageRoot()
        var fileURLs: [URL] = []
        do {
            for relativePath in paths {
                fileURLs.append(try PathSandbox.resolveWithin(root: root, candidate: relativePath))
            }
        }
        catch {
            call.reject("exportFiles: \(error)")
            return
        }

        if let testOutcome = call.getString("testOutcome") {
            resolveExportFiles(call, root: root, paths: paths, cancelled: testOutcome == "cancelled")
            return
        }

        DispatchQueue.main.async {
            let activityController = UIActivityViewController(activityItems: fileURLs, applicationActivities: nil)
            activityController.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                guard let self = self else {
                    return
                }
                self.resolveExportFiles(call, root: root, paths: paths, cancelled: !completed)
            }
            guard let presenter = self.bridge?.viewController else {
                self.resolveExportFiles(call, root: root, paths: paths, cancelled: true)
                return
            }
            activityController.popoverPresentationController?.sourceView = presenter.view
            presenter.present(activityController, animated: true)
        }
    }

    //
    // Deletes the single temp copy and resolves the call with { path } (or { path: null } on cancel).
    //
    private func resolveExportFile(_ call: CAPPluginCall, root: URL, path: String, cancelled: Bool) {
        let exported = ExportTemp.finishExport(root: root, relativePath: path, cancelled: cancelled)
        call.resolve(["path": exported ?? NSNull()])
    }

    //
    // Deletes every temp copy and resolves the call with { paths } (or { paths: null } on cancel).
    //
    private func resolveExportFiles(_ call: CAPPluginCall, root: URL, paths: [String], cancelled: Bool) {
        let exported = ExportTemp.finishExportBatch(root: root, relativePaths: paths, cancelled: cancelled)
        call.resolve(["paths": exported ?? NSNull()])
    }

    //
    // requestMediaPermission: asks for the photo library permission and reports whether it was
    // granted, as { granted: Bool }.
    //
    // Only read access is asked for. Limited access (the user choosing particular photos) counts as
    // granted: automatic import can only see what it was given, and telling the user it was refused
    // when they deliberately shared a few photos would be wrong.
    //
    @objc func requestMediaPermission(_ call: CAPPluginCall) {
        PHPhotoLibrary.requestAuthorization { status in
            let granted: Bool
            if #available(iOS 14, *) {
                granted = status == .authorized || status == .limited
            }
            else {
                granted = status == .authorized
            }
            call.resolve(["granted": granted])
        }
    }

    //
    // stageMediaDeleteOutcome: stages the answer to the next photo library delete request, instead
    // of presenting the system confirmation.
    //
    // The confirmation cannot be tapped by an automated test. Staging the answer leaves everything
    // above it under test: choosing which photos are confirmed, batching them into one request, and
    // handling both answers. Nothing stages an outcome in production, so the real request is issued.
    //
    @objc func stageMediaDeleteOutcome(_ call: CAPPluginCall) {
        guard let outcome = call.getString("outcome") else {
            call.reject("outcome is required")
            return
        }

        MediaDeleteStaging.stage(deleted: outcome == "deleted")
        call.resolve()
    }


    //
    // Returns the one driver for the life of the app, creating it on first use.
    //
    static func sharedAutoImportDriver() -> AutoImportDriver? {
        autoImportLock.lock()
        defer { autoImportLock.unlock() }

        if let existing = autoImportDriver {
            return existing
        }

        guard let plugin = activeInstance else {
            return nil
        }

        let created = AutoImportDriver(host: plugin, sharedPassLock: sharedPassLock)
        autoImportDriver = created
        return created
    }

    //
    // Returns the one sync driver for the life of the app, creating it on first use.
    //
    static func sharedSyncDriver() -> SyncDriver? {
        syncLock.lock()
        defer { syncLock.unlock() }

        if let existing = syncDriver {
            return existing
        }

        guard activeInstance != nil else {
            return nil
        }

        let created = SyncDriver(host: syncDriverHost, sharedPassLock: sharedPassLock)
        syncDriver = created
        return created
    }

    //
    // Starts the loop that runs sync passes while the app is foregrounded.
    //
    // Starting it again while it is running does nothing, for the same reason the import loop refuses
    // a second start: two loops would take turns running passes back to back with no gap between
    // them.
    //
    static func startForegroundSync() {
        guard let driver = sharedSyncDriver() else {
            return
        }

        driver.resume()

        syncLock.lock()
        if let existing = syncLoopThread, !existing.isFinished {
            syncLock.unlock()
            return
        }

        let thread = Thread {
            driver.runLoop()
        }
        thread.name = "photosphere-background-sync"
        syncLoopThread = thread
        syncLock.unlock()

        thread.start()
    }

    //
    // Stops the foreground sync loop, leaving any pass in flight to finish or be cancelled.
    //
    static func stopForegroundSync() {
        syncLock.lock()
        let driver = syncDriver
        syncLock.unlock()

        driver?.stop()
    }

    //
    // Stops the background sync outright and cancels the sync in flight.
    //
    static func stopSync() {
        stopForegroundSync()

        guard let plugin = activeInstance else {
            return
        }

        plugin.lock.lock()
        let currentPool = plugin.pool
        plugin.lock.unlock()

        currentPool?.cancelTasks(source: backgroundSyncTaskSource)
    }

    //
    // Runs exactly one sync pass, for the background processing task the system schedules.
    //
    // One pass, not a loop: the system decides when this runs and how long it may take, and a handler
    // that tried to loop would be killed part way through.
    //
    static func runOneBackgroundSyncPass() {
        guard let driver = sharedSyncDriver() else {
            return
        }

        driver.resume()
        driver.runOnePass()
    }

    //
    // Starts the loop that runs passes while the app is foregrounded.
    //
    // Starting it again while it is running does nothing: two loops would ask for a pass each, and
    // while the driver refuses to run them at once, they would take turns running passes back to back
    // with no gap between them.
    //
    static func startForegroundAutoImport() {
        guard let driver = sharedAutoImportDriver() else {
            return
        }

        driver.resume()

        autoImportLock.lock()
        if let existing = autoImportLoopThread, !existing.isFinished {
            autoImportLock.unlock()
            return
        }

        let thread = Thread {
            driver.runLoop()
        }
        thread.name = "photosphere-auto-import"
        autoImportLoopThread = thread
        autoImportLock.unlock()

        thread.start()
    }

    //
    // Stops the foreground loop, leaving any pass in flight to finish or be cancelled.
    //
    static func stopForegroundAutoImport() {
        autoImportLock.lock()
        let driver = autoImportDriver
        autoImportLock.unlock()

        driver?.stop()
    }

    //
    // Stops the background import outright and cancels the import in flight.
    //
    static func stopAutoImport() {
        stopForegroundAutoImport()

        guard let plugin = activeInstance else {
            return
        }

        plugin.lock.lock()
        let currentPool = plugin.pool
        plugin.lock.unlock()

        currentPool?.cancelTasks(source: autoImportTaskSource)
    }

    //
    // Runs exactly one pass, for the background processing task the system schedules.
    //
    // One pass, not a loop: the system decides when this runs and how long it may take, and a handler
    // that tried to loop would be killed part way through.
    //
    // Returns false when the pass found automatic import switched off, so the caller withdraws the
    // request it made for the next one.
    //
    static func runOneBackgroundImportPass() -> Bool {
        guard let driver = sharedAutoImportDriver() else {
            return false
        }

        driver.resume()
        return driver.runOnePass() == .ran
    }

    //
    // Queues one background task and blocks until it finishes.
    //
    // The wait ends when the task completes or when the driver is stopped, whichever comes first. A
    // stop also cancels the task, so nothing is left running behind a wait that has been abandoned.
    // There is deliberately no overall timeout: an import of a large photo library takes as long as it
    // takes, and a wait that gave up part way would have the driver start a second import beside the
    // first.
    //
    fileprivate func runBackgroundTask(type: String, dataJson: String, source: String, isStopped: () -> Bool) throws -> BackgroundTaskWaiter {
        let taskId = UUID().uuidString
        let waiter = BackgroundTaskWaiter()

        backgroundWaiterLock.lock()
        backgroundWaitersByTaskId[taskId] = waiter
        backgroundWaiterLock.unlock()

        defer {
            backgroundWaiterLock.lock()
            backgroundWaitersByTaskId.removeValue(forKey: taskId)
            backgroundWaiterLock.unlock()
        }

        lock.lock()
        let currentPool = ensurePool()
        lock.unlock()

        currentPool.addTask(PooledTask(
            taskId: taskId,
            type: type,
            dataJson: dataJson,
            source: source,
            priority: TaskPriority.background))

        while waiter.finished.wait(timeout: .now() + 0.5) == .timedOut {
            if isStopped() {
                currentPool.cancelTasks(source: source)
                throw AutoImportError.stopped
            }
        }

        return waiter
    }

    //
    // Wakes whatever is waiting for a background task, if anything is.
    //
    private func completeBackgroundTask(taskId: String, succeeded: Bool, outputsJson: String?, errorMessage: String?) {
        backgroundWaiterLock.lock()
        let waiter = backgroundWaitersByTaskId[taskId]
        backgroundWaiterLock.unlock()

        guard let waiter = waiter else {
            return
        }

        waiter.succeeded = succeeded
        waiter.outputsJson = outputsJson
        waiter.errorMessage = errorMessage
        waiter.finished.signal()
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
        completeBackgroundTask(taskId: task.taskId, succeeded: true, outputsJson: outputsJson, errorMessage: nil)

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
        completeBackgroundTask(taskId: task.taskId, succeeded: false, outputsJson: nil, errorMessage: errorMessage)

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

//
// The plugin as the background import's host: it owns the engine pool, so it is what runs the tasks
// a pass is made of.
//
extension JsEnginePlugin: AutoImportDriverHost {

    //
    // Asks the plan-auto-import task what the next pass should do.
    //
    func readPlan() throws -> AutoImportPlan {
        let waiter = try runBackgroundTask(
            type: JsEnginePlugin.planAutoImportTask,
            dataJson: "{}",
            source: JsEnginePlugin.autoImportTaskSource,
            isStopped: { JsEnginePlugin.sharedAutoImportDriver()?.isStopped != false })
        if !waiter.succeeded {
            throw AutoImportError.taskFailed(waiter.errorMessage ?? "plan-auto-import failed")
        }

        guard let outputsJson = waiter.outputsJson else {
            throw AutoImportError.malformedPlan
        }

        return try JsEnginePlugin.parseAutoImportPlan(outputsJson)
    }

    //
    // Runs one of the plan's steps on the engine pool and waits for it to finish.
    //
    func runStep(_ step: AutoImportPlan.Step) throws -> Bool {
        let waiter = try runBackgroundTask(
            type: step.type,
            dataJson: step.dataJson,
            source: JsEnginePlugin.autoImportTaskSource,
            isStopped: { JsEnginePlugin.sharedAutoImportDriver()?.isStopped != false })
        return waiter.succeeded
    }

    //
    // Waits between passes, ending early when the driver is stopped.
    //
    // Woken every second rather than parked for the whole gap, so switching automatic import off, or
    // the app leaving the foreground, is noticed within a second instead of at the end of the gap.
    //
    func pause(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if JsEnginePlugin.sharedAutoImportDriver()?.isStopped != false {
                return false
            }
            Thread.sleep(forTimeInterval: min(1, deadline.timeIntervalSinceNow))
        }

        return JsEnginePlugin.sharedAutoImportDriver()?.isStopped == false
    }

    //
    // Says what the background import is doing.
    //
    func report(_ message: String) {
        print("[AutoImport] \(message)")
    }

    //
    // Says what went wrong.
    //
    func reportError(_ message: String) {
        print("[AutoImport] ERROR: \(message)")
    }

    //
    // Turns the plan-auto-import task's outputs into the plan the driver runs.
    //
    private static func parseAutoImportPlan(_ outputsJson: String) throws -> AutoImportPlan {
        guard let data = outputsJson.data(using: .utf8),
              let outputs = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutoImportError.malformedPlan
        }

        var steps: [AutoImportPlan.Step] = []
        if let stepsJson = outputs["steps"] as? [[String: Any]] {
            for stepJson in stepsJson {
                guard let type = stepJson["type"] as? String,
                      let stepData = stepJson["data"],
                      let stepDataJson = try? JSONSerialization.data(withJSONObject: stepData),
                      let stepDataString = String(data: stepDataJson, encoding: .utf8) else {
                    throw AutoImportError.malformedPlan
                }
                steps.append(AutoImportPlan.Step(type: type, dataJson: stepDataString))
            }
        }

        // The plan carries the gap in milliseconds, because that is what the Android side takes; iOS
        // waits in seconds.
        let pauseMs = outputs["pauseBetweenRunsMs"] as? Double ?? 0

        return AutoImportPlan(
            shouldRun: outputs["shouldRun"] as? Bool ?? false,
            databasePath: outputs["databasePath"] as? String ?? "",
            pauseBetweenRuns: pauseMs / 1000,
            steps: steps)
    }
}

//
// Error raised when the picker vends neither a file URL nor an error for a picked item, so it cannot
// be copied into the sandbox. Surfacing it lets pickFiles reject rather than silently drop the item.
//
enum JsEnginePickError: Error {

    // The picker's loadFileRepresentation completion supplied no URL and no error.
    case missingFileRepresentation
}

//
// Outcome of loading and copying one picked item into the sandbox: either the sandbox-relative path
// of the copied file, or the error that prevented the copy. The picker collects one per picked item.
//
enum PickedItemOutcome {

    // The item was copied successfully to this sandbox-relative path.
    case copied(String)

    // The item could not be loaded or copied; carries the underlying error.
    case failed(Error)
}

//
// Result of aggregating every picked item's outcome: either all items copied (their relative paths in
// pick order) or the first failure that occurred, so pickFiles resolves with the paths or rejects with
// the error, matching the Android plugin which rejects the whole call on any copy failure.
//
enum PickAggregation {

    // Every picked item copied; carries the sandbox-relative paths in pick order.
    case success([String])

    // At least one item failed; carries the first failure's error.
    case failure(Error)
}

//
// Reduces the per-item outcomes to a single aggregation: the first failure wins and short-circuits the
// whole pick (matching Android's reject-on-IOException), otherwise every copied path is returned in
// pick order. Kept as a free function so the resolve-versus-reject decision is unit-testable.
//
func aggregatePickedOutcomes(_ outcomes: [PickedItemOutcome]) -> PickAggregation {
    var paths: [String] = []
    for outcome in outcomes {
        switch outcome {
        case .copied(let relativePath):
            paths.append(relativePath)
        case .failed(let error):
            return .failure(error)
        }
    }
    return .success(paths)
}

//
// PHPicker delegate: copies each picked item into the sandbox and resolves the held pickFiles call
// with the copied files' sandbox-relative paths (empty when the user cancelled). If any item fails to
// load or copy the call is rejected instead of silently dropping that item, matching the Android
// plugin. Kept in this file so the fileprivate copyPickedFile and private storageRoot remain accessible.
//
@available(iOS 14.0, *)
extension JsEnginePlugin: PHPickerViewControllerDelegate {

    //
    // Handles the picker finishing: dismisses it, loads each result's file representation into the
    // sandbox off the main thread, and resolves the held call once every copy has finished. If any
    // item fails to load or copy, the call is rejected rather than resolving with a partial list.
    //
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let call = pendingPickCall else {
            return
        }
        pendingPickCall = nil

        if results.isEmpty {
            call.resolve(["paths": []])
            return
        }

        let group = DispatchGroup()
        let outcomesLock = NSLock()
        var outcomes = [PickedItemOutcome?](repeating: nil, count: results.count)

        for (index, result) in results.enumerated() {
            group.enter()
            let provider = result.itemProvider
            let typeIdentifier = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
            let mimeType = UTType(typeIdentifier)?.preferredMIMEType
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, loadError in
                defer {
                    group.leave()
                }
                let outcome: PickedItemOutcome
                if let loadError = loadError {
                    outcome = .failed(loadError)
                }
                else if let self = self, let url = url {
                    do {
                        let relativePath = try self.copyPickedFile(from: url, suggestedName: provider.suggestedName, mimeType: mimeType)
                        outcome = .copied(relativePath)
                    }
                    catch {
                        outcome = .failed(error)
                    }
                }
                else {
                    outcome = .failed(JsEnginePickError.missingFileRepresentation)
                }
                outcomesLock.lock()
                outcomes[index] = outcome
                outcomesLock.unlock()
            }
        }

        group.notify(queue: .main) {
            let resolvedOutcomes = outcomes.map { outcome in
                outcome ?? .failed(JsEnginePickError.missingFileRepresentation)
            }
            switch aggregatePickedOutcomes(resolvedOutcomes) {
            case .success(let paths):
                call.resolve(["paths": paths])
            case .failure(let error):
                call.reject("Failed to import picked files: \(error.localizedDescription)")
            }
        }
    }
}

//
// The plugin as the background sync's way to the engine pool.
//
// A separate extension from the import's because the two run under different source tags and stop
// independently: a sync cancelled because an import was switched off would be a sync that stopped for
// no reason the user could see.
//
extension JsEnginePlugin {

    //
    // Queues one background sync task and waits for it, ending the wait if the sync driver is
    // stopped.
    //
    fileprivate static func runSyncBackgroundTask(type: String, dataJson: String) throws -> BackgroundTaskWaiter {
        guard let plugin = activeInstance else {
            throw AutoImportError.stopped
        }

        return try plugin.runBackgroundTask(
            type: type,
            dataJson: dataJson,
            source: backgroundSyncTaskSource,
            isStopped: { sharedSyncDriver()?.isStopped != false })
    }

    //
    // Asks the plan-sync task whether a sync should run, and against which database.
    //
    fileprivate static func readSyncPlan() throws -> SyncPlan {
        let waiter = try runSyncBackgroundTask(type: planSyncTask, dataJson: "{}")
        if !waiter.succeeded {
            throw AutoImportError.taskFailed(waiter.errorMessage ?? "plan-sync failed")
        }

        guard let outputsJson = waiter.outputsJson else {
            throw AutoImportError.malformedPlan
        }

        return try parseSyncPlan(outputsJson)
    }

    //
    // Turns the plan-sync task's outputs into the plan the sync driver runs.
    //
    // Every field defaults to the answer that does nothing, so outputs that arrive malformed refuse a
    // sync rather than running one on a guess.
    //
    static func parseSyncPlan(_ outputsJson: String) throws -> SyncPlan {
        guard let data = outputsJson.data(using: .utf8),
              let outputs = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutoImportError.malformedPlan
        }

        var steps: [SyncPlan.Step] = []
        if let stepsJson = outputs["steps"] as? [[String: Any]] {
            for stepJson in stepsJson {
                guard let type = stepJson["type"] as? String,
                      let stepData = stepJson["data"],
                      let stepDataJson = try? JSONSerialization.data(withJSONObject: stepData),
                      let stepDataString = String(data: stepDataJson, encoding: .utf8) else {
                    throw AutoImportError.malformedPlan
                }
                steps.append(SyncPlan.Step(type: type, dataJson: stepDataString))
            }
        }

        // The plan carries the gap in milliseconds, because that is what the Android side takes; iOS
        // waits in seconds.
        let pauseMs = outputs["pauseBetweenRunsMs"] as? Double ?? 0

        return SyncPlan(
            shouldRun: outputs["shouldRun"] as? Bool ?? false,
            databasePath: outputs["databasePath"] as? String ?? "",
            reason: outputs["reason"] as? String ?? "",
            pauseBetweenRuns: pauseMs / 1000,
            steps: steps)
    }
}

//
// What the sync driver talks to the engine pool through.
//
// Its own type rather than the plugin itself, which is what the import driver uses. The two driver
// protocols name the same methods, and one type answering both would leave a sync's log lines saying
// "AutoImport" and a sync's wait between passes ending when the import loop was stopped.
//
final class SyncPluginHost: SyncDriverHost {

    //
    // Asks the plan-sync task whether a sync should run, and against which database.
    //
    func readPlan() throws -> SyncPlan {
        return try JsEnginePlugin.readSyncPlan()
    }

    //
    // Runs one of the plan's steps on the engine pool and waits for it to finish.
    //
    func runStep(_ step: SyncPlan.Step) throws -> Bool {
        let waiter = try JsEnginePlugin.runSyncBackgroundTask(type: step.type, dataJson: step.dataJson)
        return waiter.succeeded
    }

    //
    // Waits between passes, ending early when the sync driver is stopped.
    //
    // Woken every second rather than parked for the whole gap, so switching syncing off, or the app
    // leaving the foreground, is noticed within a second instead of at the end of the gap. The gap
    // between sync passes is minutes, which makes that difference a large one.
    //
    func pause(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if JsEnginePlugin.sharedSyncDriver()?.isStopped != false {
                return false
            }
            Thread.sleep(forTimeInterval: min(1, deadline.timeIntervalSinceNow))
        }

        return JsEnginePlugin.sharedSyncDriver()?.isStopped == false
    }

    //
    // Says what the background sync is doing.
    //
    func report(_ message: String) {
        print("[BackgroundSync] \(message)")
    }

    //
    // Says what went wrong.
    //
    func reportError(_ message: String) {
        print("[BackgroundSync] ERROR: \(message)")
    }
}
