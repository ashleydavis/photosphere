import { registerPlugin } from "@capacitor/core";
import type { ISecureStore } from "./mobile-secure-store";

//
// Argument for a keyed SecureStore read/delete.
//
export interface ISecureStoreKeyOptions {
    // The item key.
    key: string;
}

//
// Argument for a SecureStore write.
//
export interface ISecureStoreSetOptions {
    // The item key.
    key: string;

    // The value to store.
    value: string;
}

//
// Result of a SecureStore read: the stored value, or null when the key is absent.
//
export interface ISecureStoreGetResult {
    // The stored value, or null when the key is absent.
    value: string | null;
}

//
// Result of a SecureStore keys() enumeration.
//
export interface ISecureStoreKeysResult {
    // Every stored key.
    keys: string[];
}

//
// The `SecureStore` Capacitor plugin interface. The native implementation stores items in the device
// keychain: iOS Keychain Services (kSecClassGenericPassword, accessible only after first unlock on this
// device) and Android EncryptedSharedPreferences backed by the Android Keystore. Exposed to the WebView
// so mobile secrets live in the keychain instead of plaintext localStorage.
//
// Every operation is per item: one secret's value is one keychain item, so reading or writing one secret
// never decrypts or rewrites another. MobileSecretStore owns the key naming (see mobile-secure-store.ts).
//
export interface ISecureStorePlugin {
    // Reads an item, resolving { value } (value is null when the key is absent).
    get(options: ISecureStoreKeyOptions): Promise<ISecureStoreGetResult>;

    // Writes (or overwrites) an item.
    set(options: ISecureStoreSetOptions): Promise<void>;

    // Deletes an item. A missing key is not an error.
    delete(options: ISecureStoreKeyOptions): Promise<void>;

    // Returns every stored key.
    keys(): Promise<ISecureStoreKeysResult>;
}

//
// The registered `SecureStore` plugin singleton. On a device this is backed by the native plugin; in a
// browser/dev preview it is a Capacitor web proxy (which throws until a native impl exists).
//
export const SecureStore = registerPlugin<ISecureStorePlugin>("SecureStore");

//
// Adapts the Capacitor SecureStore plugin to the ISecureStore shape the secrets cache writes through,
// flattening the plugin's object-wrapped arguments and results to plain values.
//
export function createCapacitorSecureStore(): ISecureStore {
    return {
        get: async (key: string): Promise<string | null> => {
            const result = await SecureStore.get({ key });
            // Coerce an omitted/undefined bridge value to null so callers see a clean "absent".
            return result.value ?? null;
        },
        set: async (key: string, value: string): Promise<void> => {
            await SecureStore.set({ key, value });
        },
        delete: async (key: string): Promise<void> => {
            await SecureStore.delete({ key });
        },
        keys: async (): Promise<string[]> => {
            const result = await SecureStore.keys();
            return result.keys;
        },
    };
}
