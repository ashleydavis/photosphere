import XCTest
@testable import App

//
// Tests the asset-export temp lifecycle helpers, mirroring the Android ExportTempTest. They assert
// the parts either side of the (untestable) UIActivityViewController sheet: the sandbox temp path
// stays inside PathSandbox, the completion path deletes the temp on every exit (shared, cancelled,
// error), cancel yields nil while success yields the path, and the start-up sweep removes an orphan.
//
final class ExportTempTests: XCTestCase {

    //
    // A fresh temporary storage root per test, standing in for the app's Documents directory.
    //
    private var storageRoot: URL!

    //
    // Creates a unique temporary directory to act as the storage root.
    //
    override func setUpWithError() throws {
        storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    //
    // Removes the temporary storage root after each test.
    //
    override func tearDownWithError() throws {
        if let storageRoot = storageRoot {
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }

    //
    // The export temp path the frontend builds resolves to a location inside the storage root.
    //
    func testTempPathStaysInsideSandbox() throws {
        let relativePath = "\(ExportTemp.exportTempDir)/uuid-1/cat.jpeg"
        let resolved = try PathSandbox.resolveWithin(root: storageRoot, candidate: relativePath)
        let canonicalRoot = storageRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalResolved = resolved.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(canonicalResolved.hasPrefix(canonicalRoot))
        XCTAssertEqual(resolved.lastPathComponent, "cat.jpeg")
    }

    //
    // finishExport on the shared exit deletes the temp copy (and its empty per-export dir) and returns
    // the exported path, and the written bytes match what was staged.
    //
    func testFinishExportSharedDeletesTempAndReturnsPath() throws {
        let relativePath = try writeTemp(subPath: "uuid-a/cat.jpeg", text: "the decrypted original bytes")
        let resolved = storageRoot.appendingPathComponent(relativePath)
        XCTAssertEqual(try String(contentsOf: resolved, encoding: .utf8), "the decrypted original bytes")

        let result = ExportTemp.finishExport(root: storageRoot, relativePath: relativePath, cancelled: false)

        XCTAssertEqual(result, relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
        let perExportDir = storageRoot.appendingPathComponent("\(ExportTemp.exportTempDir)/uuid-a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: perExportDir.path))
    }

    //
    // finishExport on the cancelled exit deletes the temp copy and returns nil.
    //
    func testFinishExportCancelledDeletesTempAndReturnsNil() throws {
        let relativePath = try writeTemp(subPath: "uuid-b/cat.jpeg", text: "bytes")
        let resolved = storageRoot.appendingPathComponent(relativePath)

        let result = ExportTemp.finishExport(root: storageRoot, relativePath: relativePath, cancelled: true)

        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resolved.path))
    }

    //
    // finishExportBatch deletes every temp copy on the shared exit and returns the paths.
    //
    func testFinishExportBatchSharedDeletesAllAndReturnsPaths() throws {
        let first = try writeTemp(subPath: "uuid-c/a.jpeg", text: "a")
        let second = try writeTemp(subPath: "uuid-c/b.png", text: "bb")

        let result = ExportTemp.finishExportBatch(root: storageRoot, relativePaths: [first, second], cancelled: false)

        XCTAssertEqual(result, [first, second])
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.appendingPathComponent(first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.appendingPathComponent(second).path))
    }

    //
    // finishExportBatch deletes every temp copy on the cancelled exit and returns nil.
    //
    func testFinishExportBatchCancelledDeletesAllAndReturnsNil() throws {
        let first = try writeTemp(subPath: "uuid-d/a.jpeg", text: "a")
        let second = try writeTemp(subPath: "uuid-d/b.png", text: "bb")

        let result = ExportTemp.finishExportBatch(root: storageRoot, relativePaths: [first, second], cancelled: true)

        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.appendingPathComponent(first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.appendingPathComponent(second).path))
    }

    //
    // The start-up sweep removes an orphaned temp copy left by a kill mid-sheet.
    //
    func testSweepRemovesOrphanedTemp() throws {
        _ = try writeTemp(subPath: "uuid-orphan/cat.jpeg", text: "left behind")
        let exportRoot = storageRoot.appendingPathComponent(ExportTemp.exportTempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportRoot.path))

        ExportTemp.sweep(root: storageRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: exportRoot.path))
    }

    //
    // Writes a temp file at "<exportTempDir>/<subPath>" with the given text and returns its
    // sandbox-relative path.
    //
    private func writeTemp(subPath: String, text: String) throws -> String {
        let relativePath = "\(ExportTemp.exportTempDir)/\(subPath)"
        let fileURL = storageRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        return relativePath
    }
}
