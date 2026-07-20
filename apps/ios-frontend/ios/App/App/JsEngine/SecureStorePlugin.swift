import Foundation
import Capacitor

//
// The "SecureStore" Capacitor plugin: the WebView-facing half of the device keychain. The mobile config
// store holds secrets here (via get/set/delete) instead of in plaintext localStorage, matching desktop's
// OS keychain. Backed by SecureStore on the same service the host.secureStore* functions use, so a secret
// written from the WebView is readable by the worker vault.
//
// No explicit dispatch is needed here: Capacitor invokes plugin methods on the plugin's own background
// DispatchQueue, so the Keychain Services calls never run on the main thread. (The Android plugin has to
// hop threads explicitly, which is why its methods look different.)
//
@objc(SecureStorePlugin)
public class SecureStorePlugin: CAPPlugin {

    //
    // The keychain store, on the canonical service shared with the worker host functions.
    //
    private let store = SecureStore(service: SecureStore.defaultService)

    //
    // get({ key }): resolves { value } with the stored value, or null when the key is absent.
    //
    @objc func get(_ call: CAPPluginCall) {
        guard let key = call.getString("key") else {
            call.reject("get requires key")
            return
        }
        do {
            let value = try store.get(key: key)
            // Resolve an absent key as JS null (NSNull) so the WebView adapter sees a clean null.
            call.resolve(["value": value ?? NSNull()])
        }
        catch {
            call.reject("SecureStore get failed: \(error)")
        }
    }

    //
    // set({ key, value }): stores (or overwrites) the value.
    //
    @objc func set(_ call: CAPPluginCall) {
        guard let key = call.getString("key") else {
            call.reject("set requires key")
            return
        }
        guard let value = call.getString("value") else {
            call.reject("set requires value")
            return
        }
        do {
            try store.set(key: key, value: value)
            call.resolve()
        }
        catch {
            call.reject("SecureStore set failed: \(error)")
        }
    }

    //
    // delete({ key }): removes the key (a missing key is not an error).
    //
    @objc func delete(_ call: CAPPluginCall) {
        guard let key = call.getString("key") else {
            call.reject("delete requires key")
            return
        }
        do {
            try store.delete(key: key)
            call.resolve()
        }
        catch {
            call.reject("SecureStore delete failed: \(error)")
        }
    }

    //
    // keys(): resolves { keys } with every stored key.
    //
    @objc func keys(_ call: CAPPluginCall) {
        do {
            let keys = try store.keys()
            call.resolve(["keys": keys])
        }
        catch {
            call.reject("SecureStore keys failed: \(error)")
        }
    }
}
