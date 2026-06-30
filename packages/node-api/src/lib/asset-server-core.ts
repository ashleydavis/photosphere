import { createStorage, loadEncryptionKeysFromPem, type IStorage } from "storage";
import type { IDatabaseOp } from "api";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import { streamAsset, writeAssetStream, createLazyDatabaseStorage } from "./media-file-database";
import { resolveStorageCredentials } from "./resolve-storage-credentials";
import { applyDatabaseOps as applyDatabaseOpsToStorage } from "./apply-database-ops";

//
// Options for creating the transport-agnostic asset server core.
//
export interface IAssetServerCoreOptions {
    //
    // UUID generator used when applying database ops.
    //
    uuidGenerator: IUuidGenerator;

    //
    // Timestamp provider used when applying database ops.
    //
    timestampProvider: ITimestampProvider;

    //
    // Write-lock owner for write/apply operations (see acquireWriteLock).
    //
    sessionId: string;
}

//
// The transport-agnostic asset server core. Holds the storage cache and exposes the
// serve/write/apply operations the HTTP routes call, with no knowledge of express or HTTP.
// The same core is reused by the express wiring on Node and by the asset-server task.
//
export interface IAssetServerCore {
    //
    // Loads one asset variant (thumb | display | asset) from a database directory and returns it as a byte stream.
    //
    serveAsset(assetId: string, assetType: string, databasePath: string): Promise<NodeJS.ReadableStream>;

    //
    // Writes raw bytes for one asset variant into a database directory from a byte stream.
    //
    writeAsset(assetId: string, assetType: string, databasePath: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength: number | undefined): Promise<void>;

    //
    // Applies metadata operations to one or more on-disk databases.
    //
    applyDatabaseOps(ops: IDatabaseOp[]): Promise<void>;
}

//
// Creates the transport-agnostic asset server core. The returned object owns a cache of lazy
// database storage instances keyed by database path, so repeated reads avoid re-reading the
// config / merkle-tree files. The HTTP layer (express on Node, the shimmed http on mobile) calls
// these methods; their behaviour is identical regardless of how the request arrived.
//
export function createAssetServerCore(options: IAssetServerCoreOptions): IAssetServerCore {
    const { uuidGenerator, timestampProvider, sessionId } = options;

    //
    // Cache of lazy database storage instances keyed by database path.
    // Avoids recreating storage (and re-reading the config/merkle-tree files) on every asset request.
    //
    const storageCache = new Map<string, IStorage>();

    //
    // Returns a cached lazy storage instance for the given database path, creating one if needed.
    //
    async function getAssetStorage(databasePath: string): Promise<IStorage> {
        const cached = storageCache.get(databasePath);
        if (cached) {
            return cached;
        }
        const { s3Config, encryptionKeyPems } = await resolveStorageCredentials(databasePath);
        const { options: storageOptions } = await loadEncryptionKeysFromPem(encryptionKeyPems);
        const storage = await createLazyDatabaseStorage(databasePath, s3Config, storageOptions);
        storageCache.set(databasePath, storage);
        return storage;
    }

    return {
        async serveAsset(assetId: string, assetType: string, databasePath: string): Promise<NodeJS.ReadableStream> {
            const assetStorage = await getAssetStorage(databasePath);
            return await streamAsset(assetStorage, assetId, assetType);
        },

        async writeAsset(assetId: string, assetType: string, databasePath: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength: number | undefined): Promise<void> {
            const { storage, rawStorage } = createStorage(databasePath, undefined, undefined);
            await writeAssetStream(storage, rawStorage, sessionId, assetId, assetType, contentType, inputStream, contentLength);
        },

        async applyDatabaseOps(ops: IDatabaseOp[]): Promise<void> {
            await applyDatabaseOpsToStorage(uuidGenerator, timestampProvider, sessionId, ops);
        },
    };
}
