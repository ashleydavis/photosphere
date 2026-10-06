//
// Native file and folder pickers. The core asks for one from a worker thread. The dialog is shown on the main thread and the
// worker waits for the user, so the main thread is never blocked. On MacOS these are NSOpenPanel and NSSavePanel.
//

import Foundation
import WebKit
import CZiggy
import AppKit

// What the user did with a picker.
enum ZiggyPickOutcome {
    // The paths they chose, empty when they cancelled.
    case chosen([String])
    // The picker could not be shown or could not give a path, with the reason.
    case failed(String)
}

// Carries the outcome from the main thread, where the dialog runs, to the worker thread that waits for it.
final class ZiggyPickAnswer {
    // The outcome, set on the main thread before the semaphore is signalled and read on the worker after it.
    var outcome: ZiggyPickOutcome?
}

// Shows pickers for the core's pick_paths callback.
enum ZiggyPicker {
    // The core's pick_paths callback, for a worker thread. Shows the dialog on the main thread, waits for the user, and
    // writes the chosen paths into the buffer as a JSON array of strings ("[]" when they cancelled). Returns the number of
    // bytes written, or -1 after printing why it could not.
    static func pickPaths(webView: WKWebView, kind: Int32, title: String?, initialName: String?, buffer: UnsafeMutablePointer<CChar>, capacity: Int) -> Int {
        if Thread.isMainThread {
            ZiggyBridge.report("a picker was asked for on the main thread, which would wait for itself")
            return -1
        }
        let answer = ZiggyPickAnswer()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            ZiggyPicker.present(webView: webView, kind: kind, title: title, initialName: initialName) { outcome in
                answer.outcome = outcome
                semaphore.signal()
            }
        }
        semaphore.wait()
        guard let outcome = answer.outcome else {
            ZiggyBridge.report("the picker finished without an outcome")
            return -1
        }
        switch outcome {
        case .failed(let reason):
            ZiggyBridge.report("the picker failed: \(reason)")
            return -1
        case .chosen(let paths):
            let bytes: Data
            do {
                bytes = try JSONEncoder().encode(paths)
            }
            catch {
                ZiggyBridge.report("could not write the chosen paths as JSON: \(error)")
                return -1
            }
            if bytes.count > capacity {
                ZiggyBridge.report("the chosen paths need \(bytes.count) bytes and the core's buffer holds \(capacity)")
                return -1
            }
            bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer, count: capacity).bindMemory(to: UInt8.self), count: bytes.count)
            return bytes.count
        }
    }

    // Runs on the main thread: shows the panel for the kind, which blocks the main thread inside the panel's own event loop
    // until the user answers, then reports the outcome.
    private static func present(webView: WKWebView, kind: Int32, title: String?, initialName: String?, completion: @escaping (ZiggyPickOutcome) -> Void) {
        let panel: NSSavePanel
        switch Int(kind) {
        case Int(ZIGGY_PICK_OPEN_FILES):
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = true
            openPanel.canChooseDirectories = false
            openPanel.allowsMultipleSelection = true
            panel = openPanel
        case Int(ZIGGY_PICK_FOLDER):
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = false
            openPanel.canChooseDirectories = true
            openPanel.allowsMultipleSelection = false
            openPanel.canCreateDirectories = true
            panel = openPanel
        case Int(ZIGGY_PICK_SAVE_FILE):
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = initialName ?? ""
            panel = savePanel
        default:
            completion(.failed("unknown picker kind \(kind)"))
            return
        }
        if let title = title {
            panel.title = title
            panel.message = title
        }
        if panel.runModal() != .OK {
            completion(.chosen([]))
            return
        }
        if let openPanel = panel as? NSOpenPanel {
            completion(.chosen(openPanel.urls.map { $0.path }))
            return
        }
        guard let url = panel.url else {
            completion(.failed("the save panel was accepted with no file"))
            return
        }
        completion(.chosen([url.path]))
    }
}

