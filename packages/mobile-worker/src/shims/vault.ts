//
// The `vault` module for the mobile worker bundle.
//
// `resolveStorageCredentials` calls `getVault(getDefaultVaultType())` while opening a database and, for
// an encrypted or s3: database, reads the encryption key / S3 credential secret by name. The real
// desktop vaults use OS keychains via `child_process`, which the embedded engine has not. This shim
// reads secrets NATIVELY from the device keychain via the `secureStoreGet` host function (whose full
// native SecureStore implementation is owned by step 6b), so a secret value is fetched at the point of
// use and never travels inside a task payload.
//
// The distinction that matters: `secureStoreGet` returns the value string for a configured secret,
// null when no such secret is configured (read as "unconfigured": `get` returns undefined), and a host
// error envelope when the keychain is unavailable (read as "unavailable": `get` throws). Before this,
// every key read as undefined, which masked the crypto gap: "vault unavailable" and "no secret
// configured" were the same value, so an encrypted database opened as plain storage and read
// still-encrypted bytes rather than failing. Making the two distinguishable is what lets the honest
// throws in the crypto shim fire when they should.
//

import { callHost } from "./host-access";

//
// The subset of native host functions the vault shim calls.
//
interface ISecureStoreHost {
    // Reads a secret value from the device keychain by name; returns the value, or null when no such
    // secret is configured. An unavailable keychain returns a host error envelope (callHost throws).
    secureStoreGet: (key: string) => string | null;
}

//
// A vault secret value. Matches the shape resolveStorageCredentials reads (`secret.value`).
//
export interface IVaultSecret {
    // The secret's stored string value.
    value: string;
}

//
// The vault interface subset the credential resolver uses.
//
export interface IVault {
    // Returns the secret for a key, or undefined when not present.
    get(key: string): Promise<IVaultSecret | undefined>;
}

//
// Returns the installed native host bridge for secure storage, throwing a clear error if it is missing.
//
function getSecureStoreHost(): ISecureStoreHost {
    const host = (globalThis as any).host;
    if (!host) {
        throw new Error("Native host bridge (globalThis.host) is not installed; vault shim cannot run.");
    }

    return host as ISecureStoreHost;
}

//
// Prefix under which the app stores each secret's value in the device keychain. Must match
// SECRET_VALUE_KEY_PREFIX in packages/mobile-frontend/src/lib/mobile-secure-store.ts, where the app
// writes secret values (a secret named `foo` is stored under `photosphere.secret.foo`). The worker
// cannot import that frontend-only module, so the constant is duplicated here and reads the value
// back by the same key.
//
const SECRET_VALUE_KEY_PREFIX = "photosphere.secret.";

//
// A keychain-backed vault: reads secrets natively via secureStoreGet. A configured secret resolves to
// its value; an unconfigured secret resolves to undefined; an unavailable keychain throws (via
// callHost decoding the host error envelope), so the caller can tell the two apart.
//
class KeychainVault implements IVault {
    //
    // Reads a secret by name. Returns undefined when the secret is not configured (native returned
    // null); throws when the keychain is unavailable (native returned a host error envelope).
    //
    async get(name: string): Promise<IVaultSecret | undefined> {
        const host = getSecureStoreHost();
        const value = callHost(() => host.secureStoreGet(SECRET_VALUE_KEY_PREFIX + name));
        if (value === null || value === undefined) {
            return undefined;
        }
        return { value };
    }
}

//
// Returns the default vault type identifier. The value is irrelevant because getVault always returns
// the keychain-backed vault on mobile.
//
export function getDefaultVaultType(): string {
    return "keychain";
}

//
// Returns the keychain-backed vault used by the mobile worker.
//
export function getVault(_type: string): IVault {
    return new KeychainVault();
}
