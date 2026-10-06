//
// Native file and folder pickers. The core asks for one from a worker thread. The dialog is shown on the main thread and the
// worker waits for the user, so the main thread is never blocked. The dialogs are UIDocumentPickerViewController, which can open
// files and choose a folder but has no dialog for choosing where to save.
//

import Foundation
import WebKit
import CZiggy
import UIKit
import UniformTypeIdentifiers

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

    // Runs on the main thread: presents a document picker over the web view's window and reports the outcome from its
    // delegate. Saving has no iOS dialog, so it fails.
    private static func present(webView: WKWebView, kind: Int32, title: String?, initialName: String?, completion: @escaping (ZiggyPickOutcome) -> Void) {
        let picker: UIDocumentPickerViewController
        switch Int(kind) {
        case Int(ZIGGY_PICK_OPEN_FILES):
            // asCopy gives the app copies in its temporary directory, which it can read without any access to the originals.
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.item], asCopy: true)
            picker.allowsMultipleSelection = true
        case Int(ZIGGY_PICK_FOLDER):
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        case Int(ZIGGY_PICK_SAVE_FILE):
            completion(.failed("iOS has no dialog for choosing where to save a file"))
            return
        default:
            completion(.failed("unknown picker kind \(kind)"))
            return
        }
        guard var presenter = webView.window?.rootViewController else {
            completion(.failed("the web view is not in a window with a root view controller"))
            return
        }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        if let title = title {
            picker.title = title
        }
        let delegate = ZiggyPickerDelegate(isFolder: Int(kind) == Int(ZIGGY_PICK_FOLDER), completion: completion)
        picker.delegate = delegate
        delegate.keepAlive = delegate
        presenter.present(picker, animated: true)
    }
}

// Receives a document picker's answer. The picker holds its delegate weakly, so this keeps itself alive until it has answered.
final class ZiggyPickerDelegate: NSObject, UIDocumentPickerDelegate {
    // Whether the picker chose a folder, whose access must be started, rather than copies of files.
    private let isFolder: Bool

    // Reports the outcome.
    private let completion: (ZiggyPickOutcome) -> Void

    // Set to this object while the picker is showing, and cleared after it answers.
    var keepAlive: ZiggyPickerDelegate?

    // Creates the delegate for one picker.
    init(isFolder: Bool, completion: @escaping (ZiggyPickOutcome) -> Void) {
        self.isFolder = isFolder
        self.completion = completion
        super.init()
    }

    // The user chose something.
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        keepAlive = nil
        if isFolder {
            guard let folder = urls.first else {
                completion(.failed("the folder picker returned no folder"))
                return
            }
            // Access to the folder lasts until the process ends, because nothing calls stopAccessingSecurityScopedResource.
            if !folder.startAccessingSecurityScopedResource() {
                completion(.failed("could not start accessing the folder \(folder.path)"))
                return
            }
        }
        completion(.chosen(urls.map { $0.path }))
    }

    // The user cancelled, which is a normal answer of no paths.
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        keepAlive = nil
        completion(.chosen([]))
    }
}
