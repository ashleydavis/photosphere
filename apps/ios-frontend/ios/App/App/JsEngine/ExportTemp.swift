import Foundation

//
// Pure helpers for the asset-export flow's sandbox-temp lifecycle, mirroring the Android ExportTemp.
// A download writes a decrypted original to a sandbox temp path under exportTempDir, the native share
// sheet (UIActivityViewController) hands that file out, and the temp copy is then deleted on every
// sheet exit (shared, cancelled, error). These helpers own the delete-on-exit and the start-up sweep,
// kept free of UIKit so they can be unit-tested (the UIActivityViewController presentation cannot).
//
enum ExportTemp {

    //
    // The sandbox-relative directory a download's finished bytes are written to before the export
    // sheet hands them out. Swept on start-up to collect any temp left by a kill mid-sheet.
    //
    static let exportTempDir = ".export-tmp"

    //
    // Deletes one sandbox temp file (resolved through PathSandbox so a hostile path cannot escape the
    // storage root) and removes its now-empty per-export parent directory when that parent sits under
    // exportTempDir. A missing file is not an error: cleanup is idempotent.
    //
    static func deleteTemp(root: URL, relativePath: String) {
        guard let resolved = try? PathSandbox.resolveWithin(root: root, candidate: relativePath) else {
            return
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: resolved.path) {
            try? fileManager.removeItem(at: resolved)
        }

        let parent = resolved.deletingLastPathComponent()
        let exportRoot = root.appendingPathComponent(exportTempDir)
        if isUnder(root: exportRoot, candidate: parent) && parent.standardizedFileURL != exportRoot.standardizedFileURL {
            let remaining = (try? fileManager.contentsOfDirectory(atPath: parent.path)) ?? []
            if remaining.isEmpty {
                try? fileManager.removeItem(at: parent)
            }
        }
    }

    //
    // Finishes a single-file export: deletes the temp copy (on every exit: shared, cancelled, error)
    // and returns the exported sandbox-relative path on success, or nil when the user cancelled the
    // sheet. The frontend maps nil to its "cancelled" undefined contract.
    //
    static func finishExport(root: URL, relativePath: String, cancelled: Bool) -> String? {
        deleteTemp(root: root, relativePath: relativePath)
        return cancelled ? nil : relativePath
    }

    //
    // Finishes a batch export: deletes every temp copy (on every exit) and returns the exported
    // sandbox-relative paths on success, or nil when the user cancelled the sheet.
    //
    static func finishExportBatch(root: URL, relativePaths: [String], cancelled: Bool) -> [String]? {
        for relativePath in relativePaths {
            deleteTemp(root: root, relativePath: relativePath)
        }
        return cancelled ? nil : relativePaths
    }

    //
    // Removes the whole export temp directory and its contents on app start-up, collecting any temp
    // copy orphaned by a process kill that happened while the export sheet was still up.
    //
    static func sweep(root: URL) {
        let exportRoot = root.appendingPathComponent(exportTempDir)
        try? FileManager.default.removeItem(at: exportRoot)
    }

    //
    // Reports whether candidate is the given root or sits beneath it, comparing canonicalised paths so
    // a symlink or `.` segment cannot slip a sibling directory past the check.
    //
    private static func isUnder(root: URL, candidate: URL) -> Bool {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        if canonicalCandidate == canonicalRoot {
            return true
        }
        let rootWithSeparator = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        return canonicalCandidate.hasPrefix(rootWithSeparator)
    }
}
