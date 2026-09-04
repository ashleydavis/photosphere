import * as crypto from "crypto";
import * as fsSync from "fs";
import * as path from "path";
import type { ITaskContext } from "task-queue";
import { createTestTempDir } from "node-utils";
import type { IAutoImportSettings, IDatabaseDescriptor } from "api";

jest.mock("../../lib/resolve-storage-credentials", () => ({
    resolveStorageCredentials: jest.fn().mockResolvedValue({
        s3Config: undefined,
        encryptionKeyPems: [],
        googleApiKey: undefined,
    }),
}));

jest.mock("storage", () => ({
    createStorage: jest.fn().mockReturnValue({ storage: {}, rawStorage: {} }),
    loadEncryptionKeysFromPem: jest.fn().mockResolvedValue({ options: {} }),
}));

// The database lookup that decides whether a photo may be deleted. Mocked because the storage above
// is a stub, and because a test needs to see exactly what it was asked.
const mockFindByValue = jest.fn();

jest.mock("bdb", () => ({
    ...jest.requireActual("bdb"),
    BsonDatabase: jest.fn().mockImplementation(() => ({
        collection: () => ({
            sortIndex: () => ({ findByValue: mockFindByValue }),
        }),
    })),
}));

import { cleanupSourcesHandler, ICleanupSourcesData } from "../../lib/cleanup-sources.worker";
import { getHashCacheDir, HashCache } from "../../lib/hash-cache";

describe("cleanupSourcesHandler", () => {

    let tempDir: string;
    let photosDir: string;

    const storageDescriptor: IDatabaseDescriptor = { databasePath: "/test/db" } as IDatabaseDescriptor;

    beforeEach(() => {
        tempDir = createTestTempDir("cleanup-sources-worker");
        photosDir = path.join(tempDir, "photos");
        fsSync.mkdirSync(photosDir, { recursive: true });
        process.env.PHOTOSPHERE_TMP_DIR = tempDir;

        // The hash cache this test writes to and reads back lives in the platform's cache location,
        // so pointing that at the test's own directory is what keeps the test off the developer's
        // real cache and out of the way of any other run on the machine.
        process.env.PHOTOSPHERE_CACHE_DIR = path.join(tempDir, "cache");

        mockFindByValue.mockReset();
        mockFindByValue.mockResolvedValue([]);
    });

    //
    // A task context that never cancels.
    //
    function makeContext(): ITaskContext {
        let uuidCounter = 0;
        return {
            uuidGenerator: { generate: () => `test-uuid-${uuidCounter++}` },
            timestampProvider: { now: () => Date.now(), dateNow: () => new Date() },
            sessionId: "session-1",
            maxConcurrentChildTasks: 10,
            taskId: "cleanup-task",
            sendMessage: () => { /* nothing listening. */ },
            isCancelled: () => false,
        } as ITaskContext;
    }

    //
    // The settings naming the watched folder, which is where the cleanup looks.
    //
    function settings(): IAutoImportSettings {
        return {
            enabled: true,
            sources: [{ type: "folder", path: photosDir, recurse: true }],
        };
    }

    //
    // The task data for one run.
    //
    function makeData(dryRun: boolean): ICleanupSourcesData {
        return { storageDescriptor, settings: settings(), dryRun };
    }

    //
    // Writes a photo into the watched folder.
    //
    function writePhoto(fileName: string, contents: string): string {
        const filePath = path.join(photosDir, fileName);
        fsSync.writeFileSync(filePath, contents);
        return filePath;
    }

    //
    // Records against a file what an earlier import would have: the hash of its contents, filed
    // under the source id a folder source gives it, which is its own path.
    //
    async function seedCacheEntry(filePath: string, contents: string, assetId: string | undefined): Promise<void> {
        const hash = crypto.createHash("sha256").update(contents).digest();
        const fileStat = fsSync.statSync(filePath);

        const hashCache = new HashCache(getHashCacheDir(storageDescriptor.databasePath));
        await hashCache.load();
        hashCache.addSourceHash(filePath, { hash, length: fileStat.size, lastModified: fileStat.mtime });
        if (assetId !== undefined) {
            hashCache.setAssetId(filePath, assetId);
        }
        await hashCache.save();
    }

    test("offers a photo the database holds", async () => {
        const filePath = writePhoto("in-the-database.jpg", "one");
        await seedCacheEntry(filePath, "one", "asset-1");
        mockFindByValue.mockResolvedValue([{ _id: "asset-1" }]);

        const result = await cleanupSourcesHandler(makeData(true), makeContext());

        expect(result.considered).toBe(1);
        expect(result.deletableSourceIds).toEqual([filePath]);
    });

    test("leaves a photo the database does not hold, whatever the cache says", async () => {
        // The cache says this device hashed it and recorded an asset id, but the database is the only
        // thing that counts here: this deletes the user's only copy.
        const filePath = writePhoto("not-in-the-database.jpg", "one");
        await seedCacheEntry(filePath, "one", "asset-that-is-gone");
        mockFindByValue.mockResolvedValue([]);

        const result = await cleanupSourcesHandler(makeData(true), makeContext());

        expect(result.deletableSourceIds).toEqual([]);
    });

    test("asks the database even when an asset id is recorded", async () => {
        const filePath = writePhoto("in-the-database.jpg", "one");
        await seedCacheEntry(filePath, "one", "asset-1");
        mockFindByValue.mockResolvedValue([{ _id: "asset-1" }]);

        await cleanupSourcesHandler(makeData(true), makeContext());

        expect(mockFindByValue).toHaveBeenCalledTimes(1);
    });

    test("leaves a photo this device has never hashed", async () => {
        // A photo imported on another device and synced in. This device has no entry for it, and
        // finding out would mean hashing the whole library, which is the cost this all exists to
        // avoid. So it stays.
        writePhoto("from-another-device.jpg", "one");

        const result = await cleanupSourcesHandler(makeData(true), makeContext());

        expect(result.considered).toBe(1);
        expect(result.deletableSourceIds).toEqual([]);
        expect(mockFindByValue).not.toHaveBeenCalled();
    });

    test("leaves a photo whose cache entry no longer describes it", async () => {
        // A photo library may hand a deleted item's id to a new one, and deleting the wrong photo is
        // not recoverable.
        const filePath = writePhoto("changed.jpg", "one");
        await seedCacheEntry(filePath, "one", "asset-1");
        fsSync.writeFileSync(filePath, "a completely different photo");
        mockFindByValue.mockResolvedValue([{ _id: "asset-1" }]);

        const result = await cleanupSourcesHandler(makeData(true), makeContext());

        expect(result.deletableSourceIds).toEqual([]);
    });

    test("a counting pass deletes nothing", async () => {
        const filePath = writePhoto("in-the-database.jpg", "one");
        await seedCacheEntry(filePath, "one", "asset-1");
        mockFindByValue.mockResolvedValue([{ _id: "asset-1" }]);

        const result = await cleanupSourcesHandler(makeData(true), makeContext());

        expect(result.deletedSourceIds).toEqual([]);
        expect(fsSync.existsSync(filePath)).toBe(true);
    });

    test("a deleting pass deletes what it offered", async () => {
        const filePath = writePhoto("in-the-database.jpg", "one");
        await seedCacheEntry(filePath, "one", "asset-1");
        mockFindByValue.mockResolvedValue([{ _id: "asset-1" }]);

        const result = await cleanupSourcesHandler(makeData(false), makeContext());

        expect(result.deletedSourceIds).toEqual([filePath]);
        expect(fsSync.existsSync(filePath)).toBe(false);
    });

    test("a deleting pass leaves the photos it did not offer", async () => {
        const keptPath = writePhoto("not-in-the-database.jpg", "two");
        const deletedPath = writePhoto("in-the-database.jpg", "one");
        await seedCacheEntry(deletedPath, "one", "asset-1");
        mockFindByValue.mockResolvedValue([{ _id: "asset-1" }]);

        await cleanupSourcesHandler(makeData(false), makeContext());

        expect(fsSync.existsSync(keptPath)).toBe(true);
        expect(fsSync.existsSync(deletedPath)).toBe(false);
    });

    test("refuses to run with no sources configured, rather than looking nowhere and reporting success", async () => {
        const data: ICleanupSourcesData = { storageDescriptor, settings: { ...settings(), sources: [] }, dryRun: true };

        await expect(cleanupSourcesHandler(data, makeContext())).rejects.toThrow(/no sources configured/i);
    });
});
