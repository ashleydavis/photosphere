import { getVault } from "vault";
import type { IDatabaseEntry } from "electron-defs";
import type { IDatabaseSharePayload, ISecretSharePayload, IShareS3Credentials, IShareEncryptionKey, IShareGeocodingKey } from "./lan-share-types";

//
// Builds a database share payload by reading the vault to resolve all
// secret references on the given database entry into full credential objects.
//
export async function resolveDatabaseSharePayload(entry: IDatabaseEntry): Promise<IDatabaseSharePayload> {
    const vault = getVault("plaintext");

    let s3Credentials: IShareS3Credentials | undefined;
    if (entry.s3CredentialId) {
        const secret = await vault.get(entry.s3CredentialId);
        if (secret) {
            const parsed = JSON.parse(secret.value);
            s3Credentials = {
                label: parsed.label || entry.s3CredentialId,
                region: parsed.region,
                accessKeyId: parsed.accessKeyId,
                secretAccessKey: parsed.secretAccessKey,
                endpoint: parsed.endpoint,
            };
        }
    }

    let encryptionKey: IShareEncryptionKey | undefined;
    if (entry.encryptionKeyId) {
        const secret = await vault.get(entry.encryptionKeyId);
        if (secret) {
            const parsed = JSON.parse(secret.value);
            encryptionKey = {
                label: parsed.label || entry.encryptionKeyId,
                privateKeyPem: parsed.privateKeyPem,
                publicKeyPem: parsed.publicKeyPem,
            };
        }
    }

    let geocodingKey: IShareGeocodingKey | undefined;
    if (entry.geocodingKeyId) {
        const secret = await vault.get(entry.geocodingKeyId);
        if (secret) {
            const parsed = JSON.parse(secret.value);
            geocodingKey = {
                label: parsed.label || entry.geocodingKeyId,
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
    const vault = getVault("plaintext");
    const secret = await vault.get(secretName);
    if (!secret) {
        throw new Error(`Secret "${secretName}" not found in vault.`);
    }

    return {
        type: "secret",
        secretType: secret.type as "s3-credentials" | "encryption-key" | "api-key",
        value: secret.value,
    };
}
