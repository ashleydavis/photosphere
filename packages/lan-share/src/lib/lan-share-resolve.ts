import { createPrivateKey, createPublicKey } from "node:crypto";
import { exportPublicKeyToPem } from "storage";
import { getVault, getDefaultVaultType } from "vault";
import type { IDatabaseEntry } from "electron-defs";
import type { IDatabaseSharePayload, ISecretSharePayload, IShareS3Credentials, IShareEncryptionKey, IShareGeocodingKey } from "./lan-share-types";

//
// Builds a database share payload by reading the vault to resolve all
// secret references on the given database entry into full credential objects.
//
export async function resolveDatabaseSharePayload(entry: IDatabaseEntry): Promise<IDatabaseSharePayload> {
    const vault = getVault(getDefaultVaultType());

    let s3Credentials: IShareS3Credentials | undefined;
    if (entry.s3Key) {
        const secret = await vault.get(entry.s3Key);
        if (secret) {
            const parsed = JSON.parse(secret.value);
            s3Credentials = {
                name: entry.s3Key,
                label: parsed.label || entry.s3Key,
                region: parsed.region,
                accessKeyId: parsed.accessKeyId,
                secretAccessKey: parsed.secretAccessKey,
                endpoint: parsed.endpoint,
            };
        }
    }

    let encryptionKey: IShareEncryptionKey | undefined;
    if (entry.encryptionKey) {
        const secret = await vault.get(entry.encryptionKey);
        if (secret) {
            let label: string;
            let privateKeyPem: string;
            let publicKeyPem: string;
            try {
                const parsed = JSON.parse(secret.value);
                label = parsed.label || entry.encryptionKey;
                privateKeyPem = parsed.privateKeyPem;
                publicKeyPem = parsed.publicKeyPem;
            }
            catch {
                // Raw PEM key — derive the public key from it.
                label = entry.encryptionKey;
                privateKeyPem = secret.value;
                publicKeyPem = exportPublicKeyToPem(createPublicKey(createPrivateKey(secret.value)));
            }
            encryptionKey = { name: entry.encryptionKey, label, privateKeyPem, publicKeyPem };
        }
    }

    let geocodingKey: IShareGeocodingKey | undefined;
    if (entry.geocodingKey) {
        const secret = await vault.get(entry.geocodingKey);
        if (secret) {
            const parsed = JSON.parse(secret.value);
            geocodingKey = {
                name: entry.geocodingKey,
                label: parsed.label || entry.geocodingKey,
                apiKey: parsed.apiKey,
            };
        }
    }

    return {
        type: "database",
        name: entry.name,
        description: entry.description,
        path: entry.path,
        origin: entry.origin,
        s3Credentials,
        encryptionKey,
        geocodingKey,
    };
}

//
// Builds a secret share payload by reading a vault entry by name
// and wrapping it in the share payload format.
//
export async function resolveSecretSharePayload(secretName: string): Promise<ISecretSharePayload> {
    const vault = getVault(getDefaultVaultType());
    const secret = await vault.get(secretName);
    if (!secret) {
        throw new Error(`Secret "${secretName}" not found in vault.`);
    }

    return {
        type: "secret",
        name: secretName,
        secretType: secret.type as "s3-credentials" | "encryption-key" | "api-key",
        value: secret.value,
    };
}
