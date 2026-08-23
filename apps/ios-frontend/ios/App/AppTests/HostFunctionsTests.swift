import XCTest
import JavaScriptCore
@testable import App

//
// Tests the native fs READ host functions on iOS: reading bytes (base64), existence, stat, and
// directory listing against a temporary sandbox root, plus the path-sandbox rejections and the
// JS-installed round trip. Mirrors the Android HostFunctionsTest so both platforms are proven to
// behave identically.
//
final class HostFunctionsTests: XCTestCase {

    //
    // The temporary storage root the bridge is sandboxed to, created fresh per test.
    //
    private var storageRoot: URL!

    //
    // The bridge under test, sandboxed to storageRoot.
    //
    private var bridge: HostBridge!

    //
    // Creates a unique temporary storage root and a bridge sandboxed to it.
    //
    override func setUpWithError() throws {
        storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        bridge = HostBridge(
            sessionId: "session-1",
            storageRoot: storageRoot,
            isCancelledProvider: { _ in false },
            messageSink: { _, _ in },
            queueTaskSink: { _, _, _, _, _, _ in }
        )
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
    // Writes bytes to a file under the storage root, creating parent directories as needed.
    //
    private func writeFile(_ relativePath: String, _ bytes: [UInt8]) throws {
        let target = storageRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: target)
    }

    //
    // fsReadFile returns base64 that decodes back to the original bytes.
    //
    func testFsReadFileReturnsBase64OfContents() throws {
        let content: [UInt8] = [0, 1, 2, 200, 255, 42]
        try writeFile("db/data.bin", content)

        let base64 = try bridge.fsReadFile(path: "db/data.bin")
        XCTAssertNotNil(base64)
        let decoded = Data(base64Encoded: base64!)
        XCTAssertEqual(decoded.map { Array($0) }, content)
    }

    //
    // fsReadFile returns nil for a missing file and for a directory.
    //
    func testFsReadFileReturnsNilForMissingOrDirectory() throws {
        try FileManager.default.createDirectory(at: storageRoot.appendingPathComponent("db"), withIntermediateDirectories: true)
        XCTAssertNil(try bridge.fsReadFile(path: "db/missing.bin"))
        XCTAssertNil(try bridge.fsReadFile(path: "db"))
    }

    //
    // fsAccess reflects existence of files and directories.
    //
    func testFsAccessReflectsExistence() throws {
        try writeFile("db/a.txt", Array("x".utf8))
        XCTAssertTrue(try bridge.fsAccess(path: "db/a.txt"))
        XCTAssertTrue(try bridge.fsAccess(path: "db"))
        XCTAssertFalse(try bridge.fsAccess(path: "db/missing"))
    }

    //
    // fsStat reports size and type predicates for a file and a directory, and nil when missing.
    //
    func testFsStatReportsFieldsAndNilWhenMissing() throws {
        try writeFile("db/a.txt", Array("hello".utf8))

        let fileStat = try bridge.fsStat(path: "db/a.txt")
        XCTAssertNotNil(fileStat)
        XCTAssertTrue(fileStat!.contains("\"size\":5"))
        XCTAssertTrue(fileStat!.contains("\"isFile\":true"))
        XCTAssertTrue(fileStat!.contains("\"isDirectory\":false"))

        let dirStat = try bridge.fsStat(path: "db")
        XCTAssertNotNil(dirStat)
        XCTAssertTrue(dirStat!.contains("\"isDirectory\":true"))
        XCTAssertTrue(dirStat!.contains("\"isFile\":false"))

        XCTAssertNil(try bridge.fsStat(path: "db/missing"))
    }

    //
    // fsReaddir lists entries with their directory flag, and returns nil for a missing directory.
    //
    func testFsReaddirListsEntries() throws {
        try writeFile("db/a.txt", Array("a".utf8))
        try FileManager.default.createDirectory(at: storageRoot.appendingPathComponent("db/sub"), withIntermediateDirectories: true)

        let listing = try bridge.fsReaddir(path: "db")
        XCTAssertNotNil(listing)
        XCTAssertTrue(listing!.contains("\"name\":\"a.txt\""))
        XCTAssertTrue(listing!.contains("\"name\":\"sub\",\"isDirectory\":true"))

        XCTAssertNil(try bridge.fsReaddir(path: "db/missing"))
    }

    //
    // Path sandbox rejection: absolute paths and `..` traversal must throw before any IO.
    //
    func testFsFunctionsRejectAbsoluteAndTraversalPaths() {
        XCTAssertThrowsError(try bridge.fsReadFile(path: "/etc/passwd"))
        XCTAssertThrowsError(try bridge.fsReadFile(path: "../escape"))
        XCTAssertThrowsError(try bridge.fsAccess(path: "/etc"))
        XCTAssertThrowsError(try bridge.fsStat(path: "../../escape"))
    }

    //
    // fsWriteFile writes base64-decoded bytes, creating parent directories, and the file reads back.
    //
    func testFsWriteFileWritesBytesAndCreatesParents() throws {
        let content: [UInt8] = [9, 8, 7, 254, 0, 33]
        try bridge.fsWriteFile(path: "db/nested/out.bin", base64: Data(content).base64EncodedString(), exclusive: false)

        let readBack = try bridge.fsReadFile(path: "db/nested/out.bin")
        XCTAssertEqual(Data(base64Encoded: readBack ?? "").map { Array($0) }, content)
    }

    //
    // fsWriteFile with exclusive=true throws an EEXIST-marked error when the file already exists.
    //
    func testFsWriteFileExclusiveThrowsWhenPresent() throws {
        try bridge.fsWriteFile(path: "db/lock", base64: Data("a".utf8).base64EncodedString(), exclusive: true)
        XCTAssertThrowsError(try bridge.fsWriteFile(path: "db/lock", base64: Data("b".utf8).base64EncodedString(), exclusive: true)) { error in
            XCTAssertTrue("\(error)".contains("EEXIST"))
        }
    }

    //
    // fsMkdir creates nested directories and is idempotent.
    //
    func testFsMkdirCreatesRecursivelyAndIsIdempotent() throws {
        try bridge.fsMkdir(path: "db/a/b/c", recursive: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageRoot.appendingPathComponent("db/a/b/c").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        // Idempotent.
        try bridge.fsMkdir(path: "db/a/b/c", recursive: true)
    }

    //
    // fsRename moves a file and overwrites an existing destination.
    //
    func testFsRenameMovesAndOverwrites() throws {
        try writeFile("db/src.txt", Array("source".utf8))
        try writeFile("db/dest.txt", Array("old".utf8))
        try bridge.fsRename(srcPath: "db/src.txt", destPath: "db/dest.txt")

        XCTAssertFalse(try bridge.fsAccess(path: "db/src.txt"))
        let readBack = try bridge.fsReadFile(path: "db/dest.txt")
        XCTAssertEqual(Data(base64Encoded: readBack ?? "").map { String(decoding: $0, as: UTF8.self) }, "source")
    }

    //
    // fsUnlink deletes a file and throws when it is missing.
    //
    func testFsUnlinkDeletesAndThrowsWhenMissing() throws {
        try writeFile("db/a.txt", Array("x".utf8))
        try bridge.fsUnlink(path: "db/a.txt")
        XCTAssertFalse(try bridge.fsAccess(path: "db/a.txt"))
        XCTAssertThrowsError(try bridge.fsUnlink(path: "db/a.txt"))
    }

    //
    // fsRm removes a directory tree; with force a missing path is a no-op.
    //
    func testFsRmRemovesTreeAndForceIgnoresMissing() throws {
        try writeFile("db/sub/a.txt", Array("a".utf8))
        try writeFile("db/sub/b.txt", Array("b".utf8))
        try bridge.fsRm(path: "db/sub", recursive: true, force: false)
        XCTAssertFalse(try bridge.fsAccess(path: "db/sub"))
        try bridge.fsRm(path: "db/missing", recursive: true, force: true)
    }

    //
    // hostErrorEnvelope encodes the error message with the recognised code so the JS shim decodes it.
    //
    func testHostErrorEnvelope() {
        XCTAssertEqual(HostBridge.hostErrorEnvelope(HostFsError.exists("x")), "@@HOSTERR@@EEXIST:EEXIST: file already exists: x")
        XCTAssertEqual(HostBridge.hostErrorEnvelope(HostFsError.message("ENOENT: missing")), "@@HOSTERR@@ENOENT:ENOENT: missing")
        XCTAssertEqual(HostBridge.hostErrorEnvelope(HostFsError.message("some other failure")), "@@HOSTERR@@:some other failure")
    }

    //
    // jsonEscape escapes quotes, backslashes, and control characters.
    //
    func testJsonEscape() {
        XCTAssertEqual(HostBridge.jsonEscape("a\"b"), "a\\\"b")
        XCTAssertEqual(HostBridge.jsonEscape("a\\b"), "a\\\\b")
        XCTAssertEqual(HostBridge.jsonEscape("a\nb"), "a\\nb")
        XCTAssertEqual(HostBridge.jsonEscape("plain.txt"), "plain.txt")
    }

    //
    // The fs functions installed into a JSContext are callable from JS and return the expected values.
    //
    func testFsFunctionsInstalledIntoContext() throws {
        try writeFile("db/a.txt", Array("hi".utf8))

        let context = JSContext()!
        bridge.install(into: context)

        XCTAssertEqual(context.evaluateScript("host.fsAccess('db/a.txt')")?.toBool(), true)
        XCTAssertEqual(context.evaluateScript("host.fsAccess('db/missing')")?.toBool(), false)

        // fsReadFile returns base64 of "hi" (= "aGk=").
        XCTAssertEqual(context.evaluateScript("host.fsReadFile('db/a.txt')")?.toString(), "aGk=")

        // Missing file returns JS null.
        let missing = context.evaluateScript("host.fsReadFile('db/missing')")
        XCTAssertEqual(missing?.isNull, true)
    }
}
