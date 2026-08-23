import type { ITaskContext } from "task-queue";
import { addItem, createTree, IMerkleTree } from "merkle-tree";

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

jest.mock("../../lib/tree", () => ({
    loadMerkleTree: jest.fn(),
    saveMerkleTree: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("api", () => ({
    ...jest.requireActual("api"),
    loadDatabaseConfig: jest.fn(),
}));

import { loadDatabaseConfig } from "api";
import { openStorage } from "../../lib/open-storage";
import { loadMerkleTree, saveMerkleTree } from "../../lib/tree";
import { evictOriginalsHandler, IEvictOriginalsData } from "../../lib/evict-originals.worker";
import { IDatabaseMetadata } from "../../lib/media-file-database";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;
const mockLoadMerkleTree = loadMerkleTree as jest.MockedFunction<typeof loadMerkleTree>;
const mockSaveMerkleTree = saveMerkleTree as jest.MockedFunction<typeof saveMerkleTree>;
const mockLoadDatabaseConfig = loadDatabaseConfig as jest.MockedFunction<typeof loadDatabaseConfig>;

//
// One file to put in a database's merkle tree.
//
interface ITreeFile {
    // The path in the database, such as "asset/one".
    name: string;

    // The content hash, as hex.
    hash: string;

    // The size in bytes.
    size: number;

    // How many days ago the file was last modified, which is what stands in for import time.
    daysAgo: number;
}

//
// A merkle tree holding the given files.
//
function treeOf(files: ITreeFile[], metadata: IDatabaseMetadata): IMerkleTree<IDatabaseMetadata> {
    let tree = createTree<IDatabaseMetadata>("test-tree");
    for (const file of files) {
        tree = addItem(tree, {
            name: file.name,
            hash: Buffer.from(file.hash, "hex"),
            length: file.size,
            lastModified: new Date(Date.now() - (file.daysAgo * 24 * 60 * 60 * 1000)),
        });
    }
    tree.databaseMetadata = metadata;
    return tree;
}

//
// A storage that reports every named file as present and records what was deleted.
//
class FakeStorage {
    // Files the storage holds.
    readonly present: Set<string>;

    // Files that were deleted, in order.
    readonly deleted: string[] = [];

    constructor(present: string[]) {
        this.present = new Set(present);
    }

    async fileExists(filePath: string): Promise<boolean> {
        return this.present.has(filePath);
    }

    async deleteFile(filePath: string): Promise<void> {
        this.present.delete(filePath);
        this.deleted.push(filePath);
    }
}

describe("evictOriginalsHandler", () => {

    let localStorage: FakeStorage;

    const data: IEvictOriginalsData = { databasePath: "/local/db", sessionId: "session-1" };

    //
    // A task context that is never cancelled.
    //
    function makeContext(): ITaskContext {
        return {
            uuidGenerator: { generate: () => "test-uuid" },
            timestampProvider: { now: () => Date.now(), dateNow: () => new Date() },
            sessionId: "session-1",
            maxConcurrentChildTasks: 10,
            sendMessage: jest.fn(),
            isCancelled: () => false,
            taskId: "evict-task",
        } as ITaskContext;
    }

    //
    // Points the handler at a local database and its origin.
    //
    function setUpDatabases(localFiles: ITreeFile[], originFiles: ITreeFile[], localMetadata: IDatabaseMetadata): void {
        localStorage = new FakeStorage(localFiles.map(file => file.name));
        const originStorage = new FakeStorage(originFiles.map(file => file.name));

        mockOpenStorage.mockImplementation(async (databasePath: string) => {
            if (databasePath === "/local/db") {
                return { storage: localStorage, rawStorage: localStorage } as any;
            }
            return { storage: originStorage, rawStorage: originStorage } as any;
        });

        const localTree = treeOf(localFiles, localMetadata);
        const originTree = treeOf(originFiles, { filesImported: originFiles.length });

        mockLoadMerkleTree.mockImplementation(async (storage: any) => {
            return storage === localStorage ? localTree as any : originTree as any;
        });
    }

    beforeEach(() => {
        jest.clearAllMocks();
        mockLoadDatabaseConfig.mockResolvedValue({ origin: "/origin/db" });
        mockSaveMerkleTree.mockResolvedValue(undefined);
    });

    //
    // A huge original, so the two gigabyte size budget always wants it gone.
    //
    function hugeOriginal(assetId: string, hash: string, daysAgo: number): ITreeFile {
        return { name: `asset/${assetId}`, hash, size: 3 * 1024 * 1024 * 1024, daysAgo };
    }

    test("evicts nothing when there is no origin", async () => {
        mockLoadDatabaseConfig.mockResolvedValue({});
        setUpDatabases([hugeOriginal("one", "aaaa", 10)], [], { filesImported: 1 });

        const result = await evictOriginalsHandler(data, makeContext());

        expect(result.evictedAssetIds).toEqual([]);
        expect(result.skippedReason).toBe("no origin configured");
        expect(localStorage.deleted).toEqual([]);
    });

    test("evicts nothing when the origin cannot be read", async () => {
        setUpDatabases([hugeOriginal("one", "aaaa", 10)], [], { filesImported: 1 });
        mockLoadMerkleTree.mockImplementation(async (storage: any) => {
            return storage === localStorage ? treeOf([hugeOriginal("one", "aaaa", 10)], { filesImported: 1 }) as any : undefined;
        });

        const result = await evictOriginalsHandler(data, makeContext());

        expect(result.evictedAssetIds).toEqual([]);
        expect(result.skippedReason).toMatch(/origin not accessible/);
    });

    test("evicts an original the origin holds with a matching hash", async () => {
        setUpDatabases(
            [hugeOriginal("one", "aaaa", 10)],
            [hugeOriginal("one", "aaaa", 10)],
            { filesImported: 1 }
        );

        const result = await evictOriginalsHandler(data, makeContext());

        expect(result.evictedAssetIds).toEqual(["one"]);
        expect(localStorage.deleted).toEqual(["asset/one"]);
        expect(result.freedBytes).toBe(3 * 1024 * 1024 * 1024);
    });

    test("never evicts an original the origin does not hold", async () => {
        setUpDatabases([hugeOriginal("one", "aaaa", 10)], [], { filesImported: 1 });
        mockLoadMerkleTree.mockImplementation(async (storage: any) => {
            const localTree = treeOf([hugeOriginal("one", "aaaa", 10)], { filesImported: 1 });
            const originTree = treeOf([], { filesImported: 0 });
            return (storage === localStorage ? localTree : originTree) as any;
        });

        const result = await evictOriginalsHandler(data, makeContext());

        expect(result.evictedAssetIds).toEqual([]);
        expect(localStorage.deleted).toEqual([]);
    });

    test("never evicts an original whose hash on the origin is different", async () => {
        setUpDatabases(
            [hugeOriginal("one", "aaaa", 10)],
            [hugeOriginal("one", "bbbb", 10)],
            { filesImported: 1 }
        );

        const result = await evictOriginalsHandler(data, makeContext());

        expect(result.evictedAssetIds).toEqual([]);
        expect(localStorage.deleted).toEqual([]);
    });

    test("leaves the thumbnail and the micro thumbnail in place", async () => {
        const localFiles: ITreeFile[] = [
            hugeOriginal("one", "aaaa", 10),
            { name: "display/one", hash: "dddd", size: 1000, daysAgo: 10 },
            { name: "thumb/one", hash: "tttt", size: 100, daysAgo: 10 },
            { name: "micro/one", hash: "mmmm", size: 10, daysAgo: 10 },
        ];
        setUpDatabases(localFiles, localFiles, { filesImported: 1 });

        await evictOriginalsHandler(data, makeContext());

        expect(localStorage.deleted.sort()).toEqual(["asset/one", "display/one"]);
        expect(localStorage.present.has("thumb/one")).toBe(true);
        expect(localStorage.present.has("micro/one")).toBe(true);
    });

    test("keeps the display copy when the origin does not hold a matching one", async () => {
        const localFiles: ITreeFile[] = [
            hugeOriginal("one", "aaaa", 10),
            { name: "display/one", hash: "dddd", size: 1000, daysAgo: 10 },
        ];
        const originFiles: ITreeFile[] = [
            hugeOriginal("one", "aaaa", 10),
            { name: "display/one", hash: "eeee", size: 1000, daysAgo: 10 },
        ];
        setUpDatabases(localFiles, originFiles, { filesImported: 1 });

        await evictOriginalsHandler(data, makeContext());

        expect(localStorage.deleted).toEqual(["asset/one"]);
        expect(localStorage.present.has("display/one")).toBe(true);
    });

    test("marks the database partial once something has been evicted", async () => {
        setUpDatabases(
            [hugeOriginal("one", "aaaa", 10)],
            [hugeOriginal("one", "aaaa", 10)],
            { filesImported: 1 }
        );

        await evictOriginalsHandler(data, makeContext());

        expect(mockSaveMerkleTree).toHaveBeenCalled();
        const savedTree = mockSaveMerkleTree.mock.calls[0][0] as IMerkleTree<IDatabaseMetadata>;
        expect(savedTree.databaseMetadata!.isPartial).toBe(true);
        expect(savedTree.databaseMetadata!.filesImported).toBe(1);
    });

    test("does not rewrite the tree when nothing was evicted", async () => {
        setUpDatabases([hugeOriginal("one", "aaaa", 10)], [], { filesImported: 1 });
        mockLoadMerkleTree.mockImplementation(async (storage: any) => {
            const localTree = treeOf([hugeOriginal("one", "aaaa", 10)], { filesImported: 1 });
            const originTree = treeOf([], { filesImported: 0 });
            return (storage === localStorage ? localTree : originTree) as any;
        });

        await evictOriginalsHandler(data, makeContext());

        expect(mockSaveMerkleTree).not.toHaveBeenCalled();
    });

    test("does not rewrite the tree when the database is already partial", async () => {
        setUpDatabases(
            [hugeOriginal("one", "aaaa", 10)],
            [hugeOriginal("one", "aaaa", 10)],
            { filesImported: 1, isPartial: true }
        );

        const result = await evictOriginalsHandler(data, makeContext());

        expect(result.evictedAssetIds).toEqual(["one"]);
        expect(mockSaveMerkleTree).not.toHaveBeenCalled();
    });

    test("evicts the oldest first and stops once the budget is met", async () => {
        // Three originals of one gigabyte each, against a two gigabyte budget: one has to go, and it
        // is the oldest.
        const gigabyte = 1024 * 1024 * 1024;
        const localFiles: ITreeFile[] = [
            { name: "asset/newest", hash: "1111", size: gigabyte, daysAgo: 1 },
            { name: "asset/oldest", hash: "2222", size: gigabyte, daysAgo: 100 },
            { name: "asset/middle", hash: "3333", size: gigabyte, daysAgo: 50 },
        ];
        setUpDatabases(localFiles, localFiles, { filesImported: 3 });

        const result = await evictOriginalsHandler(data, makeContext());

        expect(result.evictedAssetIds).toEqual(["oldest"]);
    });

    test("evicts nothing when the originals are already under the budget", async () => {
        const localFiles: ITreeFile[] = [
            { name: "asset/one", hash: "1111", size: 1000, daysAgo: 100 },
        ];
        setUpDatabases(localFiles, localFiles, { filesImported: 1 });

        const result = await evictOriginalsHandler(data, makeContext());

        expect(result.evictedAssetIds).toEqual([]);
        expect(localStorage.deleted).toEqual([]);
    });

    test("an original already gone from disk frees nothing and is not an error", async () => {
        setUpDatabases(
            [hugeOriginal("one", "aaaa", 10)],
            [hugeOriginal("one", "aaaa", 10)],
            { filesImported: 1 }
        );
        localStorage.present.delete("asset/one");

        const result = await evictOriginalsHandler(data, makeContext());

        expect(result.evictedAssetIds).toEqual(["one"]);
        expect(result.freedBytes).toBe(0);
    });

    test("a budget given in the task data is used instead of the active policy", async () => {
        // Small originals that the active two gigabyte policy would never touch.
        const localFiles: ITreeFile[] = [
            { name: "asset/one", hash: "1111", size: 1000, daysAgo: 100 },
            { name: "asset/two", hash: "2222", size: 1000, daysAgo: 1 },
        ];
        setUpDatabases(localFiles, localFiles, { filesImported: 2 });

        const result = await evictOriginalsHandler({ ...data, localOriginalBudgetBytes: 1000 }, makeContext());

        expect(result.evictedAssetIds).toEqual(["one"]);
    });

    test("a budget of zero drops every confirmed original", async () => {
        const localFiles: ITreeFile[] = [
            { name: "asset/one", hash: "1111", size: 1000, daysAgo: 100 },
            { name: "asset/two", hash: "2222", size: 1000, daysAgo: 1 },
        ];
        setUpDatabases(localFiles, localFiles, { filesImported: 2 });

        const result = await evictOriginalsHandler({ ...data, localOriginalBudgetBytes: 0 }, makeContext());

        expect(result.evictedAssetIds).toEqual(["one", "two"]);
    });

    test("a budget does not override the rule about the origin", async () => {
        const localFiles: ITreeFile[] = [{ name: "asset/one", hash: "1111", size: 1000, daysAgo: 100 }];
        setUpDatabases(localFiles, [], { filesImported: 1 });
        mockLoadMerkleTree.mockImplementation(async (storage: any) => {
            const localTree = treeOf(localFiles, { filesImported: 1 });
            const originTree = treeOf([], { filesImported: 0 });
            return (storage === localStorage ? localTree : originTree) as any;
        });

        const result = await evictOriginalsHandler({ ...data, localOriginalBudgetBytes: 0 }, makeContext());

        expect(result.evictedAssetIds).toEqual([]);
    });

    test("refuses a database path that is not given", async () => {
        await expect(evictOriginalsHandler({ databasePath: "", sessionId: "s" }, makeContext()))
            .rejects.toThrow(/databasePath is required/);
    });
});
