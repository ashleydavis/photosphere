import XCTest
@testable import App

//
// Proves the app can hold its databases.toml on device.
//
// The database list lives in databases.toml at the root of the app's storage sandbox, read and
// written by the read-databases-config / write-databases-config worker tasks. Those tasks reach the
// file through FileStorage, which on device calls the native fs host functions tested here. The
// TypeScript tests cover the TOML itself; what they cannot reach is whether the native layer will
// actually serve a file at that path, which is what these assert.
//
// Mirrors DatabasesConfigFileTest.java on Android, case for case, so a difference between the two
// platforms shows up as one of these failing rather than as a database list that silently does not
// persist on one of them.
//
final class DatabasesConfigFileTests: XCTestCase {

    //
    // The temporary storage root used by each test, standing in for the app's private files
    // directory. Created fresh in setUp and removed in tearDown.
    //
    private var storageRoot: URL!

    //
    // The name the app reads its database list from, relative to the storage root. Must match
    // DATABASES_CONFIG_PATH in packages/mobile-frontend/src/lib/mobile-databases-config-file.ts.
    //
    private let databasesConfig = "databases.toml"

    //
    // A databases config in the format both platforms read and write, holding one of the user's own
    // databases and one seeded test database.
    //
    private let configToml = """
    recent_database_names = [ "My photos" ]

    [[databases]]
    name = "My photos"
    description = "Everything"
    path = "/storage/photos"
    s3_key = "default:s3"

    [[databases]]
    name = "test-50-assets"
    description = ""
    path = "50-assets"

    """

    //
    // Creates a unique temporary directory to act as the storage root for the test.
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
    // Builds a host bridge rooted at the test's storage root, the way the engine builds one per task.
    //
    private func makeBridge() -> HostBridge {
        return HostBridge(
            sessionId: "databases-config-test",
            storageRoot: storageRoot,
            isCancelledProvider: { _ in false },
            messageSink: { _, _ in },
            queueTaskSink: { _, _, _, _, _, _ in }
        )
    }

    //
    // Writes text to a sandbox-relative path through the native write host function, the way the
    // write-databases-config task does.
    //
    private func writeConfig(_ bridge: HostBridge, _ relativePath: String, _ contents: String) throws {
        let base64 = Data(contents.utf8).base64EncodedString()
        try bridge.fsWriteFile(path: relativePath, base64: base64, exclusive: false)
    }

    //
    // Reads a sandbox-relative path through the native read host function and decodes it, the way the
    // read-databases-config task does. Returns nil when the file is not there.
    //
    private func readConfig(_ bridge: HostBridge, _ relativePath: String) throws -> String? {
        guard let base64 = try bridge.fsReadFile(path: relativePath) else {
            return nil
        }
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    //
    // A config written at the sandbox root comes back exactly as written. This is the round trip the
    // app depends on: the write task saves the list, the read task loads it on the next start.
    //
    func testDatabasesConfigRoundTripsAtTheSandboxRoot() throws {
        let bridge = makeBridge()
        try writeConfig(bridge, databasesConfig, configToml)

        XCTAssertEqual(configToml, try readConfig(bridge, databasesConfig))
    }

    //
    // The file lands where the sandbox says it should, at the root of the app's storage directory
    // rather than anywhere else under it.
    //
    func testDatabasesConfigIsWrittenAtTheRootOfTheStorageDirectory() throws {
        let bridge = makeBridge()
        try writeConfig(bridge, databasesConfig, configToml)

        let expected = storageRoot.appendingPathComponent(databasesConfig)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "databases.toml should exist at the storage root")
    }

    //
    // The read path checks the file exists before reading it, so that check has to see the config.
    //
    func testDatabasesConfigIsVisibleToTheExistenceCheck() throws {
        let bridge = makeBridge()
        XCTAssertFalse(try bridge.fsAccess(path: databasesConfig))

        try writeConfig(bridge, databasesConfig, configToml)

        XCTAssertTrue(try bridge.fsAccess(path: databasesConfig))
    }

    //
    // A device that has never registered a database has no config, and that must read as absent. It
    // is the state of every fresh install, and the app starts from an empty list rather than failing.
    //
    func testAMissingDatabasesConfigReadsAsAbsent() throws {
        let bridge = makeBridge()

        XCTAssertFalse(try bridge.fsAccess(path: databasesConfig))
        XCTAssertNil(try bridge.fsReadFile(path: databasesConfig))
    }

    //
    // Rewriting the config replaces it rather than appending, so removing a database really removes
    // it instead of leaving the old list behind the new one.
    //
    func testRewritingTheDatabasesConfigReplacesIt() throws {
        let bridge = makeBridge()
        try writeConfig(bridge, databasesConfig, configToml)

        let shorter = "recent_database_names = [ ]\n"
        try writeConfig(bridge, databasesConfig, shorter)

        XCTAssertEqual(shorter, try readConfig(bridge, databasesConfig))
    }

    //
    // Non-ASCII survives the round trip. Database names are free text, so a config naming a database
    // in another script has to come back unmangled rather than as replacement characters.
    //
    func testDatabasesConfigRoundTripsNonAsciiNames() throws {
        let bridge = makeBridge()
        let toml = """
        recent_database_names = [ "Fotos münchen" ]

        [[databases]]
        name = "Fotos münchen"
        description = "Ferien 🌴"
        path = "fotos"

        """
        try writeConfig(bridge, databasesConfig, toml)

        XCTAssertEqual(toml, try readConfig(bridge, databasesConfig))
    }

    //
    // The config path is sandboxed like every other path: it cannot be pointed outside the app's
    // storage, so nothing can be tricked into reading or writing another app's config.
    //
    func testTheDatabasesConfigPathCannotEscapeTheSandbox() {
        let bridge = makeBridge()

        XCTAssertThrowsError(try bridge.fsReadFile(path: "../\(databasesConfig)"),
                             "reading a config outside the sandbox should be rejected")
        XCTAssertThrowsError(try writeConfig(bridge, "/etc/\(databasesConfig)", configToml),
                             "writing a config outside the sandbox should be rejected")
    }
}
