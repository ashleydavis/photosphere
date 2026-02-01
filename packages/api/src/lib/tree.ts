import { buildMerkleTree, saveTree, IMerkleTree, loadTree, createTree } from "merkle-tree";
import { IDatabaseMetadata } from "./media-file-database";
import { IStorage } from "storage";
import {
    loadCollectionMerkleTree as loadCollectionMerkleTreeBdb,
    loadShardMerkleTree as loadShardMerkleTreeBdb,
} from "bdb";

//
// Path for the files Merkle tree (v6). Legacy path was .db/tree.dat.
//
const FILES_TREE_PATH = ".db/files.dat";

//
// Path for the encryption public-key marker (indicates database is encrypted).
//
const ENCRYPTION_PUB_PATH = ".db/encryption.pub";

//
// Checks if the merkle tree exists.
//
export async function merkleTreeExists(metadataStorage: IStorage): Promise<boolean> {
    return await metadataStorage.fileExists(FILES_TREE_PATH);
}

//
// Returns true if the database has an encryption marker (storage is scoped to db root).
//
export async function isDatabaseEncrypted(metadataStorage: IStorage): Promise<boolean> {
    return await metadataStorage.fileExists(ENCRYPTION_PUB_PATH);
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
export async function loadMerkleTree(metadataStorage: IStorage): Promise<IMerkleTree<IDatabaseMetadata> | undefined> {
    return await loadTree(FILES_TREE_PATH, metadataStorage);
}

//
// Gets the root hash for the files merkle tree.
// Returns undefined if the merkle tree doesn't exist or has no root hash.
//
export async function getFilesRootHash(metadataStorage: IStorage): Promise<Buffer | undefined> {
    const tree = await loadMerkleTree(metadataStorage);
    return tree?.merkle?.hash;
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
    const collectionDir = COLLECTION_DIR_PREFIX + collectionName;
    return loadCollectionMerkleTreeBdb(storage, collectionDir);
}

//
// Loads a shard Merkle tree by collection name and shard ID (v6 path: collections/<name>/shards/<id>).
//
export async function loadShardMerkleTree(
    storage: IStorage,
    collectionName: string,
    shardId: string
): Promise<IMerkleTree<undefined> | undefined> {
    const collectionDir = COLLECTION_DIR_PREFIX + collectionName;
    return loadShardMerkleTreeBdb(storage, collectionDir, shardId);
}

