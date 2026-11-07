//
// The device keychain behind the secureStore host requests. It keeps the secrets Photosphere holds on a phone in the iOS keychain, so
// they match the operating system keychain a desktop uses.
//
// Items are stored as kSecClassGenericPassword under a fixed service, with the accessibility attribute
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly: they are readable only after the device's first unlock since boot, and
// ThisDeviceOnly keeps them out of iCloud Keychain and encrypted device backups, so a backup or a second device never carries the
// secrets.
//

import Foundation
import Security

// An error from a Keychain Services operation, carrying the OSStatus so a failure surfaces a real code and never a silent nil.
enum SecureStoreError: Error, CustomStringConvertible {
    // A SecItem call returned a status that is neither success nor "item not found".
    case unexpectedStatus(OSStatus)

    // A stored item's data was not valid UTF-8.
    case invalidData

    var description: String {
        switch self {
        case .unexpectedStatus(let status):
            return "the keychain returned status \(status)"
        case .invalidData:
            return "a keychain item's data was not valid UTF-8"
        }
    }
}

// The keychain items of one service (namespace).
struct SecureStore {
    // The keychain accessibility attribute applied to every stored item (device-only, after first unlock).
    static let accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    // The keychain service (namespace) this store's items live under.
    let service: String

    // Builds the base query dictionary shared by every operation (class and service, and account when given).
    private func baseQuery(account: String?) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ]
        if let account = account {
            query[kSecAttrAccount] = account
        }
        return query
    }

    // Returns the stored value for a key, or nil when the key is absent.
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

    // Stores (or overwrites) a value for a key. Written as a delete then an add so the accessibility attribute is always applied again.
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

    // Removes a key. A missing key is not an error.
    func delete(key: String) throws {
        let query = baseQuery(account: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.unexpectedStatus(status)
        }
    }

    // Returns every stored key (account) under this service.
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
        return entries.compactMap { entry in
            entry[kSecAttrAccount] as? String
        }
    }
}
