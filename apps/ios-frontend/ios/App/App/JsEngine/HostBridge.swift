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
}
