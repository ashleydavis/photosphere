import * as fs from "node:fs";
import * as path from "node:path";
import { createStorage, IStorage } from "storage";
import { TestUuidGenerator, getProcessTmpDir } from "node-utils";
import { MockTimestampProvider } from "utils";
import { addItem } from "merkle-tree";
import type { IBsonCollection } from "bdb";
import type { IAsset } from "api";
import { loadDatabaseState, saveDatabaseState } from "api";
import { createMediaFileDatabase, createDatabase } from "../../lib/media-file-database";
import { getDatabaseContentHash, loadMerkleTree, saveMerkleTree, stampDatabaseState, stampDatabaseModified, stampDatabaseStateLocked } from "../../lib/tree";

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

//
// Creates a populated database (files tree + one committed bson record) in a temporary directory.
//
async function createPopulatedDatabase(tmpDir: string): Promise<{ assetStorage: IStorage, rawStorage: IStorage }> {
    const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
    const uuidGenerator = new TestUuidGenerator();
    const timestampProvider = new MockTimestampProvider();
    const { bsonDatabase, metadataCollection } = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
    await createDatabase(assetStorage, rawStorage, uuidGenerator, metadataCollection);
    await addFileToFilesTree(assetStorage, "asset/1", 1);
    await commitBsonRecord(bsonDatabase, metadataCollection, "a1b2c3d4-e5f6-7890-abcd-ef1234567890");
    return { assetStorage, rawStorage };
}

describe("stampDatabaseState", () => {
    test("writes the given fields plus the current content hash without acquiring the lock", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "stamp-state-"));
        try {
            const { assetStorage, rawStorage } = await createPopulatedDatabase(tmpDir);

            await stampDatabaseState(assetStorage, rawStorage, { lastSyncedAt: "2026-01-02T03:04:05.000Z" });

            const state = await loadDatabaseState(rawStorage);
            expect(state?.lastSyncedAt).toBe("2026-01-02T03:04:05.000Z");
            const expectedHash = await getDatabaseContentHash(assetStorage);
            expect(state!.contentHash!.equals(expectedHash!)).toBe(true);

            // The write lock was never taken, so it is still free.
            expect(await rawStorage.acquireWriteLock(".db/write.lock", "other")).toBe(true);
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("omits the content hash when the database is empty and preserves other fields", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "stamp-state-empty-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
            await saveDatabaseState(rawStorage, { lastModifiedAt: "2026-01-02T03:04:05.000Z" });

            await stampDatabaseState(assetStorage, rawStorage, { lastSyncedAt: "2026-01-02T03:04:06.000Z" });

            const state = await loadDatabaseState(rawStorage);
            expect(state?.lastModifiedAt).toBe("2026-01-02T03:04:05.000Z");
            expect(state?.lastSyncedAt).toBe("2026-01-02T03:04:06.000Z");
            expect(state?.contentHash).toBeUndefined();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });
});

describe("stampDatabaseModified", () => {
    test("writes lastModifiedAt and the current content hash", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "stamp-modified-"));
        try {
            const { assetStorage, rawStorage } = await createPopulatedDatabase(tmpDir);

            const before = new Date().toISOString();
            await stampDatabaseModified(assetStorage, rawStorage);
            const after = new Date().toISOString();

            const state = await loadDatabaseState(rawStorage);
            expect(state?.lastModifiedAt).toBeDefined();
            expect(before <= state!.lastModifiedAt!).toBe(true);
            expect(state!.lastModifiedAt! <= after).toBe(true);

            const expectedHash = await getDatabaseContentHash(assetStorage);
            expect(state!.contentHash!.equals(expectedHash!)).toBe(true);
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("writes lastModifiedAt but no content hash when the database is empty", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "stamp-modified-empty-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);

            await stampDatabaseModified(assetStorage, rawStorage);

            const state = await loadDatabaseState(rawStorage);
            expect(state?.lastModifiedAt).toBeDefined();
            expect(state!.contentHash).toBeUndefined();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("preserves other state fields when stamping", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "stamp-modified-merge-"));
        try {
            const { assetStorage, rawStorage } = await createPopulatedDatabase(tmpDir);
            await saveDatabaseState(rawStorage, { lastSyncedAt: "2026-01-02T03:04:05.000Z" });

            await stampDatabaseModified(assetStorage, rawStorage);

            const state = await loadDatabaseState(rawStorage);
            expect(state?.lastSyncedAt).toBe("2026-01-02T03:04:05.000Z");
            expect(state?.lastModifiedAt).toBeDefined();
            expect(state?.contentHash).toBeInstanceOf(Buffer);
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });
});

describe("stampDatabaseStateLocked", () => {
    test("writes the content hash plus the extra fields while holding the lock", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "stamp-locked-"));
        try {
            const { assetStorage, rawStorage } = await createPopulatedDatabase(tmpDir);

            await stampDatabaseStateLocked(assetStorage, rawStorage, "session-1", { lastSyncedAt: "2026-01-02T03:04:05.000Z" });

            const state = await loadDatabaseState(rawStorage);
            expect(state?.lastSyncedAt).toBe("2026-01-02T03:04:05.000Z");
            const expectedHash = await getDatabaseContentHash(assetStorage);
            expect(state!.contentHash!.equals(expectedHash!)).toBe(true);

            // The lock is released afterwards.
            expect(await rawStorage.acquireWriteLock(".db/write.lock", "other")).toBe(true);
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("omits the content hash when the database is empty", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "stamp-locked-empty-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);

            await stampDatabaseStateLocked(assetStorage, rawStorage, "session-1", { lastReplicatedAt: "2026-01-02T03:04:05.000Z" });

            const state = await loadDatabaseState(rawStorage);
            expect(state?.lastReplicatedAt).toBe("2026-01-02T03:04:05.000Z");
            expect(state?.contentHash).toBeUndefined();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("does nothing when the lock is held by another owner", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "stamp-locked-contended-"));
        try {
            const { assetStorage, rawStorage } = await createPopulatedDatabase(tmpDir);
            await rawStorage.acquireWriteLock(".db/write.lock", "other-owner");

            await stampDatabaseStateLocked(assetStorage, rawStorage, "session-1", { lastSyncedAt: "2026-01-02T03:04:05.000Z" });

            expect(await loadDatabaseState(rawStorage)).toBeUndefined();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });
});
