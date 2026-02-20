import * as crypto from 'crypto';
import {
    replicate,
    iterateLeaves,
    iterateShardDifferences,
    iterateCollectionDifferences,
    iterateDatabaseDifferences,
} from '../../lib/replicate';
import type { MerkleNode } from 'merkle-tree';
import type { HashedItem } from 'merkle-tree';
import { createTree, addItem, buildMerkleTree, saveTree } from 'merkle-tree';
import { MockStorage } from 'storage';
import { BsonDatabase } from 'bdb';
import { TestUuidGenerator } from 'node-utils';
import { MockTimestampProvider } from 'utils';
import type { IDatabaseMetadata } from '../../lib/media-file-database';

function makeHash(seed: string): Buffer {
    return crypto.createHash('sha256').update(seed, 'utf8').digest();
}

const VALID_UUID = '12345678-1234-5678-9abc-123456789abc';

function buildTree(uuid: string, items: HashedItem[]): import('merkle-tree').IMerkleTree<undefined> {
    let tree = createTree<undefined>(uuid);
    for (const item of items) {
        tree = addItem(tree, item);
    }
    tree.merkle = buildMerkleTree(tree.sort);
    tree.dirty = false;
    return tree;
}

async function buildAndSaveTreeAsync(
    storage: MockStorage,
    filePath: string,
    uuid: string,
    leafNames: string[]
): Promise<void> {
    const items: HashedItem[] = leafNames.map(name => ({
        name,
        hash: makeHash(name),
        length: 0,
        lastModified: new Date(),
    }));
    const tree = buildTree(uuid, items);
    await saveTree(filePath, tree, storage);
}

describe('iterateLeaves', () => {
    test('returns empty array for empty nodes', () => {
        const result = [...iterateLeaves([])];
        expect(result).toEqual([]);
    });

    test('yields name of a single leaf node', () => {
        const leaf: MerkleNode = {
            hash: makeHash('a'),
            nodeCount: 1,
            name: 'leaf1',
        };
        const result = [...iterateLeaves([leaf])];
        expect(result).toEqual(['leaf1']);
    });

    test('throws if leaf has no name', () => {
        const leaf: MerkleNode = {
            hash: makeHash('a'),
            nodeCount: 1,
        };
        expect(() => [...iterateLeaves([leaf])]).toThrow('Leaf node has no name');
    });

    test('yields names from multiple leaf nodes', () => {
        const leaves: MerkleNode[] = [
            { hash: makeHash('a'), nodeCount: 1, name: 'a' },
            { hash: makeHash('b'), nodeCount: 1, name: 'b' },
        ];
        const result = [...iterateLeaves(leaves)];
        expect(result).toEqual(['a', 'b']);
    });

    test('recurses into left child', () => {
        const inner: MerkleNode = {
            hash: makeHash('inner'),
            nodeCount: 1,
            name: 'inner',
        };
        const root: MerkleNode = {
            hash: makeHash('root'),
            nodeCount: 2,
            left: inner,
        };
        const result = [...iterateLeaves([root])];
        expect(result).toEqual(['inner']);
    });

    test('recurses into right child', () => {
        const inner: MerkleNode = {
            hash: makeHash('inner'),
            nodeCount: 1,
            name: 'inner',
        };
        const root: MerkleNode = {
            hash: makeHash('root'),
            nodeCount: 2,
            right: inner,
        };
        const result = [...iterateLeaves([root])];
        expect(result).toEqual(['inner']);
    });

    test('recurses into both left and right children', () => {
        const leftLeaf: MerkleNode = { hash: makeHash('l'), nodeCount: 1, name: 'left' };
        const rightLeaf: MerkleNode = { hash: makeHash('r'), nodeCount: 1, name: 'right' };
        const root: MerkleNode = {
            hash: makeHash('root'),
            nodeCount: 3,
            left: leftLeaf,
            right: rightLeaf,
        };
        const result = [...iterateLeaves([root])];
        expect(result).toEqual(['left', 'right']);
    });
});

describe('iterateShardDifferences', () => {
    test('yields nothing when tree1 does not exist', async () => {
        const storage1 = new MockStorage();
        const storage2 = new MockStorage();
        await buildAndSaveTreeAsync(storage2, 'coll/s1.dat', VALID_UUID, ['rec1']);
        const results: Array<{ collectionName: string; recordId: string }> = [];
        for await (const d of iterateShardDifferences('coll', 's1', storage1, storage2)) {
            results.push(d);
        }
        expect(results).toEqual([]);
    });

    test('yields all record ids from tree1 when tree2 does not exist', async () => {
        const storage1 = new MockStorage();
        const storage2 = new MockStorage();
        await buildAndSaveTreeAsync(storage1, 'coll/s1.dat', VALID_UUID, ['rec1', 'rec2']);
        const results: Array<{ collectionName: string; recordId: string }> = [];
        for await (const d of iterateShardDifferences('coll', 's1', storage1, storage2)) {
            results.push(d);
        }
        expect(results).toHaveLength(2);
        expect(results.map(r => r.recordId).sort()).toEqual(['rec1', 'rec2']);
        expect(results.every(r => r.collectionName === 'coll')).toBe(true);
    });

    test('yields differing record ids when both trees exist', async () => {
        const storage1 = new MockStorage();
        const storage2 = new MockStorage();
        await buildAndSaveTreeAsync(storage1, 'coll/s1.dat', VALID_UUID, ['rec1', 'rec2', 'rec3']);
        await buildAndSaveTreeAsync(storage2, 'coll/s1.dat', VALID_UUID, ['rec1']);
        const results: Array<{ collectionName: string; recordId: string }> = [];
        for await (const d of iterateShardDifferences('coll', 's1', storage1, storage2)) {
            results.push(d);
        }
        expect(results.map(r => r.recordId).sort()).toEqual(['rec2', 'rec3']);
        expect(results.every(r => r.collectionName === 'coll')).toBe(true);
    });

    test('yields nothing when both trees are identical', async () => {
        const storage1 = new MockStorage();
        const storage2 = new MockStorage();
        await buildAndSaveTreeAsync(storage1, 'coll/s1.dat', VALID_UUID, ['rec1', 'rec2']);
        await buildAndSaveTreeAsync(storage2, 'coll/s1.dat', VALID_UUID, ['rec1', 'rec2']);
        const results: Array<{ collectionName: string; recordId: string }> = [];
        for await (const d of iterateShardDifferences('coll', 's1', storage1, storage2)) {
            results.push(d);
        }
        expect(results).toEqual([]);
    });
});

describe('iterateCollectionDifferences', () => {
    test('yields nothing when tree1 collection does not exist', async () => {
        const storage1 = new MockStorage();
        const storage2 = new MockStorage();
        await buildAndSaveTreeAsync(storage2, 'coll/collection.dat', VALID_UUID, ['s1']);
        const results: Array<{ collectionName: string; recordId: string }> = [];
        for await (const d of iterateCollectionDifferences('coll', storage1, storage2)) {
            results.push(d);
        }
        expect(results).toEqual([]);
    });

    test('yields record ids from all shards when tree2 collection does not exist', async () => {
        const storage1 = new MockStorage();
        const storage2 = new MockStorage();
        await buildAndSaveTreeAsync(storage1, 'coll/collection.dat', VALID_UUID, ['s1', 's2']);
        await buildAndSaveTreeAsync(storage1, 'coll/s1.dat', VALID_UUID, ['rec1']);
        await buildAndSaveTreeAsync(storage1, 'coll/s2.dat', VALID_UUID, ['rec2', 'rec3']);
        const results: Array<{ collectionName: string; recordId: string }> = [];
        for await (const d of iterateCollectionDifferences('coll', storage1, storage2)) {
            results.push(d);
        }
        expect(results.map(r => r.recordId).sort()).toEqual(['rec1', 'rec2', 'rec3']);
        expect(results.every(r => r.collectionName === 'coll')).toBe(true);
    });

    test('yields differing record ids when both collections exist', async () => {
        const storage1 = new MockStorage();
        const storage2 = new MockStorage();
        const shardItems1 = ['a', 'b', 'c'].map(name => ({ name, hash: makeHash(name), length: 0, lastModified: new Date() }));
        const shardItems2 = ['a'].map(name => ({ name, hash: makeHash(name), length: 0, lastModified: new Date() }));
        const shardTree1 = buildTree(VALID_UUID, shardItems1);
        const shardTree2 = buildTree(VALID_UUID, shardItems2);
        await saveTree('coll/s1.dat', shardTree1, storage1);
        await saveTree('coll/s1.dat', shardTree2, storage2);
        const collTree1 = buildTree(VALID_UUID, [{ name: 's1', hash: shardTree1.merkle!.hash, length: 0, lastModified: new Date() }]);
        const collTree2 = buildTree(VALID_UUID, [{ name: 's1', hash: shardTree2.merkle!.hash, length: 0, lastModified: new Date() }]);
        await saveTree('coll/collection.dat', collTree1, storage1);
        await saveTree('coll/collection.dat', collTree2, storage2);
        const results: Array<{ collectionName: string; recordId: string }> = [];
        for await (const d of iterateCollectionDifferences('coll', storage1, storage2)) {
            results.push(d);
        }
        expect(results.map(r => r.recordId).sort()).toEqual(['b', 'c']);
        expect(results.every(r => r.collectionName === 'coll')).toBe(true);
    });
});

describe('iterateDatabaseDifferences', () => {
    test('yields nothing when tree1 database does not exist', async () => {
        const storage1 = new MockStorage();
        const storage2 = new MockStorage();
        await buildAndSaveTreeAsync(storage2, 'db.dat', VALID_UUID, ['coll']);
        const results: Array<{ collectionName: string; recordId: string }> = [];
        for await (const d of iterateDatabaseDifferences(storage1, storage2)) {
            results.push(d);
        }
        expect(results).toEqual([]);
    });

    test('yields record ids from all collections when tree2 database does not exist', async () => {
        const storage1 = new MockStorage();
        const storage2 = new MockStorage();
        await buildAndSaveTreeAsync(storage1, 'db.dat', VALID_UUID, ['c1', 'c2']);
        await buildAndSaveTreeAsync(storage1, 'c1/collection.dat', VALID_UUID, ['s1']);
        await buildAndSaveTreeAsync(storage1, 'c1/s1.dat', VALID_UUID, ['r1']);
        await buildAndSaveTreeAsync(storage1, 'c2/collection.dat', VALID_UUID, ['s1']);
        await buildAndSaveTreeAsync(storage1, 'c2/s1.dat', VALID_UUID, ['r2']);
        const results: Array<{ collectionName: string; recordId: string }> = [];
        for await (const d of iterateDatabaseDifferences(storage1, storage2)) {
            results.push(d);
        }
        expect(results).toHaveLength(2);
        const byColl = new Map<string, string[]>();
        for (const r of results) {
            const arr = byColl.get(r.collectionName) ?? [];
            arr.push(r.recordId);
            byColl.set(r.collectionName, arr);
        }
        expect(byColl.get('c1')).toEqual(['r1']);
        expect(byColl.get('c2')).toEqual(['r2']);
    });

    test('yields differing record ids when both databases exist', async () => {
        const storage1 = new MockStorage();
        const storage2 = new MockStorage();
        const shardItems1 = ['id1', 'id2'].map(name => ({ name, hash: makeHash(name), length: 0, lastModified: new Date() }));
        const shardItems2 = ['id1'].map(name => ({ name, hash: makeHash(name), length: 0, lastModified: new Date() }));
        const shardTree1 = buildTree(VALID_UUID, shardItems1);
        const shardTree2 = buildTree(VALID_UUID, shardItems2);
        await saveTree('coll/s1.dat', shardTree1, storage1);
        await saveTree('coll/s1.dat', shardTree2, storage2);
        const collTree1 = buildTree(VALID_UUID, [{ name: 's1', hash: shardTree1.merkle!.hash, length: 0, lastModified: new Date() }]);
        const collTree2 = buildTree(VALID_UUID, [{ name: 's1', hash: shardTree2.merkle!.hash, length: 0, lastModified: new Date() }]);
        await saveTree('coll/collection.dat', collTree1, storage1);
        await saveTree('coll/collection.dat', collTree2, storage2);
        const dbTree1 = buildTree(VALID_UUID, [{ name: 'coll', hash: collTree1.merkle!.hash, length: 0, lastModified: new Date() }]);
        const dbTree2 = buildTree(VALID_UUID, [{ name: 'coll', hash: collTree2.merkle!.hash, length: 0, lastModified: new Date() }]);
        await saveTree('db.dat', dbTree1, storage1);
        await saveTree('db.dat', dbTree2, storage2);
        const results: Array<{ collectionName: string; recordId: string }> = [];
        for await (const d of iterateDatabaseDifferences(storage1, storage2)) {
            results.push(d);
        }
        expect(results.map(r => r.recordId).sort()).toEqual(['id2']);
        expect(results[0].collectionName).toBe('coll');
    });
});

describe('replicate', () => {
    const uuidGenerator = new TestUuidGenerator();
    const timestampProvider = new MockTimestampProvider();
    const dbId = uuidGenerator.generate();

    test('throws when source merkle tree fails to load', async () => {
        const sourceMeta = new MockStorage();
        const sourceAsset = new MockStorage();
        const destMeta = new MockStorage();
        const destAsset = new MockStorage();
        const sourceBdb = new BsonDatabase({ storage: new MockStorage(), uuidGenerator, timestampProvider });
        await expect(
            replicate(
                sourceAsset,
                sourceMeta,
                sourceBdb,
                uuidGenerator,
                timestampProvider,
                destAsset,
                destMeta,
                undefined,
                undefined
            )
        ).rejects.toThrow('Failed to load merkle tree');
    });

    test('throws when dest has different database ID and force is not set', async () => {
        const sourceMeta = new MockStorage();
        const sourceAsset = new MockStorage();
        const destMeta = new MockStorage();
        const destAsset = new MockStorage();
        const sourceBdb = new BsonDatabase({ storage: new MockStorage(), uuidGenerator, timestampProvider });
        let sourceTree = createTree<IDatabaseMetadata>(dbId);
        sourceTree.databaseMetadata = { filesImported: 0 };
        sourceTree.merkle = buildMerkleTree(sourceTree.sort);
        sourceTree.dirty = false;
        await saveTree('.db/tree.dat', sourceTree, sourceMeta);
        const destDbId = uuidGenerator.generate();
        let destTree = createTree<IDatabaseMetadata>(destDbId);
        destTree.databaseMetadata = { filesImported: 0 };
        destTree.merkle = buildMerkleTree(destTree.sort);
        destTree.dirty = false;
        await saveTree('.db/tree.dat', destTree, destMeta);
        await expect(
            replicate(
                sourceAsset,
                sourceMeta,
                sourceBdb,
                uuidGenerator,
                timestampProvider,
                destAsset,
                destMeta,
                undefined,
                undefined
            )
        ).rejects.toThrow('You are trying to replicate');
    });

    test('succeeds when force is true and database IDs differ', async () => {
        const sourceMeta = new MockStorage();
        const sourceAsset = new MockStorage();
        const destMeta = new MockStorage();
        const destAsset = new MockStorage();
        const sourceBdb = new BsonDatabase({ storage: new MockStorage(), uuidGenerator, timestampProvider });
        const destBdbStorage = new MockStorage();
        const destBdb = new BsonDatabase({ storage: destBdbStorage, uuidGenerator, timestampProvider });
        let sourceTree = createTree<IDatabaseMetadata>(dbId);
        sourceTree.databaseMetadata = { filesImported: 0 };
        sourceTree.merkle = buildMerkleTree(sourceTree.sort);
        sourceTree.dirty = false;
        await saveTree('.db/tree.dat', sourceTree, sourceMeta);
        const destDbId = uuidGenerator.generate();
        let destTree = createTree<IDatabaseMetadata>(destDbId);
        destTree.databaseMetadata = { filesImported: 0 };
        destTree.merkle = buildMerkleTree(destTree.sort);
        destTree.dirty = false;
        await saveTree('.db/tree.dat', destTree, destMeta);
        const result = await replicate(
            sourceAsset,
            sourceMeta,
            sourceBdb,
            uuidGenerator,
            timestampProvider,
            destAsset,
            destMeta,
            { force: true },
            undefined
        );
        expect(result).toBeDefined();
        expect(result.filesImported).toBe(0);
        expect(result.copiedFiles).toBe(0);
        expect(result.copiedRecords).toBe(0);
        expect(Array.isArray(result.prunedFiles)).toBe(true);
    });

    test('returns result shape with zero counts when source has no files and empty dest', async () => {
        const sourceMeta = new MockStorage();
        const sourceAsset = new MockStorage();
        const destMeta = new MockStorage();
        const destAsset = new MockStorage();
        const sourceBdbStorage = new MockStorage();
        const sourceBdb = new BsonDatabase({ storage: sourceBdbStorage, uuidGenerator, timestampProvider });
        let sourceTree = createTree<IDatabaseMetadata>(dbId);
        sourceTree.databaseMetadata = { filesImported: 0 };
        sourceTree.merkle = buildMerkleTree(sourceTree.sort);
        sourceTree.dirty = false;
        await saveTree('.db/tree.dat', sourceTree, sourceMeta);
        const result = await replicate(
            sourceAsset,
            sourceMeta,
            sourceBdb,
            uuidGenerator,
            timestampProvider,
            destAsset,
            destMeta,
            undefined,
            undefined
        );
        expect(result).toMatchObject({
            filesImported: 0,
            copiedFiles: 0,
            copiedRecords: 0,
        });
        expect(Array.isArray(result.prunedFiles)).toBe(true);
    });
});
