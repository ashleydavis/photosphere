//
// Build-time stub for the `vault` package in the mobile worker bundle.
//
// `resolveStorageCredentials` calls `getVault(getDefaultVaultType())` while opening any database.
// The real vault implementations use OS keychains via `child_process`, none of which exists in the
// embedded engine. Opening a plain, unencrypted local database never reads a secret, so this stub
// provides an empty vault: `get` returns undefined (no secret configured) and the mutating methods
// throw the loud NOT IMPLEMENTED error. Secret storage on mobile is a later layer.
//

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
// An empty vault: no secrets are configured on mobile, so reads return undefined.
//
class EmptyVault implements IVault {
    //
    // Returns undefined for every key (no secrets configured in the mobile worker).
    //
    async get(_key: string): Promise<IVaultSecret | undefined> {
        return undefined;
    }
}

//
// Returns the default vault type identifier. The value is irrelevant because getVault always
// returns the empty vault on mobile.
//
export function getDefaultVaultType(): string {
    return "empty";
}

//
// Returns the empty vault used by the mobile worker.
//
export function getVault(_type: string): IVault {
    return new EmptyVault();
}
