import { getVault, getDefaultVaultType } from "vault";
import { importShareSecrets, IShareSecretStore } from "lan-share-core";
import type { IShareDatabaseConfig, ConflictResolver, IDatabaseSharePayload, ISecretSharePayload } from "./index";

//
// Adapts the OS vault to the IShareSecretStore the shared importer writes through. `has` reports
// whether a secret exists (to detect a conflict); `write` creates or overwrites one.
//
function vaultSecretStore(): IShareSecretStore {
    const vault = getVault(getDefaultVaultType());
    return {
        has: async (name: string) => (await vault.get(name)) !== undefined,
        write: async (name: string, secretType: string, value: string) => {
            await vault.set({ name, type: secretType, value });
        },
    };
}

//
// Imports a database share payload by creating vault entries for each
// included secret and returning a database config ready to be saved.
// The caller is responsible for calling addDatabaseEntry with the result.
// onConflict is called whenever an incoming secret name already exists in
// the vault, allowing the caller to choose how to resolve it. The per-secret
// resolve-and-write loop is shared with mobile via lan-share-core.
//
export async function importDatabasePayload(payload: IDatabaseSharePayload, onConflict: ConflictResolver): Promise<IShareDatabaseConfig> {
    const resolvedKeys = await importShareSecrets(payload, vaultSecretStore(), onConflict);
    return {
        name: payload.name,
        description: payload.description,
        path: payload.path,
        origin: payload.origin,
        s3Key: resolvedKeys.s3Key,
        encryptionKey: resolvedKeys.encryptionKey,
        geocodingKey: resolvedKeys.geocodingKey,
    };
}

//
// Imports a secret share payload by creating a vault entry with the given name.
//
export async function importSecretPayload(payload: ISecretSharePayload, secretName: string): Promise<void> {
    const vault = getVault(getDefaultVaultType());
    await vault.set({
        name: secretName,
        type: payload.secretType,
        value: payload.value,
    });
}
