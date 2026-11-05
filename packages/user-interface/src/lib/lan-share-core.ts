//
// Platform-agnostic LAN-share payload types and the shared secret-import loop. This lives in its own
// zero-dependency package so both desktop (the Node `api` package, writing to the OS vault) and
// mobile (`mobile-frontend`, writing to the WebView config store) can import it. The `api` package
// pulls in Node built-ins (fs/os/path via `vault`), so mobile cannot import from it; and
// `user-interface` sits above `api` in the dependency graph, so the shared code cannot live there
// either. A package below both is the only home that removes the duplication without a cycle.
//

//
// Resolved S3 credentials included in a share payload.
//
export interface IShareS3Credentials {
    // The vault key name used by the sender.
    name: string;

    // AWS region (e.g. "us-east-1").
    region: string;

    // Access key ID for authentication.
    accessKeyId: string;

    // Secret access key for authentication.
    secretAccessKey: string;

    // Optional custom endpoint URL (for non-AWS S3-compatible services).
    endpoint?: string;
}

//
// Resolved encryption key pair included in a share payload.
//
export interface IShareEncryptionKey {
    // The vault key name used by the sender.
    name: string;

    // PEM-encoded PKCS#8 private key.
    privateKeyPem: string;

    // PEM-encoded SPKI public key. Optional -- receivers derive it from the private key when omitted.
    publicKeyPem?: string;
}

//
// Resolved geocoding API key included in a share payload.
//
export interface IShareGeocodingKey {
    // The vault key name used by the sender.
    name: string;

    // The API key value.
    apiKey: string;
}

//
// Share payload for a full database configuration with all resolved secrets.
//
export interface IDatabaseSharePayload {
    // Discriminator for payload type.
    type: "database";

    // Human-readable name for the database.
    name: string;

    // Description of the database.
    description: string;

    // Filesystem or S3 path to the database.
    path: string;

    // Optional origin string from the database config.
    origin?: string;

    // Resolved S3 credentials, if the database uses S3 storage.
    s3Credentials?: IShareS3Credentials;

    // Resolved encryption key pair, if the database uses encryption.
    encryptionKey?: IShareEncryptionKey;

    // Resolved geocoding API key, if configured.
    geocodingKey?: IShareGeocodingKey;
}

//
// Share payload for a single standalone secret.
//
export interface ISecretSharePayload {
    // Discriminator for payload type.
    type: "secret";

    // The name of the secret in the sender's vault.
    name: string;

    // The category of the secret being shared.
    secretType: "s3-credentials" | "encryption-key" | "api-key";

    // JSON string containing the secret value, same format as the vault value field.
    value: string;
}

//
// Resolution chosen when an incoming secret name conflicts with an existing entry.
//
export interface IConflictResolution {
    // 'replace': overwrite the existing entry.
    // 'reuse': skip importing; keep the existing entry as-is.
    // 'rename': save the incoming secret under a different name.
    action: "replace" | "reuse" | "rename";

    // Required when action is 'rename'; the new key name to use.
    newName?: string;
}

//
// Callback invoked when an incoming secret's name already exists. Returns how to resolve the
// conflict. Async so an interactive caller (desktop) can prompt the user; a caller that already has
// the resolutions (mobile) simply returns them.
//
export type ConflictResolver = (secretName: string, secretType: string) => Promise<IConflictResolution>;

//
// The minimal storage a secret importer writes through, so this module never depends on a concrete
// vault or config store. Methods return promises so an async backend (the OS vault) and a sync one
// (the WebView config store, wrapped) both satisfy it.
//
export interface IShareSecretStore {
    // Whether a secret with the given name already exists.
    has(name: string): Promise<boolean>;

    // Creates or overwrites a secret with the given name, type and value.
    write(name: string, secretType: string, value: string): Promise<void>;
}

//
// The resolved secret key names for a received database, one per included secret (undefined when the
// database did not include that kind of secret). The caller uses these to build its database entry.
//
export interface IShareResolvedKeys {
    // Final key name the S3 credentials were stored under.
    s3Key?: string;

    // Final key name the encryption key was stored under.
    encryptionKey?: string;

    // Final key name the geocoding API key was stored under.
    geocodingKey?: string;
}

//
// The final name a secret is stored under and whether its value should be written (false = the user
// chose to reuse the existing secret rather than overwrite it).
//
interface IResolvedSecret {
    // The name the secret is stored under (unchanged, or the rename target).
    finalName: string;

    // Whether to write the value.
    shouldWrite: boolean;
}

//
// Checks whether an incoming secret name already exists and, if so, applies the caller's conflict
// resolution. Returns the final name and whether the value should be written.
//
async function resolveConflict(store: IShareSecretStore, name: string, secretType: string, resolveConflictCallback: ConflictResolver): Promise<IResolvedSecret> {
    if (!(await store.has(name))) {
        return { finalName: name, shouldWrite: true };
    }

    const resolution = await resolveConflictCallback(name, secretType);

    if (resolution.action === "reuse") {
        return { finalName: name, shouldWrite: false };
    }

    if (resolution.action === "rename") {
        return { finalName: resolution.newName!, shouldWrite: true };
    }

    return { finalName: name, shouldWrite: true };
}

//
// Writes each secret included in a received database payload (S3 credentials, encryption key,
// geocoding key), honouring per-secret conflict resolutions, and returns the final key names the
// caller's database entry should reference. This is the logic desktop and mobile previously
// duplicated: the only per-platform differences (which store, and how the resolved keys become a
// database entry) are supplied by the caller through `store` and the return value.
//
export async function importShareSecrets(payload: IDatabaseSharePayload, store: IShareSecretStore, resolveConflictCallback: ConflictResolver): Promise<IShareResolvedKeys> {
    const resolvedKeys: IShareResolvedKeys = {};

    if (payload.s3Credentials) {
        const { finalName, shouldWrite } = await resolveConflict(store, payload.s3Credentials.name, "s3-credentials", resolveConflictCallback);
        resolvedKeys.s3Key = finalName;
        if (shouldWrite) {
            await store.write(finalName, "s3-credentials", JSON.stringify({
                region: payload.s3Credentials.region,
                accessKeyId: payload.s3Credentials.accessKeyId,
                secretAccessKey: payload.s3Credentials.secretAccessKey,
                endpoint: payload.s3Credentials.endpoint,
            }));
        }
    }

    if (payload.encryptionKey) {
        const { finalName, shouldWrite } = await resolveConflict(store, payload.encryptionKey.name, "encryption-key", resolveConflictCallback);
        resolvedKeys.encryptionKey = finalName;
        if (shouldWrite) {
            await store.write(finalName, "encryption-key", payload.encryptionKey.privateKeyPem);
        }
    }

    if (payload.geocodingKey) {
        const { finalName, shouldWrite } = await resolveConflict(store, payload.geocodingKey.name, "api-key", resolveConflictCallback);
        resolvedKeys.geocodingKey = finalName;
        if (shouldWrite) {
            await store.write(finalName, "api-key", payload.geocodingKey.apiKey);
        }
    }

    return resolvedKeys;
}
