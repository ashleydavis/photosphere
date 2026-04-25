import { getVault, getDefaultVaultType } from "vault";
import type { IDatabaseEntry } from "electron-defs";
import type { ConflictResolver, IDatabaseSharePayload, ISecretSharePayload } from "./lan-share-types";

//
// Checks whether the given name is already in the vault and, if so, calls
// onConflict to ask the caller how to resolve it. Returns the final vault key
// name to use and whether the secret value should be written (false = reuse).
//
async function resolveConflict(
    vaultGet: (name: string) => Promise<unknown>,
    name: string,
    secretType: string,
    onConflict: ConflictResolver
): Promise<{ finalName: string; shouldWrite: boolean }> {
    const existing = await vaultGet(name);
    if (!existing) {
        return { finalName: name, shouldWrite: true };
    }

    const resolution = await onConflict(name, secretType);

    if (resolution.action === "reuse") {
        return { finalName: name, shouldWrite: false };
    }

    if (resolution.action === "rename") {
        return { finalName: resolution.newName!, shouldWrite: true };
    }

    return { finalName: name, shouldWrite: true };
}

//
// Imports a database share payload by creating vault entries for each
// included secret and returning a database entry ready to be saved.
// The caller is responsible for calling addDatabaseEntry with the result.
// onConflict is called whenever an incoming secret name already exists in
// the vault, allowing the caller to choose how to resolve it.
//
export async function importDatabasePayload(payload: IDatabaseSharePayload, onConflict: ConflictResolver): Promise<IDatabaseEntry> {
    const vault = getVault(getDefaultVaultType());

    let s3Key: string | undefined;
    if (payload.s3Credentials) {
        const { finalName, shouldWrite } = await resolveConflict(name => vault.get(name), payload.s3Credentials.name, "s3-credentials", onConflict);
        s3Key = finalName;
        if (shouldWrite) {
            await vault.set({
                name: s3Key,
                type: "s3-credentials",
                value: JSON.stringify({
                    label: payload.s3Credentials.label,
                    region: payload.s3Credentials.region,
                    accessKeyId: payload.s3Credentials.accessKeyId,
                    secretAccessKey: payload.s3Credentials.secretAccessKey,
                    endpoint: payload.s3Credentials.endpoint,
                }),
            });
        }
    }

    let encryptionKey: string | undefined;
    if (payload.encryptionKey) {
        const { finalName, shouldWrite } = await resolveConflict(name => vault.get(name), payload.encryptionKey.name, "encryption-key", onConflict);
        encryptionKey = finalName;
        if (shouldWrite) {
            await vault.set({
                name: encryptionKey,
                type: "encryption-key",
                value: JSON.stringify({
                    label: payload.encryptionKey.label,
                    privateKeyPem: payload.encryptionKey.privateKeyPem,
                    publicKeyPem: payload.encryptionKey.publicKeyPem,
                }),
            });
        }
    }

    let geocodingKey: string | undefined;
    if (payload.geocodingKey) {
        const { finalName, shouldWrite } = await resolveConflict(name => vault.get(name), payload.geocodingKey.name, "api-key", onConflict);
        geocodingKey = finalName;
        if (shouldWrite) {
            await vault.set({
                name: geocodingKey,
                type: "api-key",
                value: JSON.stringify({
                    label: payload.geocodingKey.label,
                    apiKey: payload.geocodingKey.apiKey,
                }),
            });
        }
    }

    return {
        name: payload.name,
        description: payload.description,
        path: payload.path,
        origin: payload.origin,
        s3Key,
        encryptionKey,
        geocodingKey,
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
