import Foundation
import Security

//
// An error from a Keychain Services operation, carrying the OSStatus so a failure surfaces a real code
// rather than a silent nil.
//
enum SecureStoreError: Error {

    // A SecItem* call returned an unexpected status (not success and not "item not found").
    case unexpectedStatus(OSStatus)

    // A stored item's data was not valid UTF-8.
    case invalidData
}

//
// The device keychain behind both the SecureStore Capacitor plugin (WebView) and the host.secureStore*
// functions (embedded worker). It stores mobile secrets in the iOS keychain so they match desktop's OS
// keychain instead of sitting in plaintext WebView localStorage.
//
// Items are stored as kSecClassGenericPassword under a fixed service, with the accessibility attribute
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: they are readable only after the device's first
// unlock since boot, and ThisDeviceOnly keeps them out of iCloud Keychain and encrypted device backups,
// so a backup or a second device never carries the secrets. Mirrors the Android EncryptedSharedPreferences
// (Keystore-backed) store.
//
struct SecureStore {

    //
    // The keychain accessibility attribute applied to every stored item (device-only, after first unlock).
    // Exposed so the XCTest suite can assert the stored attribute is exactly this value.
    //
    static let accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    //
    // The canonical keychain service both the plugin and the host functions use, so a secret written from
    // the WebView is readable by the worker vault and vice versa.
    //
    static let defaultService = "au.com.codecapers.photosphere.securestore"

    //
    // The keychain service (namespace) this store's items live under.
    //
    let service: String

    //
    // Builds the base query dictionary shared by every operation (class + service, and account when given).
    //
    private func baseQuery(account: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service
        ]
        if let account = account {
            query[kSecAttrAccount] = account
        }
        return query
    }

    //
    // Returns the stored value for a key, or nil when the key is absent.
    //
    func get(key: String) throws -> String? {
        var query = baseQuery(account: key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecureStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw SecureStoreError.invalidData
        }
        return value
    }

    //
    // Stores (or overwrites) a value for a key. Written as a delete-then-add so the accessibility
    // attribute is always (re)applied.
    //
    func set(key: String, value: String) throws {
        try delete(key: key)

        var query = baseQuery(account: key)
        query[kSecValueData] = Data(value.utf8)
        query[kSecAttrAccessible] = SecureStore.accessibility

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SecureStoreError.unexpectedStatus(status)
        }
    }

    //
    // Removes a key. A missing key is not an error.
    //
    func delete(key: String) throws {
        let query = baseQuery(account: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.unexpectedStatus(status)
        }
    }

    //
    // Returns every stored key (account) under this service.
    //
    func keys() throws -> [String] {
        var query = baseQuery(account: nil)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitAll

        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw SecureStoreError.unexpectedStatus(status)
        }
        guard let entries = items as? [[CFString: Any]] else {
            return []
        }
        return entries.compactMap { $0[kSecAttrAccount] as? String }
    }

    //
    // Reads the kSecAttrAccessible attribute stored for a key (nil when absent). Used by the XCTest suite
    // to prove items are stored device-only-after-first-unlock.
    //
    func accessibilityAttribute(key: String) throws -> CFString? {
        var query = baseQuery(account: key)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SecureStoreError.unexpectedStatus(status)
        }
        guard let attributes = item as? [CFString: Any] else {
            return nil
        }
        // kSecAttrAccessible comes back as a CFString value.
        if let accessible = attributes[kSecAttrAccessible] {
            return (accessible as! CFString)
        }
        return nil
    }
}
