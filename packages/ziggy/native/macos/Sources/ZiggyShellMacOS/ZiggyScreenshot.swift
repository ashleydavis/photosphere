//
// Screenshots for the test control connection. The core asks for one from the thread of the control connection. The snapshot is
// taken on the main thread, with the web view's own takeSnapshot, and the connection's thread waits for the file to be written.
//

import Foundation
import WebKit
import CZiggy
import AppKit

// Carries the outcome from the main thread, where the snapshot is taken, to the thread that waits for it.
final class ZiggyScreenshotAnswer {
    // Why the picture could not be written, or nil when it was. Set on the main thread before the semaphore is signalled and read
    // by the waiting thread after it.
    var failure: String?
}

// Takes screenshots for the core's screenshot callback.
enum ZiggyScreenshot {
    // The core's screenshot callback. Writes a PNG of the web view to the path, waits until the file is written and returns 0.
    // When it cannot, it writes the reason into the buffer and returns the number of bytes written, negated.
    static func write(webView: WKWebView, path: String, buffer: UnsafeMutablePointer<CChar>, capacity: Int) -> Int {
        if Thread.isMainThread {
            return reply(failure: "a screenshot was asked for on the main thread, which would wait for itself", buffer: buffer, capacity: capacity)
        }
        let answer = ZiggyScreenshotAnswer()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            webView.takeSnapshot(with: nil) { image, error in
                answer.failure = ZiggyScreenshot.save(image: image, error: error, path: path)
                semaphore.signal()
            }
        }
        semaphore.wait()
        return reply(failure: answer.failure, buffer: buffer, capacity: capacity)
    }

    // Writes the snapshot to the path as a PNG, and returns nil when it worked or the reason it did not.
    static func save(image: NSImage?, error: Error?, path: String) -> String? {
        if let error = error {
            return "the web view could not make a snapshot: \(error.localizedDescription)"
        }
        guard let image = image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            return "the web view's snapshot has no pixels"
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return "the snapshot could not be encoded as a PNG"
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        }
        catch {
            return "could not write the screenshot to \(path): \(error.localizedDescription)"
        }
        return nil
    }

    // Turns a failure into what the callback returns: 0 for none, otherwise the reason is copied into the buffer, cut to fit, and
    // its length is returned negated.
    static func reply(failure: String?, buffer: UnsafeMutablePointer<CChar>, capacity: Int) -> Int {
        guard let failure = failure else {
            return 0
        }
        let bytes = Array(failure.utf8.prefix(capacity))
        memcpy(buffer, bytes, bytes.count)
        return -bytes.count
    }
}
