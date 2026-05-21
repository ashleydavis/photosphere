import { IStorage, IS3Credentials, IEncryptionKeyPem, IStorageOptions, createStorage, loadEncryptionKeysFromPem } from "storage";
import { resolveStorageCredentials } from "./resolve-storage-credentials";

//
// Result of opening a database storage instance via openStorage.
// Bundles the constructed storage with the credentials that were used so callers can reuse them
// (e.g. to write an encryption.pub file when the destination is encrypted).
//
export interface IOpenStorageResult {
    //
    // The configured storage instance (transparently decrypts when an encryption key is in use).
    //
    storage: IStorage;

    //
    // The raw underlying storage instance (no encryption layer). Used for reading or writing
    // metadata that must bypass encryption, such as .db/encryption.pub.
    //
    rawStorage: IStorage;

    //
    // The PEM key pairs resolved for this path. Empty when the path is unencrypted.
    //
    encryptionKeyPems: IEncryptionKeyPem[];

    //
    // The S3 credentials used to construct the storage. Undefined for non-s3: paths.
    //
    s3Config: IS3Credentials | undefined;

    //
    // The storage options used to construct the storage. Exposed so callers that need to build
    // a derived storage (e.g. createLazyDatabaseStorage) can reuse them without re-deriving.
    //
    storageOptions: IStorageOptions;

    //
    // The Google geocoding API key, when configured for this path.
    //
    googleApiKey: string | undefined;
}

//
// Resolves credentials for the given database path and constructs the storage instance.
// Wraps the standard resolveStorageCredentials + loadEncryptionKeysFromPem + createStorage
// pattern used by every worker handler so the call sites do not duplicate it.
//
// encryptionKey and s3Key are forwarded to resolveStorageCredentials — callers supply them when
// the path is not in databases.json (e.g. the destination of a replicate task) or to override
// the registered values.
//
export async function openStorage(
    databasePath: string,
    encryptionKey?: string,
    s3Key?: string
): Promise<IOpenStorageResult> {
    const { s3Config, encryptionKeyPems, googleApiKey } = await resolveStorageCredentials(databasePath, encryptionKey, s3Key);
    const { options: storageOptions } = await loadEncryptionKeysFromPem(encryptionKeyPems);
    const { storage, rawStorage } = createStorage(databasePath, s3Config, storageOptions);
    return { storage, rawStorage, encryptionKeyPems, s3Config, storageOptions, googleApiKey };
}
