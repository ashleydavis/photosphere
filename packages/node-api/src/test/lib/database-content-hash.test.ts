import * as fs from "node:fs";
import * as path from "node:path";
import { createStorage, IStorage } from "storage";
import { TestUuidGenerator, getProcessTmpDir } from "node-utils";
import { MockTimestampProvider } from "utils";
import { addItem } from "merkle-tree";
import type { IBsonCollection } from "bdb";
import type { IAsset } from "api";
import { createMediaFileDatabase, createDatabase } from "../../lib/media-file-database";
import { getDatabaseContentHash, loadMerkleTree, saveMerkleTree } from "../../lib/tree";

//
// Adds a file entry to the files merkle tree and saves it.
//
async function addFileToFilesTree(assetStorage: IStorage, name: string, seed: number): Promise<void> {
    let tree = await loadMerkleTree(assetStorage);
    if (!tree) {
        throw new Error("files merkle tree missing");
    }
    tree = addItem(tree, {
        name,
        hash: Buffer.alloc(32, seed),
        length: 3,
        lastModified: new Date(0),
    });
    await saveMerkleTree(tree, assetStorage);
}

//
// Inserts a metadata record and commits, so the bson database merkle tree exists on disk.
//
async function commitBsonRecord(bsonDatabase: { commit(): Promise<void> }, metadataCollection: IBsonCollection<IAsset>, recordId: string): Promise<void> {
    await metadataCollection.insertOne({ _id: recordId, origFileName: "photo.jpg" } as unknown as IAsset);
    await bsonDatabase.commit();
}

describe("getDatabaseContentHash", () => {
    test("returns undefined when there is no database", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "content-hash-empty-"));
        try {
            const { storage: assetStorage } = createStorage(tmpDir, undefined, undefined);
            expect(await getDatabaseContentHash(assetStorage)).toBeUndefined();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("returns undefined when the bson database tree is missing", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "content-hash-nobson-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
            const uuidGenerator = new TestUuidGenerator();
            const timestampProvider = new MockTimestampProvider();
            const { metadataCollection } = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
            await createDatabase(assetStorage, rawStorage, uuidGenerator, metadataCollection);

            // Files tree has content, but no bson record has been committed.
            await addFileToFilesTree(assetStorage, "asset/1", 1);

            expect(await getDatabaseContentHash(assetStorage)).toBeUndefined();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("returns a 32-byte combined hash when both trees exist", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "content-hash-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
            const uuidGenerator = new TestUuidGenerator();
            const timestampProvider = new MockTimestampProvider();
            const { bsonDatabase, metadataCollection } = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
            await createDatabase(assetStorage, rawStorage, uuidGenerator, metadataCollection);

            await addFileToFilesTree(assetStorage, "asset/1", 1);
            await commitBsonRecord(bsonDatabase, metadataCollection, "a1b2c3d4-e5f6-7890-abcd-ef1234567890");

            const hash = await getDatabaseContentHash(assetStorage);
            expect(hash).toBeInstanceOf(Buffer);
            expect(hash!.length).toBe(32);
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("changes when the files tree changes", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "content-hash-change-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
            const uuidGenerator = new TestUuidGenerator();
            const timestampProvider = new MockTimestampProvider();
            const { bsonDatabase, metadataCollection } = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
            await createDatabase(assetStorage, rawStorage, uuidGenerator, metadataCollection);

            await addFileToFilesTree(assetStorage, "asset/1", 1);
            await commitBsonRecord(bsonDatabase, metadataCollection, "a1b2c3d4-e5f6-7890-abcd-ef1234567890");
            const before = await getDatabaseContentHash(assetStorage);

            await addFileToFilesTree(assetStorage, "asset/2", 2);
            const after = await getDatabaseContentHash(assetStorage);

            expect(before).toBeInstanceOf(Buffer);
            expect(after).toBeInstanceOf(Buffer);
            expect(after!.equals(before!)).toBe(false);
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });
});
