//
// Merkle tree utilities for BSON database.
//

import * as crypto from "crypto";
import stringify from "json-stable-stringify";
import { 
    createTree, 
    addItem, 
    buildMerkleTree, 
    saveTree, 
    loadTree,
    IMerkleTree, 
    HashedItem,
    compareNames, 
} from "merkle-tree";
import { BsonCollection, IInternalRecord } from "./collection";
import { IStorage } from "storage";
import { IUuidGenerator, TimestampProvider } from "utils";

//
// Hashes a record and returns a HashedItem.
//
export function hashRecord(record: IInternalRecord): HashedItem {
    const jsonString = stringify(record.fields) || '';
    const recordHash = crypto.createHash('sha256').update(jsonString, 'utf8').digest();
    return {
        name: record._id,
        hash: recordHash,
        length: jsonString.length,
        lastModified: new Date(),
    };
}

//
// Builds a merkle tree for a shard with record hashes as leaves.
// Records are sorted by their _id before being added to the tree.
//
export async function buildShardMerkleTree(records: IInternalRecord[], uuidGenerator: IUuidGenerator): Promise<IMerkleTree<undefined>> {

    let merkleTree = createTree<undefined>(uuidGenerator.generate());
    
    for (const record of records) {
        const hashedItem = hashRecord(record);
        merkleTree = addItem(merkleTree, hashedItem);
    }

    return merkleTree;
}

//
// Saves a shard merkle tree next to the shard file.
//
export async function saveShardMerkleTree(storage: IStorage, collectionDirectory: string, shardId: string, tree: IMerkleTree<undefined>): Promise<void> {

    if (tree.dirty) {
        tree.merkle = buildMerkleTree(tree.sort);
        tree.dirty = false;
    }

    const shardFilePath = `${collectionDirectory}/${shardId}`;
    const treeFilePath = `${shardFilePath}.dat`; //todo: Might be useful to bake this into the shard file?
    await saveTree(treeFilePath, tree, storage);
}

//
// Loads a shard merkle tree.
//
export async function loadShardMerkleTree(storage: IStorage, collectionDirectory: string, shardId: string): Promise<IMerkleTree<undefined> | undefined> {
    const shardFilePath = `${collectionDirectory}/${shardId}`;
    const treeFilePath = `${shardFilePath}.dat`;
    return await loadTree<undefined>(treeFilePath, storage);
}

//
// Lists existing shard IDs in a collection.
//
export async function listShards(storage: IStorage, collectionDirectory: string): Promise<string[]> {
    const shardIds: string[] = [];
    let next: string | undefined = undefined;
    
    do {
        const storageResult = await storage.listFiles(collectionDirectory, 1000, next);
        for (const fileName of storageResult.names) {
            if (fileName.includes('.')) {
                // We are only interested in files with no extension.
                continue;
            }

            shardIds.push(fileName);
        }
        next = storageResult.next;
    } while (next);
    
    return shardIds.sort(compareNames); //todo: I'm not sure these should be sorted at this point.
}

//
// Builds a merkle tree for a collection with shard root hashes as leaves.
//
export async function buildCollectionMerkleTree(
    storage: IStorage,
    collectionName: string,
    collectionDirectory: string,
    uuidGenerator: IUuidGenerator,
    rebuild: boolean
): Promise<IMerkleTree<undefined>> {

    const shardIds = await listShards(storage, collectionDirectory);
    let collectionTree = createTree<undefined>(uuidGenerator.generate());

    for (const shardId of shardIds) {
        const collection = new BsonCollection<any>(collectionName, {
            storage,
            directory: collectionDirectory,
            uuidGenerator,
            timestampProvider: new TimestampProvider()
        });
        const records: IInternalRecord[] = await collection.loadRecords(`${collectionDirectory}/${shardId}`);
        let shardTree: IMerkleTree<undefined> | undefined;

        if (rebuild) {
            // Rebuild the shard tree.
            shardTree = await buildShardMerkleTree(records, uuidGenerator);
            await saveShardMerkleTree(storage, collectionDirectory, shardId, shardTree);
        }
        else {
            shardTree = await loadShardMerkleTree(storage, collectionDirectory, shardId);
            if (!shardTree) {
                // Shard tree doesn't exist, build it.
                shardTree = await buildShardMerkleTree(records, uuidGenerator);
                await saveShardMerkleTree(storage, collectionDirectory, shardId, shardTree);
            }
        }

        if (shardTree && shardTree.merkle) {
            const shardKey = `${shardId}`;
            const hashedItem: HashedItem = {
                name: shardKey,
                hash: shardTree.merkle.hash,
                length: shardTree.merkle.nodeCount,
                lastModified: new Date(),
            };
            collectionTree = addItem(collectionTree, hashedItem);
        }
    }

    return collectionTree;
}

//
// Saves a collection merkle tree in the collection directory.
//
export async function saveCollectionMerkleTree(storage: IStorage, collectionDirectory: string, tree: IMerkleTree<undefined>): Promise<void> {

    if (tree.dirty) {
        tree.merkle = buildMerkleTree(tree.sort);
        tree.dirty = false;
    }

    const treeFilePath = `${collectionDirectory}/collection.dat`;
    await saveTree(treeFilePath, tree, storage);
}

//
// Loads a collection merkle tree.
//
export async function loadCollectionMerkleTree(storage: IStorage, collectionDirectory: string): Promise<IMerkleTree<undefined> | undefined> {
    const treeFilePath = `${collectionDirectory}/collection.dat`;
    return await loadTree<undefined>(treeFilePath, storage);
}

//
// Lists all collections in the database.
//
async function listCollections(storage: IStorage, databaseDir: string): Promise<string[]> {
    const uniqueSet = new Set<string>();
    let next: string | undefined = undefined;
    do {
        const storageResult = await storage.listDirs(databaseDir, 1000, next);
        for (const name of storageResult.names) { 
            // Filter out system directories
            if (name === 'sort_indexes') {
                continue;
            }
            uniqueSet.add(name);
        }
        next = storageResult.next;
    } while (next);
    
    return Array.from(uniqueSet);
}

//
// Builds a merkle tree for a database with collection root hashes as leaves.
//
export async function buildDatabaseMerkleTree(
    storage: IStorage,
    uuidGenerator: IUuidGenerator,
    databaseDir: string,
    preloadedCollectionName: string | undefined,
    preloadedCollectionTree: IMerkleTree<undefined> | undefined,
    rebuild: boolean
): Promise<IMerkleTree<undefined>> {

    console.log(`Building database merkle tree for database: ${databaseDir}`); //fio:

    const collections = await listCollections(storage, databaseDir);
    console.log(`Collections: ${collections.length}`); //fio:
    let databaseTree = createTree<undefined>(uuidGenerator.generate());

    for (const collectionName of collections) {
        let collectionTree: IMerkleTree<undefined> | undefined;
        if (preloadedCollectionName === collectionName) {
            // Use the pre-loaded collection tree.
            collectionTree = preloadedCollectionTree;
        } 
        else if (rebuild) {
            // Rebuild the collection tree.
            collectionTree = await buildCollectionMerkleTree(storage, collectionName, `${databaseDir}/${collectionName}`, uuidGenerator, rebuild);
            await saveCollectionMerkleTree(storage, `${databaseDir}/${collectionName}`, collectionTree);
        }
        else {
            // Load the collection tree.
            collectionTree = await loadCollectionMerkleTree(storage, `${databaseDir}/${collectionName}`);
            if (!collectionTree) {
                // Collection tree doesn't exist, build it.
                collectionTree = await buildCollectionMerkleTree(storage, collectionName, `${databaseDir}/${collectionName}`, uuidGenerator, rebuild);
                await saveCollectionMerkleTree(storage, `${databaseDir}/${collectionName}`, collectionTree);
            }
        }
        
        if (collectionTree && collectionTree.merkle) {
            const hashedItem: HashedItem = {
                name: collectionName,
                hash: collectionTree.merkle.hash,
                length: collectionTree.merkle.nodeCount,
                lastModified: new Date(),
            };
            databaseTree = addItem(databaseTree, hashedItem);
        }
    }

    return databaseTree;
}

//
// Saves a database merkle tree.
//
export async function saveDatabaseMerkleTree(storage: IStorage, tree: IMerkleTree<undefined>): Promise<void> {

    if (tree.dirty) {
        tree.merkle = buildMerkleTree(tree.sort);
        tree.dirty = false;
    }

    const treeFilePath = "db.dat";
    await saveTree(treeFilePath, tree, storage);
}

//
// Loads a database merkle tree.
//
export async function loadDatabaseMerkleTree(storage: IStorage): Promise<IMerkleTree<undefined> | undefined> {
    const treeFilePath = "db.dat";
    return await loadTree<undefined>(treeFilePath, storage);
}

//
// Checks if the database merkle tree exists.
//
export async function databaseMerkleTreeExists(storage: IStorage): Promise<boolean> {
    const treeFilePath = "db.dat";
    return await storage.fileExists(treeFilePath);
}

//
// Gets the root hash for the database from its merkle tree.
// Returns undefined if the database merkle tree doesn't exist or has no root hash.
//
export async function getDatabaseRootHash(storage: IStorage): Promise<Buffer | undefined> {
    const tree = await loadDatabaseMerkleTree(storage);
    return tree?.merkle?.hash;
}

