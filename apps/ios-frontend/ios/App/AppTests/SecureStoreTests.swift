import XCTest
import Security
@testable import App

//
// Tests the iOS device keychain (SecureStore) and the host facade (SecureStoreHost) on the simulator's
// keychain: set/get round-trip, overwrite, missing-key-is-absent, delete, key enumeration, and the
// crucial security property that every stored item carries kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
// (device-only, after first unlock). Mirrors the Android SecureStoreTest. Each test uses a unique service
// so runs are isolated and self-cleaning.
//
final class SecureStoreTests: XCTestCase {

    //
    // A store on a per-test unique service, cleaned up in tearDown.
    //
    private var store: SecureStore!

    //
    // The unique service for the current test.
    //
    private var service: String!

    override func setUpWithError() throws {
        service = "au.com.codecapers.photosphere.securestore.test.\(UUID().uuidString)"
        store = SecureStore(service: service)
    }

    override func tearDownWithError() throws {
        // Remove every item this test wrote so the simulator keychain does not accumulate entries.
        for key in try store.keys() {
            try store.delete(key: key)
        }
    }

    //
    // A value written under a key reads back unchanged.
    //
    func testSetThenGetRoundTrips() throws {
        try store.set(key: "photosphere.secret.my-api-key", value: "the-secret-value")
        XCTAssertEqual(try store.get(key: "photosphere.secret.my-api-key"), "the-secret-value")
    }

    //
    // Overwriting a key replaces the value (delete-then-add path).
    //
    func testSetOverwritesExistingValue() throws {
        try store.set(key: "k", value: "one")
        try store.set(key: "k", value: "two")
        XCTAssertEqual(try store.get(key: "k"), "two")
    }

    //
    // A missing key reads as absent (nil), not an error.
    //
    func testMissingKeyIsAbsent() throws {
        XCTAssertNil(try store.get(key: "never-written"))
    }

    //
    // Deleting a key removes it; deleting a missing key is not an error.
    //
    func testDeleteRemovesKey() throws {
        try store.set(key: "k", value: "v")
        try store.delete(key: "k")
        XCTAssertNil(try store.get(key: "k"))
        try store.delete(key: "k")
        XCTAssertNil(try store.get(key: "k"))
    }

    //
    // keys() enumerates every stored key.
    //
    func testKeysEnumeratesStoredKeys() throws {
        try store.set(key: "a", value: "1")
        try store.set(key: "b", value: "2")
        let keys = try store.keys()
        XCTAssertEqual(Set(keys), Set(["a", "b"]))
    }

    //
    // Every stored item is accessible only after first unlock and only on this device (not backed up,
    // not synced to iCloud). This is the security property the step exists to guarantee.
    //
    func testStoredItemIsDeviceOnlyAfterFirstUnlock() throws {
        try store.set(key: "k", value: "v")
        let accessible = try store.accessibilityAttribute(key: "k")
        XCTAssertEqual(accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    //
    // Each secret occupies its own keychain item, so removing one leaves the others untouched. This is
    // the property that makes a per-secret store different from the single-blob store it replaced.
    //
    func testSecretsAreIndependentItems() throws {
        try store.set(key: "photosphere.secret.first", value: "value-one")
        try store.set(key: "photosphere.secret.second", value: "value-two")

        try store.delete(key: "photosphere.secret.first")

        XCTAssertNil(try store.get(key: "photosphere.secret.first"))
        XCTAssertEqual(try store.get(key: "photosphere.secret.second"), "value-two")
    }

    //
    // The host facade delegates to the shared-service keychain: round-trip and delete through
    // SecureStoreHost mirror the WebView plugin path.
    //
    func testHostFacadeRoundTrips() throws {
        let hostKey = "photosphere.hosttest.\(UUID().uuidString)"
        try SecureStoreHost.set(key: hostKey, value: "blob")
        XCTAssertEqual(try SecureStoreHost.get(key: hostKey), "blob")
        try SecureStoreHost.delete(key: hostKey)
        XCTAssertNil(try SecureStoreHost.get(key: hostKey))
    }
}
