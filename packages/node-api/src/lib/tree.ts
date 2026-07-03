import { buildMerkleTree, saveTree, IMerkleTree, loadTree, createTree, upsertItem, combineHashes } from "merkle-tree";
import { IDatabaseMetadata } from "./media-file-database";
import { IStorage, walkDirectory } from "storage";
import {
    loadCollectionMerkleTree as loadCollectionMerkleTreeBdb,
    loadShardMerkleTree as loadShardMerkleTreeBdb,
    getDatabaseRootHash,
} from "bdb";
import { computeHash } from "./hash";
import { batchGenerator, retry, IUuidGenerator } from "utils";
import { LARGE_FILE_TIMEOUT, mergeDatabaseState, updateDatabaseStateLocked, IDatabaseState } from "api";

//
// Path for the files Merkle tree (v6). Legacy path was .db/tree.dat.
// The files tree stores hash, length, and lastModified of the logical (plain/decrypted)
// content of each file only, so that plain and encrypted databases compare equal via compare.
//
const FILES_TREE_PATH = ".db/files.dat";

//
// Path for the encryption public-key marker (indicates database is encrypted).
//
const ENCRYPTION_PUB_PATH = ".db/encryption.pub";

//
// Checks if the merkle tree exists.
//
export async function merkleTreeExists(assetStorage: IStorage): Promise<boolean> {
    return await assetStorage.fileExists(FILES_TREE_PATH);
}

//
// Returns true if the database has an encryption marker (storage is scoped to db root).
//
export async function isDatabaseEncrypted(assetStorage: IStorage): Promise<boolean> {
    return await assetStorage.fileExists(ENCRYPTION_PUB_PATH);
}

//
// Saves the merkle tree to disk.
//
export async function saveMerkleTree(merkleTree: IMerkleTree<IDatabaseMetadata>, assetStorage: IStorage): Promise<void> {
    if (!merkleTree) {
        throw new Error("Cannot save database. No merkle tree provided.");
    }

    if (merkleTree.dirty) {
        merkleTree.merkle = buildMerkleTree(merkleTree.sort);
        merkleTree.dirty = false;
    }

    await saveTree(FILES_TREE_PATH, merkleTree, assetStorage);
}

//
// Loads the merkle tree from disk.
//
export async function loadMerkleTree(assetStorage: IStorage): Promise<IMerkleTree<IDatabaseMetadata> | undefined> {
    return await loadTree(FILES_TREE_PATH, assetStorage);
}

//
// Gets the root hash for the files merkle tree.
// Returns undefined if the merkle tree doesn't exist or has no root hash.
//
export async function getFilesRootHash(assetStorage: IStorage): Promise<Buffer | undefined> {
    const tree = await loadMerkleTree(assetStorage);
    return tree?.merkle?.hash;
}

//
// BSON database path within a database (v6 layout).
//
const BSON_DB_PATH = ".db/bson";

//
// Computes the combined content hash of the database: the files-tree root combined with the bson-db-tree root.
// Two databases with the same content hash are identical. Returns undefined if either root is unavailable
// (e.g. an empty database), in which case callers skip the content-hash based sync early-out.
//
export async function getDatabaseContentHash(assetStorage: IStorage): Promise<Buffer | undefined> {
    const filesRootHash = await getFilesRootHash(assetStorage);
    if (!filesRootHash) {
        return undefined;
    }
    const bsonRootHash = await getDatabaseRootHash(assetStorage, BSON_DB_PATH);
    if (!bsonRootHash) {
        return undefined;
    }
    return combineHashes(filesRootHash, bsonRootHash);
}

//
// Builds the state-file partial for a stamp: the given fields plus the database's current content hash
// (only when both merkle trees are available, so an empty database does not clear an existing hash).
//
async function buildStampPartial(assetStorage: IStorage, extra: Partial<IDatabaseState>): Promise<Partial<IDatabaseState>> {
    const partial: Partial<IDatabaseState> = { ...extra };
    const contentHash = await getDatabaseContentHash(assetStorage);
    if (contentHash) {
        partial.contentHash = contentHash;
    }
    return partial;
}

//
// Refreshes the content hash in the state file together with the given fields (e.g. lastModifiedAt or
// lastSyncedAt). Lock-free: the caller must already hold the database write lock and should call this as
// the last step of the locked mutation, after the merkle tree and bson database are persisted. A crash
// between persisting the trees and this call leaves the previous content hash, which only causes an extra
// full sync (which self-heals the state file), never data loss.
//
export async function stampDatabaseState(assetStorage: IStorage, rawStorage: IStorage, extra: Partial<IDatabaseState>): Promise<void> {
    await mergeDatabaseState(rawStorage, await buildStampPartial(assetStorage, extra));
}

//
// Records that the database was modified locally: stamps lastModifiedAt and refreshes the content hash.
// Lock-free: the caller must already hold the database write lock.
//
export async function stampDatabaseModified(assetStorage: IStorage, rawStorage: IStorage): Promise<void> {
    await stampDatabaseState(assetStorage, rawStorage, { lastModifiedAt: new Date().toISOString() });
}

//
// Refreshes the content hash in the state file together with the given fields (e.g. lastSyncedAt or
// lastReplicatedAt), acquiring the write lock for the duration. For callers that do not already hold the
// lock (replicate, repair). Does nothing if the lock cannot be acquired.
//
export async function stampDatabaseStateLocked(assetStorage: IStorage, rawStorage: IStorage, sessionId: string, extra: Partial<IDatabaseState>): Promise<void> {
    await updateDatabaseStateLocked(rawStorage, sessionId, await buildStampPartial(assetStorage, extra));
}

//
// BDB collection path (v6 layout: collections/<name>). Used by loaders below so callers pass only collection name.
//
const COLLECTION_DIR_PREFIX = "collections/";

//
// Loads a collection Merkle tree by collection name (v6 path: collections/<name>).
//
export async function loadCollectionMerkleTree(
    storage: IStorage,
    collectionName: string
): Promise<IMerkleTree<undefined> | undefined> {
    return loadCollectionMerkleTreeBdb(storage, ".db/bson", collectionName);
}

//
// Loads a shard Merkle tree by collection name and shard ID (v6 path: collections/<name>/shards/<id>).
//
export async function loadShardMerkleTree(
    storage: IStorage,
    collectionName: string,
    shardId: string
): Promise<IMerkleTree<undefined> | undefined> {
    return loadShardMerkleTreeBdb(storage, ".db/bson", collectionName, shardId);
}

//
// Result of buildFilesTree: the rebuilt tree and the number of files included.
//
export interface IBuildFilesTreeResult {
    merkleTree: IMerkleTree<IDatabaseMetadata>;
    fileCount: number;
}

//
// Builds the files merkle tree from storage: walks only paths that belong in the tree
// (asset/, display/, thumb/; skips .db/). Hashes each file via storage (logical content
// when encrypted), upserts into tree, saves once. Reads and hashes up to BATCH_SIZE
// files in parallel per batch to overlap I/O.
//
export async function buildFilesTree(
    storage: IStorage,
    progressCallback: (fileCount: number) => void,
    uuidGenerator: IUuidGenerator
): Promise<IBuildFilesTreeResult> {
    const existingTree = await retry(() => loadMerkleTree(storage));
    const newTreeId = existingTree ? existingTree.id : uuidGenerator.generate();
    let merkleTree = createTree<IDatabaseMetadata>(newTreeId);
    let databaseMetadata: IDatabaseMetadata = existingTree?.databaseMetadata
        ? { ...existingTree.databaseMetadata }
        : { filesImported: 0 };
    let filesImported = 0;
    let fileCount = 0;

    async function readAndHash(fileName: string): Promise<{ fileName: string; hash: Buffer; length: number; lastModified: Date }> {
        const info = await retry(() => storage.info(fileName));
        if (!info) {
            throw new Error(`No info for file listed in storage: ${fileName}`);
        }
        const hash = await retry(async () => computeHash(await storage.readStream(fileName)), 3, 1_000, 2, LARGE_FILE_TIMEOUT, `Failed to hash file ${fileName}`);
        return { fileName, hash, length: info.length, lastModified: info.lastModified };
    }

    const BATCH_SIZE = 100;
    for await (const batch of batchGenerator(walkDirectory(storage, "", [/^\.db(\/|$)/]), BATCH_SIZE)) {
        const results = await Promise.all(batch.map(({ fileName }) => readAndHash(fileName)));
        for (const r of results) {
            merkleTree = upsertItem(merkleTree, {
                name: r.fileName,
                hash: r.hash,
                length: r.length,
                lastModified: r.lastModified,
            });
            fileCount++;
            if (r.fileName.startsWith("asset/")) {
                filesImported++;
            }
            progressCallback(fileCount);
        }
    }

    databaseMetadata.filesImported = filesImported;
    merkleTree.databaseMetadata = databaseMetadata;
    await retry(() => saveMerkleTree(merkleTree, storage));
    return { merkleTree, fileCount };
}

