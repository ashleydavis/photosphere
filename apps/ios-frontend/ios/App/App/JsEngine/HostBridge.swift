import Foundation
import JavaScriptCore
import CommonCrypto

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
    // The id of the task currently running on this engine, set by the engine immediately before it
    // invokes runTask. host.queueTask reads it as the parent id so the pool can route the child
    // task's outcome back to this engine. Mirrors the Android HostBridge.setCurrentTask.
    //
    var currentTaskId: String?

    //
    // The native TCP socket layer behind the host.tcp* functions. Owned per engine context; the
    // engine drains its inbound event queue on the JSContext thread and delivers each event into the
    // JS net shim via globalThis.__tcpEvent.
    //
    let tcp = TcpHost()

    //
    // The native UDP layer behind host.udp*. LAN-share discovery broadcasts/receives datagrams through
    // it; inbound "message" events are drained on the JSContext thread and delivered via globalThis.__udpEvent.
    //
    let udp = UdpHost()

    //
    // The native TLS layer behind host.tls*. LAN-share's receiver runs a TLS server and its sender a
    // cert-pinning TLS client through it; inbound events are delivered via globalThis.__tlsEvent. Built on
    // Network.framework (iOS 13+), matching the app deployment target.
    //
    let tls = TlsHost()

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
    // Hands a child task the running handler enqueued (via host.queueTask) back to the pool, tagged
    // with the parent task id, so the pool queues it and later routes its outcome to this engine.
    // Mirrors the Android HostBridge forwarding to EngineCallbacks.queueChildTask.
    //
    private let queueTaskSink: (String, String, String, String, String, TaskPriority?) -> Void

    //
    // Constructs a host bridge for one engine context. `sessionId` and `storageRoot` come from
    // the pool; `isCancelledProvider`, `messageSink`, and `queueTaskSink` route cancellation reads,
    // streamed messages, and child-task enqueues back to the pool (or to capturing closures in tests).
    //
    init(sessionId: String,
         storageRoot: URL,
         isCancelledProvider: @escaping (String) -> Bool,
         messageSink: @escaping (String, String) -> Void,
         queueTaskSink: @escaping (String, String, String, String, String, TaskPriority?) -> Void) {
        self.sessionId = sessionId
        self.storageRoot = storageRoot
        self.isCancelledProvider = isCancelledProvider
        self.messageSink = messageSink
        self.queueTaskSink = queueTaskSink
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

        // queueTask(childTaskId, type, dataJson, source, priority): synchronous; hands the child task
        // to the pool tagged with the current (parent) task id so the child's outcome routes back to
        // this engine. A no-op when no task is current (there is no parent to route back to). The
        // priority is JS null when the handler named none, and the child then runs at its parent's; a
        // string that is not a known priority raises a JS exception rather than quietly running the
        // child in the background.
        // The priority crosses as a JSValue rather than an optional String so JS null is read through
        // documented JSValue API rather than relying on how a block parameter bridges a null.
        let queueTask: @convention(block) (String, String, String, String, JSValue) -> Void = { [weak self] childTaskId, type, dataJson, source, priorityValue in
            guard let self = self, let parentTaskId = self.currentTaskId else {
                return
            }
            let priorityWireName: String? = (priorityValue.isNull || priorityValue.isUndefined) ? nil : priorityValue.toString()
            do {
                let priority = try taskPriority(fromWireName: priorityWireName)
                self.queueTaskSink(parentTaskId, childTaskId, type, dataJson, source, priority)
            }
            catch let error as UnknownTaskPriorityError {
                context.exception = JSValue(newErrorFromMessage: error.message, in: context)
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: "\(error)", in: context)
            }
        }
        host.setValue(JSValue(object: queueTask, in: context), forProperty: "queueTask")

        // sha256(path): hashes a whole file natively and returns the digest as lower-case hex, or JS
        // null when the file is missing (which the shim surfaces as ENOENT, matching fsReadFile).
        // A failure raises a JS exception rather than returning a wrong hash: a hash that is fast
        // and wrong is worse than a slow one, because every asset's identity depends on it.
        let sha256: @convention(block) (String) -> JSValue = { [weak self] path in
            guard let self = self else {
                return JSValue(undefinedIn: context)
            }
            do {
                guard let digest = try self.sha256(path: path) else {
                    return JSValue(nullIn: context)
                }
                return JSValue(object: digest, in: context)
            }
            catch {
                context.exception = JSValue(newErrorFromMessage: "\(error)", in: context)
                return JSValue(undefinedIn: context)
            }
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

        let tcpConnect: @convention(block) (String, Int) -> JSValue = { [weak self] host, port in
            guard let self = self else { return JSValue(nullIn: context) }
            return JSValue(object: self.tcp.tcpConnect(host: host, port: port), in: context)
        }
        host.setValue(JSValue(object: tcpConnect, in: context), forProperty: "tcpConnect")

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

        // Native-backed UDP datagram functions: LAN-share discovery binds a broadcast socket and
        // sends/receives datagrams through these. Inbound datagrams are pushed back into the engine via
        // globalThis.__udpEvent. udpBind returns the socket JSON (or an error envelope); udpSend/udpClose
        // return JS null on success or an error envelope.
        let udpBind: @convention(block) (String, Int, Bool) -> JSValue = { [weak self] host, port, broadcast in
            guard let self = self else { return JSValue(nullIn: context) }
            return JSValue(object: self.udp.udpBind(host: host, port: port, broadcast: broadcast), in: context)
        }
        host.setValue(JSValue(object: udpBind, in: context), forProperty: "udpBind")

        let udpSend: @convention(block) (String, String, String, Int) -> JSValue = { [weak self] socketId, base64, host, port in
            guard let self = self else { return JSValue(nullIn: context) }
            if let envelope = self.udp.udpSend(socketId: socketId, base64: base64, host: host, port: port) {
                return JSValue(object: envelope, in: context)
            }
            return JSValue(nullIn: context)
        }
        host.setValue(JSValue(object: udpSend, in: context), forProperty: "udpSend")

        let udpClose: @convention(block) (String) -> JSValue = { [weak self] socketId in
            guard let self = self else { return JSValue(nullIn: context) }
            if let envelope = self.udp.udpClose(socketId: socketId) {
                return JSValue(object: envelope, in: context)
            }
            return JSValue(nullIn: context)
        }
        host.setValue(JSValue(object: udpClose, in: context), forProperty: "udpClose")

        // Native-backed TLS functions: LAN-share's receiver runs a TLS server (from the PEM cert/key the
        // TypeScript generates) and its sender a cert-pinning TLS client. Inbound connection/data/close
        // events are pushed back via globalThis.__tlsEvent. tlsListen/tlsConnect return JSON (or an error
        // envelope); the others return JS null on success or an error envelope.
        let tlsListen: @convention(block) (String, Int, String, String) -> JSValue = { [weak self] host, port, certPem, keyPem in
            guard let self = self else { return JSValue(nullIn: context) }
            return JSValue(object: self.tls.tlsListen(host: host, port: port, certPem: certPem, keyPem: keyPem), in: context)
        }
        host.setValue(JSValue(object: tlsListen, in: context), forProperty: "tlsListen")

        let tlsConnect: @convention(block) (String, Int, Bool) -> JSValue = { [weak self] host, port, rejectUnauthorized in
            guard let self = self else { return JSValue(nullIn: context) }
            return JSValue(object: self.tls.tlsConnect(host: host, port: port, rejectUnauthorized: rejectUnauthorized), in: context)
        }
        host.setValue(JSValue(object: tlsConnect, in: context), forProperty: "tlsConnect")

        let tlsWrite: @convention(block) (String, String) -> JSValue = { [weak self] connectionId, base64 in
            guard let self = self else { return JSValue(nullIn: context) }
            if let envelope = self.tls.tlsWrite(connectionId: connectionId, base64: base64) {
                return JSValue(object: envelope, in: context)
            }
            return JSValue(nullIn: context)
        }
        host.setValue(JSValue(object: tlsWrite, in: context), forProperty: "tlsWrite")

        let tlsClose: @convention(block) (String) -> JSValue = { [weak self] connectionId in
            guard let self = self else { return JSValue(nullIn: context) }
            if let envelope = self.tls.tlsClose(connectionId: connectionId) {
                return JSValue(object: envelope, in: context)
            }
            return JSValue(nullIn: context)
        }
        host.setValue(JSValue(object: tlsClose, in: context), forProperty: "tlsClose")

        let tlsStopListening: @convention(block) (String) -> JSValue = { [weak self] listenerId in
            guard let self = self else { return JSValue(nullIn: context) }
            if let envelope = self.tls.tlsStopListening(listenerId: listenerId) {
                return JSValue(object: envelope, in: context)
            }
            return JSValue(nullIn: context)
        }
        host.setValue(JSValue(object: tlsStopListening, in: context), forProperty: "tlsStopListening")

        // Native RSA crypto (host.crypto*): LAN-share's receiver generates an RSA key pair and self-signs
        // its TLS certificate, then signs with the private key. Both return the result string directly, or
        // an @@HOSTERR@@ envelope the JS crypto shim decodes into a thrown error.
        let cryptoGenerateRsaKeyPair: @convention(block) (Int) -> JSValue = { modulusLength in
            return JSValue(object: CryptoHost.cryptoGenerateRsaKeyPair(modulusLength: modulusLength), in: context)
        }
        host.setValue(JSValue(object: cryptoGenerateRsaKeyPair, in: context), forProperty: "cryptoGenerateRsaKeyPair")

        let cryptoSignSha256: @convention(block) (String, String) -> JSValue = { privateKeyPem, dataBase64 in
            return JSValue(object: CryptoHost.cryptoSignSha256(privateKeyPem: privateKeyPem, dataBase64: dataBase64), in: context)
        }
        host.setValue(JSValue(object: cryptoSignSha256, in: context), forProperty: "cryptoSignSha256")

        // Native RSA OAEP (SHA-1) encrypt/decrypt and public-key derivation, used to open and write
        // ENCRYPTED databases (the AES key is RSA-wrapped with Node's default OAEP padding).
        let cryptoPublicEncryptOaepSha1: @convention(block) (String, String) -> JSValue = { publicKeyPem, dataBase64 in
            return JSValue(object: CryptoHost.cryptoPublicEncryptOaepSha1(publicKeyPem: publicKeyPem, dataBase64: dataBase64), in: context)
        }
        host.setValue(JSValue(object: cryptoPublicEncryptOaepSha1, in: context), forProperty: "cryptoPublicEncryptOaepSha1")

        let cryptoPrivateDecryptOaepSha1: @convention(block) (String, String) -> JSValue = { privateKeyPem, dataBase64 in
            return JSValue(object: CryptoHost.cryptoPrivateDecryptOaepSha1(privateKeyPem: privateKeyPem, dataBase64: dataBase64), in: context)
        }
        host.setValue(JSValue(object: cryptoPrivateDecryptOaepSha1, in: context), forProperty: "cryptoPrivateDecryptOaepSha1")

        let cryptoPublicKeyFromPrivate: @convention(block) (String) -> JSValue = { privateKeyPem in
            return JSValue(object: CryptoHost.cryptoPublicKeyFromPrivate(privateKeyPem: privateKeyPem), in: context)
        }
        host.setValue(JSValue(object: cryptoPublicKeyFromPrivate, in: context), forProperty: "cryptoPublicKeyFromPrivate")

        // Native device keychain (host.secureStore*): the worker vault reads secret values (S3
        // credentials, the encryption private key, geocoding keys) natively through these so secrets
        // never enter task payloads or the log. secureStoreGet returns the value, JS null when absent,
        // or an @@HOSTERR@@ envelope on failure; set/delete return null or an envelope.
        let secureStoreGet: @convention(block) (String) -> JSValue = { key in
            do {
                if let value = try SecureStoreHost.get(key: key) {
                    return JSValue(object: value, in: context)
                }
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: secureStoreGet, in: context), forProperty: "secureStoreGet")

        let secureStoreSet: @convention(block) (String, String) -> JSValue = { key, value in
            do {
                try SecureStoreHost.set(key: key, value: value)
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: secureStoreSet, in: context), forProperty: "secureStoreSet")

        let secureStoreDelete: @convention(block) (String) -> JSValue = { key in
            do {
                try SecureStoreHost.delete(key: key)
                return JSValue(nullIn: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: secureStoreDelete, in: context), forProperty: "secureStoreDelete")

        // The media host functions (imageMagick/ffmpeg/ffprobe) never raise a JS exception across the
        // bridge: they take a JSON-encoded argv string, run the in-process tool, and return the JSON
        // string { exitCode, output } (or an @@HOSTERR@@ envelope on failure) that the mobile
        // runMediaTool helper decodes. Path tokens in the argv are sandbox-resolved to absolute paths
        // (mirroring the fs functions) before the tool runs.

        // imageMagick(argvJson): runs a magick argv in-process (all ImageMagick operations).
        let imageMagick: @convention(block) (String) -> JSValue = { [weak self] argvJson in
            guard let self = self else { return JSValue(nullIn: context) }
            return JSValue(object: self.runMediaTool(argvJson: argvJson) { self.imageMagickRunner.imagemagick($0) }, in: context)
        }
        host.setValue(JSValue(object: imageMagick, in: context), forProperty: "imageMagick")

        // ffmpeg(argvJson): runs an ffmpeg argv in-process (e.g. the screenshot extraction).
        let ffmpeg: @convention(block) (String) -> JSValue = { [weak self] argvJson in
            guard let self = self else { return JSValue(nullIn: context) }
            return JSValue(object: self.runMediaTool(argvJson: argvJson) { self.ffmpegKitRunner.ffmpeg($0) }, in: context)
        }
        host.setValue(JSValue(object: ffmpeg, in: context), forProperty: "ffmpeg")

        // ffprobe(argvJson): runs an ffprobe argv in-process (container/stream metadata JSON).
        let ffprobe: @convention(block) (String) -> JSValue = { [weak self] argvJson in
            guard let self = self else { return JSValue(nullIn: context) }
            return JSValue(object: self.runMediaTool(argvJson: argvJson) { self.ffmpegKitRunner.ffprobe($0) }, in: context)
        }
        host.setValue(JSValue(object: ffprobe, in: context), forProperty: "ffprobe")

        // The device photo library host functions. Automatic import reads the library through these,
        // the same way it reads folders through the fs functions on desktop. Each returns JSON, or an
        // @@HOSTERR@@ envelope on failure, which the mobile shim decodes into a coded Error.

        // mediaLibraryList(cursor, pageSize): one page of the device photo library, as JSON.
        let mediaLibraryList: @convention(block) (String, Int) -> JSValue = { [weak self] cursor, pageSize in
            guard let self = self else { return JSValue(nullIn: context) }
            return JSValue(object: self.mediaLibraryHost.mediaLibraryList(cursor: cursor, pageSize: pageSize), in: context)
        }
        host.setValue(JSValue(object: mediaLibraryList, in: context), forProperty: "mediaLibraryList")

        // mediaLibraryAlbums(): the albums in the device photo library, as JSON.
        let mediaLibraryAlbums: @convention(block) () -> JSValue = { [weak self] in
            guard let self = self else { return JSValue(nullIn: context) }
            return JSValue(object: self.mediaLibraryHost.mediaLibraryAlbums(), in: context)
        }
        host.setValue(JSValue(object: mediaLibraryAlbums, in: context), forProperty: "mediaLibraryAlbums")

        // mediaLibraryOpen(itemId): copies one library item into the sandbox, returning its path.
        let mediaLibraryOpen: @convention(block) (String) -> JSValue = { [weak self] itemId in
            guard let self = self else { return JSValue(nullIn: context) }
            do {
                return JSValue(object: try self.mediaLibraryHost.mediaLibraryOpen(itemId: itemId), in: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: mediaLibraryOpen, in: context), forProperty: "mediaLibraryOpen")

        // mediaLibraryClose(itemId): deletes the sandbox copy an open made.
        let mediaLibraryClose: @convention(block) (String) -> Void = { [weak self] itemId in
            self?.mediaLibraryHost.mediaLibraryClose(itemId: itemId)
        }
        host.setValue(JSValue(object: mediaLibraryClose, in: context), forProperty: "mediaLibraryClose")

        // mediaLibraryDelete(itemIdsJson): asks to delete the named items from the photo library.
        let mediaLibraryDelete: @convention(block) (String) -> JSValue = { [weak self] itemIdsJson in
            guard let self = self else { return JSValue(nullIn: context) }
            do {
                return JSValue(object: try self.mediaLibraryHost.mediaLibraryDelete(itemIdsJson: itemIdsJson), in: context)
            }
            catch {
                return JSValue(object: HostBridge.hostErrorEnvelope(error), in: context)
            }
        }
        host.setValue(JSValue(object: mediaLibraryDelete, in: context), forProperty: "mediaLibraryDelete")

        context.globalObject.setValue(host, forProperty: "host")
    }

    //
    // The device photo library reader (the host.mediaLibrary* functions), created lazily so an
    // engine that never touches the library never asks the Photos framework for anything.
    //
    private lazy var mediaLibraryHost = MediaLibraryHost(storageRoot: storageRoot)

    //
    // The ImageMagick runner (host.imageMagick). Stateless; safe to share across contexts.
    //
    private let imageMagickRunner = ImageMagickRunner()

    //
    // The FFmpegKit runner (host.ffmpeg / host.ffprobe). Stateless; safe to share across contexts.
    //
    private let ffmpegKitRunner = FfmpegKitRunner()

    //
    // Decodes a JSON-encoded argv string, sandbox-resolves its path tokens to absolute paths, runs the
    // given tool, and returns the JSON string { exitCode, output }. On any failure (bad JSON, a path
    // that escapes the sandbox) it returns an @@HOSTERR@@ envelope string rather than throwing across
    // the bridge, matching the fs functions.
    //
    private func runMediaTool(argvJson: String, run: ([String]) -> ToolResult) -> String {
        do {
            guard let data = argvJson.data(using: .utf8),
                  let rawArgv = try JSONSerialization.jsonObject(with: data) as? [String] else {
                throw HostFsError.message("media tool: invalid argv JSON")
            }

            let resolvedArgv = try rawArgv.map { try HostBridge.resolveMediaToken(root: self.storageRoot, token: $0) }
            let result = run(resolvedArgv)
            let output = HostBridge.jsonEscape(result.output)
            return "{\"exitCode\":\(result.exitCode),\"output\":\"\(output)\"}"
        }
        catch {
            return HostBridge.hostErrorEnvelope(error)
        }
    }

    //
    // Resolves a single argv token. A token that names a sandbox-relative path (it contains a path
    // separator, optionally after an ImageMagick "encoder:" prefix like "jpeg:tmp/out.jpg") is
    // resolved to its absolute path under the storage root via PathSandbox, so the native tool reads
    // and writes real files; the sandbox rejects absolute paths and `..` traversal. Non-path tokens
    // (flags, geometry, "info:", "histogram:info:") are returned unchanged.
    //
    static func resolveMediaToken(root: URL, token: String) throws -> String {
        // Split an optional "encoder:" prefix, keeping it only when a real path (with a separator)
        // follows it, so "info:" / "histogram:info:" are left untouched.
        var prefix = ""
        var pathPart = token
        if let colon = token.firstIndex(of: ":") {
            let after = token.index(after: colon)
            if token[after...].contains("/") {
                prefix = String(token[...colon])
                pathPart = String(token[after...])
            }
        }

        if !pathPart.contains("/") {
            return token
        }

        let resolved = try PathSandbox.resolveWithin(root: root, candidate: pathPart)
        return prefix + resolved.path
    }

    //
    // How many bytes are read from the file at a time while hashing it.
    //
    // The file is streamed rather than read whole because a photo or a video can be far larger than
    // anything else this bridge handles, and reading one into memory to hash it would put the whole
    // of it in memory for no benefit: the digest is the same either way.
    //
    private static let sha256ReadBufferBytes = 1024 * 1024

    //
    // host.sha256(path): hashes the file at the sandboxed storage path and returns the digest as
    // lower-case hex, or nil when there is no such file.
    //
    // This exists because the embedded JS engine's pure-JS SHA-256 hashes at well under a megabyte a
    // second on a phone, while the platform's own runs at hundreds, and automatic import is almost
    // entirely hashing on a bare scan. The path is taken rather than the bytes so that nothing
    // crosses the bridge: a streaming hash driven from JS would send every chunk over as base64 and
    // could easily be slower than the JS it replaced.
    //
    // The digest must match what Node's crypto.createHash("sha256") produces byte for byte. These
    // digests are the identity of every asset and the key of the hash cache, so a digest that
    // differed anywhere would make every existing database look wrong, silently.
    //
    func sha256(path: String) throws -> String? {
        let resolved = try PathSandbox.resolveWithin(root: storageRoot, candidate: path)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }

        let handle = try FileHandle(forReadingFrom: resolved)
        defer {
            try? handle.close()
        }

        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        while true {
            let chunk = handle.readData(ofLength: HostBridge.sha256ReadBufferBytes)
            if chunk.isEmpty {
                break
            }
            chunk.withUnsafeBytes { rawBuffer in
                _ = CC_SHA256_Update(&context, rawBuffer.baseAddress, CC_LONG(rawBuffer.count))
            }
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)

        return digest.map { byte in
            String(format: "%02x", byte)
        }.joined()
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
    // The destination is deliberately NOT removed first. Storage writes are write-to-.tmp-then-rename,
    // so removing the destination left the real path missing for a moment and a concurrent reader that
    // had already passed its access check then got ENOENT from stat, which made reads of databases.toml
    // fail intermittently. The Android fix cannot be copied across: moveItem fails when the destination
    // exists, so simply dropping removeItem would break the overwrite. replaceItemAt is the atomic
    // replace and requires an existing destination, so each case takes the call that fits it.
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
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        }
        else {
            try fileManager.moveItem(at: source, to: destination)
        }
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
