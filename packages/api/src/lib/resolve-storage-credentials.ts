import * as fs from "fs/promises";
import { createPrivateKey, createPublicKey } from "node:crypto";
import { IS3Credentials, IEncryptionKeyPem, exportPublicKeyToPem } from "storage";
import { getVault, getDefaultVaultType, IVault } from "vault";
import { getDatabases } from "node-utils";
import { log } from "utils";

//
// The fully-resolved credentials needed to open a storage instance.
// Returned by resolveStorageCredentials and passed directly to createStorage.
//
export interface IResolvedStorageCredentials {
    //
    // S3 credentials when the database path starts with "s3:". Undefined for local paths.
    //
    s3Config?: IS3Credentials;

    //
    // PEM key pairs for encryption. Empty when no encryption key is configured.
    //
    encryptionKeyPems: IEncryptionKeyPem[];

    //
    // Google geocoding API key when configured. Undefined when not configured.
    //
    googleApiKey?: string;
}

//
// Resolves an encryption key PEM pair from a vault secret value.
// Handles two vault secret formats:
//   - JSON: { label, privateKeyPem, publicKeyPem } (stored by "dbs add" / LAN share)
//   - Raw PEM: the value is the private key PEM directly (stored by smoke tests / legacy)
//
function parseEncryptionKeyFromVaultValue(value: string): IEncryptionKeyPem {
    try {
        const parsed = JSON.parse(value);
        if (parsed.privateKeyPem) {
            return { privateKeyPem: parsed.privateKeyPem, publicKeyPem: parsed.publicKeyPem };
        }
    }
    catch {
        // Not JSON — fall through to raw PEM handling.
    }

    const privateKeyObj = createPrivateKey(value);
    const publicKeyPem = exportPublicKeyToPem(createPublicKey(privateKeyObj));
    return { privateKeyPem: value, publicKeyPem };
}

//
// Resolves all storage credentials needed to open a database at the given path.
//
// Priority order:
//   S3:            databases.json entry (s3Key) → AWS_* env vars
//   Encryption:    -k flag (encryptionKey param) → databases.json entry → PSI_ENCRYPTION_KEY env var
//   Geocoding:     databases.json entry (geocodingKey) → GOOGLE_API_KEY env var
//
// The vault is only accessed when a credential source actually requires it.
// S3 lookup is skipped entirely for non-s3: paths.
//
export async function resolveStorageCredentials(
    databasePath: string,
    encryptionKey?: string
): Promise<IResolvedStorageCredentials> {
    const vault = getVault(getDefaultVaultType());

    const databases = await getDatabases();
    const entry = databases.find(dbEntry => dbEntry.path === databasePath);

    // --- S3 ---

    let s3Config: IS3Credentials | undefined;

    if (databasePath.startsWith('s3:')) {
        if (entry?.s3Key) {
            const secret = await vault.get(entry.s3Key);
            if (secret) {
                const parsed = JSON.parse(secret.value);
                s3Config = {
                    region: parsed.region,
                    accessKeyId: parsed.accessKeyId,
                    secretAccessKey: parsed.secretAccessKey,
                    endpoint: parsed.endpoint,
                };
                log.verbose(`S3 credentials: loaded from vault (key "${entry.s3Key}")`);
            }
            else {
                log.verbose(`S3 credentials: vault key "${entry.s3Key}" not found`);
            }
        }

        if (!s3Config && process.env.AWS_ACCESS_KEY_ID && process.env.AWS_SECRET_ACCESS_KEY) {
            s3Config = {
                region: process.env.AWS_REGION || 'us-east-1',
                accessKeyId: process.env.AWS_ACCESS_KEY_ID,
                secretAccessKey: process.env.AWS_SECRET_ACCESS_KEY,
                endpoint: process.env.AWS_ENDPOINT,
            };
            log.verbose(`S3 credentials: loaded from environment variables (AWS_ACCESS_KEY_ID)`);
        }

        if (!s3Config) {
            log.verbose(`S3 credentials: not configured (no vault entry, no env vars)`);
        }
    }

    // --- Encryption key ---

    let encryptionKeyPems: IEncryptionKeyPem[] = [];

    const psiEncryptionKey = process.env.PSI_ENCRYPTION_KEY;
    const hasAnyEncryptionSource = encryptionKey || entry?.encryptionKey || psiEncryptionKey;

    if (hasAnyEncryptionSource) {
        if (encryptionKey) {
            const keyNames = encryptionKey.split(',').map(keyName => keyName.trim()).filter(keyName => keyName.length > 0);
            encryptionKeyPems = await Promise.all(keyNames.map(keyName => resolveEncryptionKeyValue(vault, keyName, '-k flag')));
        }
        else if (entry?.encryptionKey) {
            const secret = await vault.get(entry.encryptionKey);
            if (!secret) {
                throw new Error(`Encryption key "${entry.encryptionKey}" not found in vault`);
            }
            encryptionKeyPems = [parseEncryptionKeyFromVaultValue(secret.value)];
            log.verbose(`Encryption key: loaded from vault (key "${entry.encryptionKey}", via databases.json entry)`);
        }
        else if (psiEncryptionKey) {
            const pem = await resolveEncryptionKeyValue(vault, psiEncryptionKey, 'PSI_ENCRYPTION_KEY');
            encryptionKeyPems = [pem];
        }
    }
    else {
        log.verbose(`Encryption key: not configured`);
    }

    // --- Geocoding ---

    let googleApiKey: string | undefined;

    const hasAnyGeocodingSource = entry?.geocodingKey || process.env.GOOGLE_API_KEY;

    if (hasAnyGeocodingSource) {
        if (entry?.geocodingKey) {
            const secret = await vault.get(entry.geocodingKey);
            if (secret) {
                const parsed = JSON.parse(secret.value);
                googleApiKey = parsed.apiKey;
                log.verbose(`Geocoding key: loaded from vault (key "${entry.geocodingKey}")`);
            }
            else {
                log.verbose(`Geocoding key: vault key "${entry.geocodingKey}" not found`);
            }
        }

        if (!googleApiKey && process.env.GOOGLE_API_KEY) {
            googleApiKey = process.env.GOOGLE_API_KEY;
            log.verbose(`Geocoding key: loaded from environment variable (GOOGLE_API_KEY)`);
        }
    }
    else {
        log.verbose(`Geocoding key: not configured`);
    }

    return { s3Config, encryptionKeyPems, googleApiKey };
}

//
// Resolves an encryption key from a value that is either a filesystem path to a PEM file
// or a vault secret name. Throws if the value is neither.
//
async function resolveEncryptionKeyValue(
    vault: IVault,
    value: string,
    source: string
): Promise<IEncryptionKeyPem> {
    const isFile = await fs.access(value).then(() => true).catch(() => false);
    if (isFile) {
        const privateKeyPem = await fs.readFile(value, 'utf-8');
        const privateKeyObj = createPrivateKey(privateKeyPem);
        const publicKeyPem = exportPublicKeyToPem(createPublicKey(privateKeyObj));
        log.verbose(`Encryption key: loaded from file "${value}" (via ${source})`);
        return { privateKeyPem, publicKeyPem };
    }

    const secret = await vault.get(value);
    if (secret) {
        const pem = parseEncryptionKeyFromVaultValue(secret.value);
        log.verbose(`Encryption key: loaded from vault (key "${value}", via ${source})`);
        return pem;
    }

    throw new Error(`Encryption key "${value}" (via ${source}) is neither a file path nor a vault secret name`);
}
