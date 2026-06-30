import Foundation
import JavaScriptCore

//
// Error thrown by host functions that have not been implemented yet on iOS. It carries
// the exact NOT IMPLEMENTED message so the failure is identical on both platforms and is
// asserted verbatim by the unit tests.
//
struct NotImplementedError: Error, CustomStringConvertible {

    //
    // The exact NOT IMPLEMENTED message naming the missing host function.
    //
    let message: String

    //
    // Surfaces the message as the error description so it appears in the task's error result.
    //
    var description: String {
        return message
    }
}

//
// Error thrown by the native fs write host functions. `.exists` carries the EEXIST marker the JS fs
// shim maps to a Node EEXIST code (used by the storage write-lock); `.message` is any other failure.
//
enum HostFsError: Error, CustomStringConvertible {

    //
    // An exclusive ('wx') write found an existing file at the path.
    //
    case exists(String)

    //
    // Any other fs failure, carrying a human-readable message.
    //
    case message(String)

    //
    // The message surfaced as the task's error (and matched by the JS shim for EEXIST).
    //
    var description: String {
        switch self {
        case .exists(let path):
            return "EEXIST: file already exists: \(path)"
        case .message(let text):
            return text
        }
    }
}

//
// Builds the exact NOT IMPLEMENTED error message used verbatim on both platforms. Kept in
// one helper so the wording can never drift from the TypeScript `notImplementedMessage`.
//
func notImplemented(_ name: String) -> NotImplementedError {
    let message = "NOT IMPLEMENTED: native host function \"\(name)\" is not implemented yet on ios. Implement it ASAP."

    // Log at error level so a missing native function is visible during native debugging,
    // not just surfaced as the task's failure in the WebView.
    NSLog("%@", message)
    return NotImplementedError(message: message)
}

//
// The native side of `globalThis.host`. One HostBridge is installed into each engine's
// JSContext before `runTask` runs. Its functions are synchronous Swift closures called
// directly from the running JS handler (JSC runs JS->native calls synchronously on the
// context's own thread). The bridge is intentionally engine-agnostic about Capacitor: it
// reports streamed messages through a closure the pool supplies, so the same bridge is used
// in unit tests with a capturing closure.
//
final class HostBridge {

    //
    // The platform string exposed as `host.platform`. Always "ios" so the JS-side NOT
    // IMPLEMENTED stubs name the correct platform.
    //
    let platform = "ios"

    //
    // The single pool-owned session id exposed as `host.sessionId`. One value is generated at
    // pool init and shared across every engine and task so the node-api write locks stay
    // consistent.
    //
    let sessionId: String

    //
    // The storage root every path-taking host function is sandboxed to. Task-supplied paths
    // are resolved relative to this root and may never escape it.
    //
    let storageRoot: URL

    //
    // The native TCP socket layer behind the host.tcp* functions. Owned per engine context; the
    // engine drains its inbound event queue on the JSContext thread and delivers each event into the
    // JS net shim via globalThis.__tcpEvent.
    //
    let tcp = TcpHost()

    //
    // Returns true when the task with the given id has been cancelled. Reads an atomic/volatile
    // flag WITHOUT taking the pool lock, so a running handler can poll cancellation cheaply from
    // inside a tight loop without contending with the dispatcher.
    //
    private let isCancelledProvider: (String) -> Bool

    //
    // Hands a streamed message off to the pool, which forwards it as a `taskMessage` event. The
    // pool implementation takes a short lock only around the notifyListeners hand-off; this
    // closure never calls back into the engine, so there is no re-entrancy with the JS event loop.
    //
    private let messageSink: (String, String) -> Void

    //
    // Constructs a host bridge for one engine context. `sessionId` and `storageRoot` come from
    // the pool; `isCancelledProvider` and `messageSink` route cancellation reads and streamed
    // messages back to the pool (or to a capturing closure in tests).
    //
    init(sessionId: String,
         storageRoot: URL,
         isCancelledProvider: @escaping (String) -> Bool,
         messageSink: @escaping (String, String) -> Void) {
        self.sessionId = sessionId
        self.storageRoot = storageRoot
        self.isCancelledProvider = isCancelledProvider
        self.messageSink = messageSink
    }

    //
    // Installs this bridge as `globalThis.host` in the given JSContext. Every member is set as a
    // property on a fresh JS object: value properties for `platform`/`sessionId`, and JS function
    // values wrapping Swift closures for the synchronous callables. Throwing host functions raise
    // a JS exception in the calling context so the handler's promise rejects with the message.
    //
    func install(into context: JSContext) {
        let host = JSValue(newObjectIn: context)!

        host.setValue(platform, forProperty: "platform")
        host.setValue(sessionId, forProperty: "sessionId")

        // sendMessage(taskId, messageJson): synchronous; hands the raw JSON string to the pool.
        let sendMessage: @convention(block) (String, String) -> Void = { [weak self] taskId, messageJson in
            self?.messageSink(taskId, messageJson)
        }
        host.setValue(JSValue(object: sendMessage, in: context), forProperty: "sendMessage")

        // isCancelled(taskId): synchronous; returns a Bool read from the atomic cancelled flag.
        let isCancelled: @convention(block) (String) -> Bool = { [weak self] taskId in
            return self?.isCancelledProvider(taskId) ?? false
        }
        host.setValue(JSValue(object: isCancelled, in: context), forProperty: "isCancelled")

        // sha256(path): hashing a file is a Node.js crypto capability this infrastructure plan
        // deliberately does not implement natively. It raises the NOT IMPLEMENTED JS exception so
        // the task fails loudly until a later plan provides the native hashing host function.
        let sha256: @convention(block) (String) -> JSValue = { path in
            context.exception = JSValue(newErrorFromMessage: notImplemented("sha256").message, in: context)
            return JSValue(undefinedIn: context)
        }
        host.setValue(JSValue(object: sha256, in: context), forProperty: "sha256")

        // The fs host functions never raise a JS exception across the bridge: on error they return an
        // error-envelope string (mirrored with Android and the JS shim) that the shim decodes and
        // throws. This keeps the contract identical on both engines. The boolean fsAccess returns
        // false on error.

        // fsReadFile(path): bytes as a base64 string, JS null when missing, or an error envelope.
        let fsReadFile: @convention(block) (String) -> JSValue = { [weak self] path in
            guard let self = self else { return JSValue(nullIn: context) }
            do {
                if let base64 = try self.fsReadFile(path: path) {
                    return JSValue(object: base64, in: context)
                }
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: fsReadFile, in: context), forProperty: "fsReadFile")

        // fsAccess(path): whether a sandboxed file or directory exists (false on any error).
        let fsAccess: @convention(block) (String) -> Bool = { [weak self] path in
            guard let self = self else { return false }
            return (try? self.fsAccess(path: path)) ?? false
        }
        host.setValue(JSValue(object: fsAccess, in: context), forProperty: "fsAccess")

        // fsStat(path): JSON stat string, JS null when missing, or an error envelope.
        let fsStat: @convention(block) (String) -> JSValue = { [weak self] path in
            guard let self = self else { return JSValue(nullIn: context) }
            do {
                if let json = try self.fsStat(path: path) {
                    return JSValue(object: json, in: context)
                }
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: fsStat, in: context), forProperty: "fsStat")

        // fsReaddir(path): JSON listing, JS null when missing, or an error envelope.
        let fsReaddir: @convention(block) (String) -> JSValue = { [weak self] path in
            guard let self = self else { return JSValue(nullIn: context) }
            do {
                if let json = try self.fsReaddir(path: path) {
                    return JSValue(object: json, in: context)
                }
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: fsReaddir, in: context), forProperty: "fsReaddir")

        // fsWriteFile(path, base64, exclusive): writes bytes; returns JS null on success or an error
        // envelope (its message contains EEXIST for an exclusive write over an existing file).
        let fsWriteFile: @convention(block) (String, String, Bool) -> JSValue = { [weak self] path, base64, exclusive in
            guard let self = self else { return JSValue(nullIn: context) }
            do {
                try self.fsWriteFile(path: path, base64: base64, exclusive: exclusive)
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: fsWriteFile, in: context), forProperty: "fsWriteFile")

        // fsMkdir(path, recursive): creates a sandboxed directory; null on success or error envelope.
        let fsMkdir: @convention(block) (String, Bool) -> JSValue = { [weak self] path, recursive in
            guard let self = self else { return JSValue(nullIn: context) }
            do {
                try self.fsMkdir(path: path, recursive: recursive)
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: fsMkdir, in: context), forProperty: "fsMkdir")

        // fsRename(srcPath, destPath): renames/moves a file; null on success or error envelope.
        let fsRename: @convention(block) (String, String) -> JSValue = { [weak self] srcPath, destPath in
            guard let self = self else { return JSValue(nullIn: context) }
            do {
                try self.fsRename(srcPath: srcPath, destPath: destPath)
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: fsRename, in: context), forProperty: "fsRename")

        // fsUnlink(path): deletes a file; null on success or error envelope.
        let fsUnlink: @convention(block) (String) -> JSValue = { [weak self] path in
            guard let self = self else { return JSValue(nullIn: context) }
            do {
                try self.fsUnlink(path: path)
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: fsUnlink, in: context), forProperty: "fsUnlink")

        // fsRm(path, recursive, force): deletes a file or directory tree; null on success or envelope.
        let fsRm: @convention(block) (String, Bool, Bool) -> JSValue = { [weak self] path, recursive, force in
            guard let self = self else { return JSValue(nullIn: context) }
            do {
                try self.fsRm(path: path, recursive: recursive, force: force)
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: fsRm, in: context), forProperty: "fsRm")

        // Native-backed TCP socket functions: the embedded asset server (run as a long-lived task)
        // binds a loopback listener and reads/writes connections through these. Inbound connection /
        // data / close events are pushed back into the engine via globalThis.__tcpEvent (driven by the
        // engine's drain loop). tcpListen returns the listener JSON (or an error envelope); the others
        // return JS null on success or an error envelope on failure.
        let tcpListen: @convention(block) (String, Int) -> JSValue = { [weak self] host, port in
            guard let self = self else { return JSValue(nullIn: context) }
            return JSValue(object: self.tcp.tcpListen(host: host, port: port), in: context)
        }
        host.setValue(JSValue(object: tcpListen, in: context), forProperty: "tcpListen")

        let tcpWrite: @convention(block) (String, String) -> JSValue = { [weak self] connectionId, base64 in
            guard let self = self else { return JSValue(nullIn: context) }
            if let envelope = self.tcp.tcpWrite(connectionId: connectionId, base64: base64) {
                return JSValue(object: envelope, in: context)
            }
            return JSValue(nullIn: context)
        }
        host.setValue(JSValue(object: tcpWrite, in: context), forProperty: "tcpWrite")

        let tcpClose: @convention(block) (String) -> JSValue = { [weak self] connectionId in
            guard let self = self else { return JSValue(nullIn: context) }
            if let envelope = self.tcp.tcpClose(connectionId: connectionId) {
                return JSValue(object: envelope, in: context)
            }
            return JSValue(nullIn: context)
        }
        host.setValue(JSValue(object: tcpClose, in: context), forProperty: "tcpClose")

        let tcpStopListening: @convention(block) (String) -> JSValue = { [weak self] listenerId in
            guard let self = self else { return JSValue(nullIn: context) }
            if let envelope = self.tcp.tcpStopListening(listenerId: listenerId) {
                return JSValue(object: envelope, in: context)
            }
            return JSValue(nullIn: context)
        }
        host.setValue(JSValue(object: tcpStopListening, in: context), forProperty: "tcpStopListening")

        context.globalObject.setValue(host, forProperty: "host")
    }

    //
    // host.sha256(path): hashing a file is a Node.js crypto capability that this infrastructure
    // plan deliberately does not implement natively. It reports NOT IMPLEMENTED until a later plan
    // provides the native hashing host function. The path is accepted only so the signature stays
    // stable for when the real implementation lands.
    //
    func sha256(path: String) throws -> String {
        throw notImplemented("sha256")
    }

    //
    // host.fsReadFile(path): reads a sandboxed file and returns its bytes as a base64 string, or nil
    // when the path is missing or is not a regular file (surfaced as ENOENT by the JS shim). Whole-file
    // read matches the mobile read model (only small database metadata files are read).
    //
    func fsReadFile(path: String) throws -> String? {
        let url = try PathSandbox.resolveWithin(root: storageRoot, candidate: path)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return data.base64EncodedString()
    }

    //
    // host.fsAccess(path): returns true when a sandboxed file or directory exists. Backs pathExists.
    //
    func fsAccess(path: String) throws -> Bool {
        let url = try PathSandbox.resolveWithin(root: storageRoot, candidate: path)
        return FileManager.default.fileExists(atPath: url.path)
    }

    //
    // host.fsStat(path): returns a JSON string { size, mtimeMs, isFile, isDirectory } for a sandboxed
    // path, or nil when it does not exist. Built by hand (only numbers/booleans) to mirror the Android
    // implementation byte-for-byte in shape. mtimeMs is epoch milliseconds, matching Android.
    //
    func fsStat(path: String) throws -> String? {
        let url = try PathSandbox.resolveWithin(root: storageRoot, candidate: path)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let mtimeMs = Int64((modificationDate * 1000).rounded())
        let isFile = !isDirectory.boolValue
        return "{\"size\":\(size),\"mtimeMs\":\(mtimeMs),\"isFile\":\(isFile),\"isDirectory\":\(isDirectory.boolValue)}"
    }

    //
    // host.fsReaddir(path): returns a JSON string array of { name, isDirectory } entries for a
    // sandboxed directory, or nil when the directory does not exist. Entry names are JSON-escaped so
    // names with quotes/backslashes/control characters cannot corrupt the payload.
    //
    func fsReaddir(path: String) throws -> String? {
        let url = try PathSandbox.resolveWithin(root: storageRoot, candidate: path)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let entries = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        var parts: [String] = []
        for entry in entries {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            let entryIsDirectory = values.isDirectory ?? false
            parts.append("{\"name\":\"\(HostBridge.jsonEscape(entry.lastPathComponent))\",\"isDirectory\":\(entryIsDirectory)}")
        }
        return "[" + parts.joined(separator: ",") + "]"
    }

    //
    // host.fsWriteFile(path, base64, exclusive): writes base64-decoded bytes to a sandboxed path,
    // creating parent directories as needed. With exclusive true (Node 'wx') it throws an
    // EEXIST-marked error when the file already exists, so the JS shim surfaces EEXIST.
    //
    func fsWriteFile(path: String, base64: String, exclusive: Bool) throws {
        let url = try PathSandbox.resolveWithin(root: storageRoot, candidate: path)
        let fileManager = FileManager.default
        if exclusive && fileManager.fileExists(atPath: url.path) {
            throw HostFsError.exists(path)
        }

        let parent = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        guard let data = Data(base64Encoded: base64) else {
            throw HostFsError.message("fsWriteFile: invalid base64 for \(path)")
        }
        try data.write(to: url)
    }

    //
    // host.fsMkdir(path, recursive): creates a sandboxed directory, a no-op when it already exists
    // (matching Node's fs.mkdir({ recursive: true })).
    //
    func fsMkdir(path: String, recursive: Bool) throws {
        let url = try PathSandbox.resolveWithin(root: storageRoot, candidate: path)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return
            }
            throw HostFsError.message("fsMkdir: path exists and is not a directory: \(path)")
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: recursive)
    }

    //
    // host.fsRename(srcPath, destPath): renames/moves a sandboxed file, overwriting an existing
    // destination (Node semantics).
    //
    func fsRename(srcPath: String, destPath: String) throws {
        let source = try PathSandbox.resolveWithin(root: storageRoot, candidate: srcPath)
        let destination = try PathSandbox.resolveWithin(root: storageRoot, candidate: destPath)
        let fileManager = FileManager.default

        let parent = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
    }

    //
    // host.fsUnlink(path): deletes a sandboxed file. Throws an ENOENT-marked error when missing
    // (callers that tolerate that catch it).
    //
    func fsUnlink(path: String) throws {
        let url = try PathSandbox.resolveWithin(root: storageRoot, candidate: path)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            throw HostFsError.message("ENOENT: no such file or directory, unlink '\(path)'")
        }
        try fileManager.removeItem(at: url)
    }

    //
    // host.fsRm(path, recursive, force): deletes a sandboxed file or directory tree. With force, a
    // missing path is a no-op; otherwise a missing path throws ENOENT.
    //
    func fsRm(path: String, recursive: Bool, force: Bool) throws {
        let url = try PathSandbox.resolveWithin(root: storageRoot, candidate: path)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            if force {
                return
            }
            throw HostFsError.message("ENOENT: no such file or directory, rm '\(path)'")
        }
        try fileManager.removeItem(at: url)
    }

    //
    // Builds an error-envelope string (format shared with the JS host-access shim and Android) so a
    // native fs failure crosses the bridge as a value the shim decodes and throws, rather than as a
    // JS exception. The shim recognises EEXIST/ENOENT in the code segment.
    //
    static func hostErrorEnvelope(_ error: Error) -> String {
        let message = "\(error)"
        let code = message.contains("EEXIST") ? "EEXIST" : (message.contains("ENOENT") ? "ENOENT" : "")
        return "@@HOSTERR@@" + code + ":" + message
    }

    //
    // Escapes a string for embedding inside a JSON string literal (quotes, backslashes, and control
    // characters). Mirrors the Android jsonEscape so both platforms produce identical listing JSON.
    //
    static func jsonEscape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count + 2)
        for character in value.unicodeScalars {
            switch character {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                if character.value < 0x20 {
                    result += String(format: "\\u%04x", character.value)
                }
                else {
                    result.unicodeScalars.append(character)
                }
            }
        }
        return result
    }
}
