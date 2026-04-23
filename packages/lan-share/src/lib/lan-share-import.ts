import { getVault, getDefaultVaultType } from "vault";
import type { IDatabaseEntry } from "electron-defs";
import type { IDatabaseSharePayload, ISecretSharePayload } from "./lan-share-types";

//
// Generates an 8-character random alphanumeric ID for shared vault secrets.
//
function generateSharedSecretId(): string {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    let result = "";
    for (let index = 0; index < 8; index++) {
        result += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return result;
}

//
// Imports a database share payload by creating vault entries for each
// included secret and returning a database entry ready to be saved.
// The caller is responsible for calling addDatabaseEntry with the result.
//
export async function importDatabasePayload(payload: IDatabaseSharePayload): Promise<IDatabaseEntry> {
    const vault = getVault(getDefaultVaultType());

    let s3Key: string | undefined;
    if (payload.s3Credentials) {
        s3Key = generateSharedSecretId();
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

    let encryptionKey: string | undefined;
    if (payload.encryptionKey) {
        encryptionKey = generateSharedSecretId();
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

    let geocodingKey: string | undefined;
    if (payload.geocodingKey) {
        geocodingKey = generateSharedSecretId();
        await vault.set({
            name: geocodingKey,
            type: "api-key",
            value: JSON.stringify({
                label: payload.geocodingKey.label,
                apiKey: payload.geocodingKey.apiKey,
            }),
        });
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
