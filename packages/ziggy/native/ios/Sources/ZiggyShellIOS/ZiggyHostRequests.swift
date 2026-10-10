//
// How an app's own iOS code answers the core's host requests: the things only the platform can do (a permission prompt, the
// keychain, a share sheet), each named by a method. The core knows no method names, they are the app's and its handler's. The app
// gives its handler to ZiggyBridge.setHostRequestHandler before ZiggyBridge.start.
//

import Foundation

// What a ZiggyHostRequestHandler throws when it cannot do what a host request asked. The reason is in words the user can act on, and it
// is passed to the core as the failure text of the request.
public struct ZiggyHostRequestError: Error {
    // Why the request could not be done.
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

// Answers the core's host requests for the app.
public protocol ZiggyHostRequestHandler: AnyObject {
    // Does what the method names with the JSON text of its argument and returns the JSON text of the answer. It is called on a worker
    // thread of the core, never the main thread, and may block for as long as it takes, for instance to wait for a permission dialog.
    // It throws ZiggyHostRequestError, with the reason in words the user can act on, for a method it does not know or cannot do.
    func handle(method: String, requestJson: String) throws -> String
}

// How a host request's answer is handed to the core: the text goes into the buffer the core gave, and the number returned is its
// length, negated when the request failed and the text is the reason.
enum ZiggyHostReply {
    // Runs the handler for one request and writes its answer, or the reason it failed, into the core's buffer. Returns what the
    // core's host request callback returns.
    static func answer(handler: ZiggyHostRequestHandler, method: String, requestJson: String, buffer: UnsafeMutablePointer<CChar>, capacity: Int) -> Int {
        do {
            let answerJson = try handler.handle(method: method, requestJson: requestJson)
            return write(succeeded: true, method: method, text: answerJson, buffer: buffer, capacity: capacity)
        }
        catch let failure as ZiggyHostRequestError {
            return write(succeeded: false, method: method, text: failure.reason, buffer: buffer, capacity: capacity)
        }
        catch {
            return write(succeeded: false, method: method, text: "The host request \(method) failed: \(error)", buffer: buffer, capacity: capacity)
        }
    }

    // Writes the text into the buffer. An answer that succeeded but is longer than the buffer cannot be handed over, so it is reported
    // as a failure that names the request, and a reason longer than the buffer is cut to fit.
    static func write(succeeded: Bool, method: String, text: String, buffer: UnsafeMutablePointer<CChar>, capacity: Int) -> Int {
        let bytes = Array(text.utf8)
        if succeeded && bytes.count <= capacity {
            copy(bytes, count: bytes.count, into: buffer)
            return bytes.count
        }
        if succeeded {
            let reason = Array("The answer to \(method) is too long for the core to take.".utf8)
            let length = min(reason.count, capacity)
            copy(reason, count: length, into: buffer)
            return -length
        }
        let length = min(bytes.count, capacity)
        copy(bytes, count: length, into: buffer)
        return -length
    }

    // Copies the first bytes of an array into the buffer.
    private static func copy(_ bytes: [UInt8], count: Int, into buffer: UnsafeMutablePointer<CChar>) {
        bytes.withUnsafeBytes { source in
            if let base = source.baseAddress, count > 0 {
                memcpy(buffer, base, count)
            }
        }
    }
}
