import Foundation
import Capacitor
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
