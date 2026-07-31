import type { ISharedSecretEntry } from "user-interface";

//
// The device-keychain abstraction mobile secrets are stored in. On a real device this wraps the native
// SecureStore Capacitor plugin (iOS Keychain Services, Android Keystore-backed EncryptedSharedPreferences);
// in unit tests it is a plain in-memory fake. Every operation is async because native keychain access is
// async.
//
export interface ISecureStore {
    // Returns the stored string for a key, or null when the key is absent.
    get(key: string): Promise<string | null>;

    // Stores (or overwrites) a string for a key.
    set(key: string, value: string): Promise<void>;

    // Removes a key. A missing key is not an error.
    delete(key: string): Promise<void>;

    // Returns every stored key (used to enumerate the stored secrets).
    keys(): Promise<string[]>;
}

//
// Keychain key holding a single secret's VALUE, one item per secret. The embedded worker resolves a
// secret value natively with host.secureStoreGet(SECRET_VALUE_KEY_PREFIX + name), so this prefix is the
// contract between the WebView and the worker vault and must not change without changing both.
//
export const SECRET_VALUE_KEY_PREFIX = "photosphere.secret.";

//
// Keychain key holding a single secret's TYPE, one item per secret. Kept in a separate item from the
// value so the secrets list can be enumerated (keys() plus one small read per secret) WITHOUT reading a
// single secret value into memory. The two prefixes are disjoint ('.' never matches '-'), so a value key
// is never mistaken for a type key.
//
export const SECRET_TYPE_KEY_PREFIX = "photosphere.secret-type.";

//
// Returns the keychain key holding the named secret's value.
//
export function secretValueKey(name: string): string {
    return SECRET_VALUE_KEY_PREFIX + name;
}

//
// Returns the keychain key holding the named secret's type.
//
export function secretTypeKey(name: string): string {
    return SECRET_TYPE_KEY_PREFIX + name;
}

//
// Mobile secret storage, backed entirely by the device keychain (iOS Keychain Services, Android
// Keystore-backed EncryptedSharedPreferences), matching desktop's use of the OS keychain.
//
// Two properties this design exists to guarantee:
//
// 1. One keychain item per secret, never a combined blob. Reading, writing or deleting one secret
//    touches only that secret's items, so no operation decrypts or rewrites the other secrets, and a
//    single failed write cannot damage them.
//
// 2. No secret value is ever cached. Every read goes to the keychain and the value is returned straight
//    to the caller; this class holds no secret state between calls, so a secret is in memory only for as
//    long as the caller that asked for it needs it. Listing the secrets reads only the type items, so
//    enumerating never pulls a secret value into memory at all.
//
// Nothing is written to WebView localStorage: the keychain is the single source of truth for both the
// secret values and the list of which secrets exist.
//
export class MobileSecretStore {

    //
    // The device keychain every secret is read from and written to.
    //
    private readonly secureStore: ISecureStore;

    //
    // Constructs the store over a device keychain.
    //
    constructor(secureStore: ISecureStore) {
        this.secureStore = secureStore;
    }

    //
    // Returns the configured secret entries (name + type, values omitted, matching listSecrets on
    // desktop). Driven by the type items alone, so no secret value is read.
    //
    async listSecrets(): Promise<ISharedSecretEntry[]> {
        const storedKeys = await this.secureStore.keys();
        const entries: ISharedSecretEntry[] = [];

        for (const storedKey of storedKeys) {
            if (!storedKey.startsWith(SECRET_TYPE_KEY_PREFIX)) {
                continue;
            }

            const name = storedKey.substring(SECRET_TYPE_KEY_PREFIX.length);
            const type = await this.secureStore.get(storedKey);
            if (type === null) {
                // Enumerated a moment ago but gone now (a concurrent delete). Skip it rather than
                // reporting a secret with no type.
                continue;
            }

            entries.push({ name, type });
        }

        return entries;
    }

    //
    // Adds a secret. Throws (with the exact message the desktop provider uses) when a secret of the same
    // name already exists, so the duplicate-name flow behaves identically. The value is written before
    // the type, so an interrupted add leaves a value that is not listed (invisible, and overwritten by a
    // retry) rather than a listed secret with no value.
    //
    async addSecret(entry: ISharedSecretEntry, value: string): Promise<ISharedSecretEntry> {
        const existingType = await this.secureStore.get(secretTypeKey(entry.name));
        if (existingType !== null) {
            throw new Error(`A secret named '${entry.name}' already exists.`);
        }

        await this.secureStore.set(secretValueKey(entry.name), value);
        await this.secureStore.set(secretTypeKey(entry.name), entry.type);
        return entry;
    }

    //
    // Updates the secret matching originalName: replaces its entry, and its value when one is given.
    // A rename moves both items to the new name and removes the old ones.
    //
    async updateSecret(originalName: string, entry: ISharedSecretEntry, value?: string): Promise<void> {
        const renamed = entry.name !== originalName;

        if (value !== undefined) {
            await this.secureStore.set(secretValueKey(entry.name), value);
        }
        else if (renamed) {
            // A rename with no new value has to carry the stored value across to the new key. This is the
            // only path that reads a secret value here, and it holds it only for the duration of this call.
            const existingValue = await this.secureStore.get(secretValueKey(originalName));
            if (existingValue === null) {
                throw new Error(`Cannot rename the secret '${originalName}' to '${entry.name}': the device keychain holds no value for it.`);
            }
            await this.secureStore.set(secretValueKey(entry.name), existingValue);
        }

        await this.secureStore.set(secretTypeKey(entry.name), entry.type);

        if (renamed) {
            // Type first, so the old name leaves the list before its value goes.
            await this.secureStore.delete(secretTypeKey(originalName));
            await this.secureStore.delete(secretValueKey(originalName));
        }
    }

    //
    // Removes the secret with the given name. The type is deleted first so the secret leaves the list
    // even if the value delete then fails, rather than being listed with no value behind it.
    //
    async deleteSecret(name: string): Promise<void> {
        await this.secureStore.delete(secretTypeKey(name));
        await this.secureStore.delete(secretValueKey(name));
    }

    //
    // Returns the stored value for a secret name, or undefined when not present. Read straight from the
    // keychain on every call: nothing is cached here, so the value lives only in the caller.
    //
    async getSecretValue(name: string): Promise<string | undefined> {
        const value = await this.secureStore.get(secretValueKey(name));
        if (value === null) {
            return undefined;
        }
        return value;
    }

}
