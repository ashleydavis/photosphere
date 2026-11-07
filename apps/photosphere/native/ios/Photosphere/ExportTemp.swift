//
// The lifecycle of the temporary copies an export hands out. A download writes a finished file to a temp path under exportTempDir, the
// native share sheet (UIActivityViewController) hands that file out, and the temp copy is then deleted on every sheet exit (shared,
// cancelled, error). These helpers own the delete on exit, the folder an export's files are written into, and the start-up sweep. They
// are free of UIKit.
//

import Foundation

// The temp files of exports, under the storage root.
enum ExportTemp {
    // The storage-relative directory a download's finished bytes are written to before the export sheet hands them out. Swept on
    // start-up to collect any temp left by a kill mid-sheet.
    static let exportTempDir = ".export-tmp"

    // Deletes one temp file (resolved through PathSandbox so a hostile path cannot escape the storage root) and removes its now-empty
    // per-export parent directory when that parent sits under exportTempDir. A missing file is not an error: cleanup is idempotent.
    static func deleteTemp(root: URL, relativePath: String) throws {
        let resolved = try PathSandbox.resolveWithin(root: root, candidate: relativePath)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: resolved.path) {
            try fileManager.removeItem(at: resolved)
        }

        let parent = resolved.deletingLastPathComponent()
        let exportRoot = root.appendingPathComponent(exportTempDir)
        if isUnder(root: exportRoot, candidate: parent) && parent.standardizedFileURL != exportRoot.standardizedFileURL {
            let remaining = try fileManager.contentsOfDirectory(atPath: parent.path)
            if remaining.isEmpty {
                try fileManager.removeItem(at: parent)
            }
        }
    }

    // Makes the folder one export's files are written into and returns it. The save tasks write to an absolute path in a folder that
    // exists, so the page asks for the folder first. The folder is resolved through PathSandbox and must sit under exportTempDir, so a
    // request cannot make a folder anywhere else in the storage root.
    static func prepareFolder(root: URL, relativeFolder: String) throws -> URL {
        let folder = try PathSandbox.resolveWithin(root: root, candidate: relativeFolder)
        let exportRoot = root.appendingPathComponent(exportTempDir)
        if !isUnder(root: exportRoot, candidate: folder) || folder.standardizedFileURL == exportRoot.standardizedFileURL {
            throw ExportTempError.folderOutsideExportDirectory(relativeFolder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // Reads the outcome a test staged for an export in place of the share sheet: "shared" completes as if the user shared the files and
    // "cancelled" as if they backed out. Returns true for cancelled. Any other word is an error, so a mistyped outcome fails the test
    // loudly instead of being taken for one of the two.
    static func isCancelledTestOutcome(_ testOutcome: String) throws -> Bool {
        if testOutcome == "cancelled" {
            return true
        }
        if testOutcome == "shared" {
            return false
        }
        throw ExportTempError.unknownTestOutcome(testOutcome)
    }

    // Finishes a single-file export: deletes the temp copy (on every exit: shared, cancelled, error) and returns the exported
    // storage-relative path on success, or nil when the user cancelled the sheet. The page maps nil to its "cancelled" contract.
    static func finishExport(root: URL, relativePath: String, cancelled: Bool) throws -> String? {
        try deleteTemp(root: root, relativePath: relativePath)
        return cancelled ? nil : relativePath
    }

    // Finishes a batch export: deletes every temp copy (on every exit) and returns the exported storage-relative paths on success, or
    // nil when the user cancelled the sheet.
    static func finishExportBatch(root: URL, relativePaths: [String], cancelled: Bool) throws -> [String]? {
        for relativePath in relativePaths {
            try deleteTemp(root: root, relativePath: relativePath)
        }
        return cancelled ? nil : relativePaths
    }

    // Removes the whole export temp directory and its contents on app start-up, collecting any temp copy orphaned by a process kill
    // that happened while the export sheet was still up. A missing directory is not an error.
    static func sweep(root: URL) throws {
        let exportRoot = root.appendingPathComponent(exportTempDir)
        if FileManager.default.fileExists(atPath: exportRoot.path) {
            try FileManager.default.removeItem(at: exportRoot)
        }
    }

    // Reports whether candidate is the given root or sits beneath it, comparing canonicalised paths so a symlink or `.` segment cannot
    // slip a sibling directory past the check.
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

// What can go wrong preparing or finishing an export.
enum ExportTempError: Error, CustomStringConvertible {
    // An export folder was asked for outside the export temp directory.
    case folderOutsideExportDirectory(String)

    // A staged export outcome that is neither "shared" nor "cancelled".
    case unknownTestOutcome(String)

    var description: String {
        switch self {
        case .folderOutsideExportDirectory(let folder):
            return "An export folder must be inside \(ExportTemp.exportTempDir): \(folder)"
        case .unknownTestOutcome(let outcome):
            return "The staged export outcome \"\(outcome)\" is not \"shared\" or \"cancelled\"."
        }
    }
}
