//
// Hands finished files out of the app: exportFile and exportFiles show the system share sheet for the files, and exportTempFolder
// makes the folder an export's files are written into. The download has already written the bytes under the storage root at the
// storage-relative paths in the request. Every exit, whether the files were shared, the user backed out or the sheet failed, removes the
// temporary copies. The core calls from a worker thread and waits, so a request may block on the share sheet.
//

import Foundation
import UIKit
import ZiggyNativeIOS

// The export requests.
final class ExportHostRequests: ZiggyHostRequestHandler {
    // The directory the paths in requests are relative to, which is the app's data directory.
    private let storageRoot: URL

    // The view controller the share sheet is shown over. Called on the main thread.
    private let presenter: () -> UIViewController?

    init(storageRoot: URL, presenter: @escaping () -> UIViewController?) {
        self.storageRoot = storageRoot
        self.presenter = presenter
    }

    // Removes the export temp directory, collecting any copies left by the app being killed while a sheet was on screen.
    func sweep() throws {
        try ExportTemp.sweep(root: storageRoot)
    }

    func handle(method: String, requestJson: String) throws -> String {
        let request = try HostJson.object(from: requestJson, method: method)
        switch method {
        case "exportFile":
            return try exportFile(path: try HostJson.string(request, "path", method: method), testOutcome: request["testOutcome"] as? String)
        case "exportTempFolder":
            return try exportTempFolder(folder: try HostJson.string(request, "folder", method: method))
        case "exportFiles":
            return try exportFiles(paths: try HostJson.strings(request, "paths", method: method), testOutcome: request["testOutcome"] as? String)
        default:
            throw ZiggyHostRequestError("ExportHostRequests does not answer \"\(method)\".")
        }
    }

    // Makes the folder one export's files are written into, so the save task can create files in it, and says where it is.
    private func exportTempFolder(folder: String) throws -> String {
        let made: URL
        do {
            made = try ExportTemp.prepareFolder(root: storageRoot, relativeFolder: folder)
        }
        catch {
            throw ZiggyHostRequestError("exportTempFolder: \(error)")
        }
        let reply: [String: Any] = [
            "path": made.path,
        ]
        return try HostJson.text(from: reply, method: "exportTempFolder")
    }

    // Shows the share sheet for one file, then removes the temporary copy. A request carrying a test outcome skips the sheet and goes
    // straight to the completion path, because the sheet cannot be answered by an automated test.
    private func exportFile(path: String, testOutcome: String?) throws -> String {
        let fileURL = try resolve(path, method: "exportFile")
        let cancelled: Bool
        do {
            if let testOutcome = testOutcome {
                cancelled = try ExportTemp.isCancelledTestOutcome(testOutcome)
            }
            else {
                cancelled = !(try share([fileURL]))
            }
        }
        catch {
            try removeTemps([path], after: error)
            throw error
        }
        let exported = try ExportTemp.finishExport(root: storageRoot, relativePath: path, cancelled: cancelled)
        let reply: [String: Any] = [
            "path": exported ?? NSNull(),
        ]
        return try HostJson.text(from: reply, method: "exportFile")
    }

    // Shows one share sheet for all the files, then removes the temporary copies. A request carrying a test outcome skips the sheet, as
    // for exportFile.
    private func exportFiles(paths: [String], testOutcome: String?) throws -> String {
        let cancelled: Bool
        do {
            var fileURLs: [URL] = []
            for path in paths {
                fileURLs.append(try resolve(path, method: "exportFiles"))
            }
            if let testOutcome = testOutcome {
                cancelled = try ExportTemp.isCancelledTestOutcome(testOutcome)
            }
            else {
                cancelled = !(try share(fileURLs))
            }
        }
        catch {
            try removeTemps(paths, after: error)
            throw error
        }
        let exported = try ExportTemp.finishExportBatch(root: storageRoot, relativePaths: paths, cancelled: cancelled)
        let reply: [String: Any] = [
            "paths": exported ?? NSNull(),
        ]
        return try HostJson.text(from: reply, method: "exportFiles")
    }

    // Confirms a temporary file is inside the sandbox before anything is shown.
    private func resolve(_ path: String, method: String) throws -> URL {
        do {
            return try PathSandbox.resolveWithin(root: storageRoot, candidate: path)
        }
        catch {
            throw ZiggyHostRequestError("\(method): \(error)")
        }
    }

    // Removes the temporary copies when the export failed. If removing them fails as well, the request fails with both reasons, so
    // neither is lost.
    private func removeTemps(_ paths: [String], after failure: Error) throws {
        for path in paths {
            do {
                try ExportTemp.deleteTemp(root: storageRoot, relativePath: path)
            }
            catch {
                throw ZiggyHostRequestError("The export failed (\(failure)) and its temporary copy of \(path) could not be removed (\(error)).")
            }
        }
    }

    // Shows the share sheet for the files on the main thread and waits for it to be dismissed. Returns true when the user completed an
    // action and false when they cancelled it.
    private func share(_ fileURLs: [URL]) throws -> Bool {
        let finished = DispatchSemaphore(value: 0)
        var completed = false
        var failure: String?

        DispatchQueue.main.async {
            guard let presenter = self.presenter() else {
                failure = "There is no screen to show the share sheet on."
                finished.signal()
                return
            }
            let activityController = UIActivityViewController(activityItems: fileURLs, applicationActivities: nil)
            activityController.completionWithItemsHandler = { _, didComplete, _, error in
                if let error = error {
                    failure = "The share sheet failed: \(error.localizedDescription)"
                }
                completed = didComplete
                finished.signal()
            }
            // On iPad the sheet is a popover and needs a source anchor.
            activityController.popoverPresentationController?.sourceView = presenter.view
            presenter.present(activityController, animated: true)
        }
        finished.wait()

        if let failure = failure {
            throw ZiggyHostRequestError(failure)
        }
        return completed
    }
}
