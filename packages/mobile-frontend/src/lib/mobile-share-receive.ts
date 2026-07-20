import * as configStore from "./mobile-config-store";
import type { IKeyValueStore } from "./mobile-config-store";
import type { MobileSecretStore } from "./mobile-secure-store";
import { importShareSecrets } from "lan-share-core";
import type { IShareSecretStore, IDatabaseSharePayload, ISecretSharePayload, IConflictResolution, ConflictResolver } from "lan-share-core";

//
// Mobile-side LAN-share receive import. The per-secret resolve-and-write loop and the payload types
// are shared with desktop through the zero-dependency lan-share-core package; this module supplies
// only the mobile specifics: a keychain-backed secret store (the device keychain via MobileSecretStore,
// per step 6b), the database-entry write, and the standalone-secret path. It depends on nothing but
// mobile-config-store, mobile-secure-store and lan-share-core, so it stays out of the Node
// `vault`/`api` packages that cannot resolve in a WebView bundle.
//

//
// A received standalone secret payload: the shared secret payload plus the name the receive dialog
// chose to save it under. saveName is mobile-specific (the desktop flow saves under the sender's
// name), so this extends the shared type rather than living in lan-share-core.
//
export interface IReceivedSecretPayload extends ISecretSharePayload {
    // The name the user chose to save the secret under on this device.
    saveName: string;
}

//
// Either kind of received share payload (a shared database config or a standalone secret).
//
export type IReceivedSharePayload = IDatabaseSharePayload | IReceivedSecretPayload;

//
// Adapts the device keychain (MobileSecretStore, per step 6b) to the IShareSecretStore the shared
// importer writes through. `write` gives create-or-overwrite semantics (MobileSecretStore.addSecret
// throws on a duplicate name, so any existing entry is removed first), matching the desktop vault's
// set. Persistence goes through the keychain, never WebView localStorage.
//
function keychainSecretStore(secretStore: MobileSecretStore): IShareSecretStore {
    return {
        has: async (name: string) => (await secretStore.getSecretValue(name)) !== undefined,
        write: async (name: string, secretType: string, value: string) => {
            await secretStore.deleteSecret(name);
            await secretStore.addSecret({ name, type: secretType }, value);
        },
    };
}

//
// Builds a conflict resolver from the pre-collected resolutions the receive dialog gathered. A
// missing resolution defaults to 'replace', matching the desktop IPC handler.
//
function resolverFromMap(conflictResolutions: Record<string, IConflictResolution>): ConflictResolver {
    return async (name: string) => conflictResolutions[name] ?? { action: "replace" };
}

//
// Imports a received database payload: writes each included secret through the shared loop (honouring
// per-secret conflict resolutions) and adds the database entry referencing the resolved secret names.
// Throws the exact desktop message when the database name already exists.
//
async function importDatabasePayload(store: IKeyValueStore, secretStore: MobileSecretStore, payload: IDatabaseSharePayload, conflictResolutions: Record<string, IConflictResolution>): Promise<void> {
    const resolvedKeys = await importShareSecrets(payload, keychainSecretStore(secretStore), resolverFromMap(conflictResolutions));

    if (configStore.findDatabase(store, payload.name)) {
        throw new Error(`A database named "${payload.name}" already exists.`);
    }

    configStore.addDatabase(store, {
        name: payload.name,
        description: payload.description,
        path: payload.path,
        origin: payload.origin,
        s3Key: resolvedKeys.s3Key,
        encryptionKey: resolvedKeys.encryptionKey,
        geocodingKey: resolvedKeys.geocodingKey,
    });
}

//
// Imports a received standalone secret payload, storing it in the device keychain under the
// user-chosen save name with create-or-overwrite semantics (matching desktop's vault.set).
//
async function importSecretPayload(secretStore: MobileSecretStore, payload: IReceivedSecretPayload): Promise<void> {
    await secretStore.deleteSecret(payload.saveName);
    await secretStore.addSecret({ name: payload.saveName, type: payload.secretType }, payload.value);
}

//
// Imports a received LAN-share payload (database or secret) into the mobile config store (database
// entries) and device keychain (secrets), applying per-secret conflict resolutions for a database
// payload. This is the mobile counterpart of the desktop 'import-share-payload' IPC handler.
//
export async function importSharePayload(store: IKeyValueStore, secretStore: MobileSecretStore, payload: IReceivedSharePayload, conflictResolutions: Record<string, IConflictResolution>): Promise<void> {
    if (payload.type === "database") {
        await importDatabasePayload(store, secretStore, payload, conflictResolutions);
    }
    else if (payload.type === "secret") {
        await importSecretPayload(secretStore, payload);
    }
}
