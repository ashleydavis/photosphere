import Foundation

//
// The process-wide device keychain behind the host.secureStore* functions the embedded worker calls.
// The worker vault reads secret values natively through these so secrets never transit task payloads or
// the log. It shares the SecureStore.defaultService with the SecureStore Capacitor plugin, so a secret
// written from the WebView is readable here and vice versa. The iOS keychain is process-global and
// thread-safe, so no context or locking is needed (unlike Android's Keystore-backed store).
//
enum SecureStoreHost {

    //
    // The shared keychain store, on the canonical service.
    //
    private static let store = SecureStore(service: SecureStore.defaultService)

    //
    // host.secureStoreGet(key): returns the stored secret value, or nil when absent.
    //
    static func get(key: String) throws -> String? {
        return try store.get(key: key)
    }

    //
    // host.secureStoreSet(key, value): stores (or overwrites) a secret value.
    //
    static func set(key: String, value: String) throws {
        try store.set(key: key, value: value)
    }

    //
    // host.secureStoreDelete(key): deletes a secret (a missing key is not an error).
    //
    static func delete(key: String) throws {
        try store.delete(key: key)
    }
}
