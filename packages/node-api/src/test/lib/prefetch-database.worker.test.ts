import type { ITaskContext } from "task-queue";
import type { IPrefetchDatabaseData } from "../../lib/prefetch-database.worker";

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

jest.mock("../../lib/tree", () => ({
    loadMerkleTree: jest.fn(),
}));

jest.mock("api", () => ({
    loadDatabaseConfig: jest.fn(),
}));

jest.mock("storage", () => ({
    walkDirectory: jest.fn(),
}));

import { openStorage } from "../../lib/open-storage";
import { loadMerkleTree } from "../../lib/tree";
import { loadDatabaseConfig } from "api";
import { walkDirectory } from "storage";
import { prefetchDatabaseHandler } from "../../lib/prefetch-database.worker";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;
const mockLoadMerkleTree = loadMerkleTree as jest.MockedFunction<typeof loadMerkleTree>;
const mockLoadDatabaseConfig = loadDatabaseConfig as jest.MockedFunction<typeof loadDatabaseConfig>;
const mockWalkDirectory = walkDirectory as jest.MockedFunction<typeof walkDirectory>;

//
// Builds a minimal ITaskContext for testing.
//
function makeContext(isCancelled: boolean): ITaskContext {
    return {
        uuidGenerator: { generate: jest.fn().mockReturnValue("test-uuid") },
        timestampProvider: { now: jest.fn().mockReturnValue(Date.now()), dateNow: jest.fn().mockReturnValue(new Date()) },
        sessionId: "session-1",
        sendMessage: jest.fn(),
        isCancelled: jest.fn().mockReturnValue(isCancelled),
        taskId: "prefetch-task-id",
    };
}

//
// A fake local storage that records fileExists lookups and writeStream copies.
//
interface IFakeLocalStorage {
    // Set of file names the local replica reports as already present.
    present: Set<string>;

    // Jest mock recording (fileName) -> Promise<boolean> presence checks.
    fileExists: jest.Mock;

    // Jest mock recording writeStream copies into the local replica.
    writeStream: jest.Mock;
}

//
// A fake origin storage that hands back a stream for each requested file.
//
interface IFakeOriginStorage {
    // Jest mock recording readStream reads from origin.
    readStream: jest.Mock;
}

//
// Builds a fake local storage whose replica already contains `present` files.
//
function makeLocalStorage(present: string[]): IFakeLocalStorage {
    const presentSet = new Set(present);
    return {
        present: presentSet,
        fileExists: jest.fn().mockImplementation(async (fileName: string) => presentSet.has(fileName)),
        writeStream: jest.fn().mockResolvedValue(undefined),
    };
}

//
// Builds a fake origin storage that returns a placeholder stream per file.
//
function makeOriginStorage(): IFakeOriginStorage {
    return {
        readStream: jest.fn().mockImplementation(async (fileName: string) => ({ __stream: fileName })),
    };
}

//
// Yields the given file names as walkDirectory entries.
//
async function* fakeWalk(fileNames: string[]): AsyncGenerator<{ fileName: string }> {
    for (const fileName of fileNames) {
        yield { fileName };
    }
}

describe("prefetchDatabaseHandler", () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test("throws when databasePath is empty", async () => {
        const data: IPrefetchDatabaseData = { databasePath: "" };

        await expect(prefetchDatabaseHandler(data, makeContext(false))).rejects.toThrow("databasePath is required");
        expect(mockOpenStorage).not.toHaveBeenCalled();
    });

    test("returns without copying for a full (non-partial) database", async () => {
        const localStorage = makeLocalStorage([]);
        mockOpenStorage.mockResolvedValueOnce({
            storage: localStorage as any,
            rawStorage: { __label: "raw" } as any,
            encryptionKeyPems: [],
            s3Config: undefined,
            storageOptions: {} as any,
            googleApiKey: undefined,
        });
        mockLoadMerkleTree.mockResolvedValue({ databaseMetadata: { isPartial: false } } as any);

        await prefetchDatabaseHandler({ databasePath: "/fake/db" }, makeContext(false));

        expect(mockLoadDatabaseConfig).not.toHaveBeenCalled();
        expect(mockWalkDirectory).not.toHaveBeenCalled();
        expect(localStorage.writeStream).not.toHaveBeenCalled();
    });

    test("returns without copying when the partial database has no origin configured", async () => {
        const localStorage = makeLocalStorage([]);
        mockOpenStorage.mockResolvedValueOnce({
            storage: localStorage as any,
            rawStorage: { __label: "raw" } as any,
            encryptionKeyPems: [],
            s3Config: undefined,
            storageOptions: {} as any,
            googleApiKey: undefined,
        });
        mockLoadMerkleTree.mockResolvedValue({ databaseMetadata: { isPartial: true } } as any);
        mockLoadDatabaseConfig.mockResolvedValue({ origin: undefined } as any);

        await prefetchDatabaseHandler({ databasePath: "/fake/db" }, makeContext(false));

        expect(mockWalkDirectory).not.toHaveBeenCalled();
        expect(localStorage.writeStream).not.toHaveBeenCalled();
    });

    test("copies files missing from the partial replica out of origin storage", async () => {
        const localStorage = makeLocalStorage([]);
        const originStorage = makeOriginStorage();
        mockOpenStorage
            .mockResolvedValueOnce({
                storage: localStorage as any,
                rawStorage: { __label: "local-raw" } as any,
                encryptionKeyPems: [],
                s3Config: undefined,
                storageOptions: {} as any,
                googleApiKey: undefined,
            })
            .mockResolvedValueOnce({
                storage: originStorage as any,
                rawStorage: { __label: "origin-raw" } as any,
                encryptionKeyPems: [],
                s3Config: undefined,
                storageOptions: {} as any,
                googleApiKey: undefined,
            });
        mockLoadMerkleTree.mockResolvedValue({ databaseMetadata: { isPartial: true } } as any);
        mockLoadDatabaseConfig.mockResolvedValue({ origin: "/fake/origin" } as any);

        // thumb/ yields one file, .db/bson yields another; both are missing locally.
        mockWalkDirectory.mockImplementation((_storage: any, dir: string) => {
            if (dir === "thumb") {
                return fakeWalk(["thumb/a"]) as any;
            }
            return fakeWalk([".db/bson/collection"]) as any;
        });

        await prefetchDatabaseHandler({ databasePath: "/fake/db" }, makeContext(false));

        expect(mockOpenStorage).toHaveBeenCalledWith("/fake/origin");
        expect(originStorage.readStream).toHaveBeenCalledWith("thumb/a");
        expect(originStorage.readStream).toHaveBeenCalledWith(".db/bson/collection");
        expect(localStorage.writeStream).toHaveBeenCalledTimes(2);
        expect(localStorage.writeStream).toHaveBeenCalledWith("thumb/a", undefined, { __stream: "thumb/a" });
        expect(localStorage.writeStream).toHaveBeenCalledWith(".db/bson/collection", undefined, { __stream: ".db/bson/collection" });
    });

    test("skips files that already exist in the local replica", async () => {
        const localStorage = makeLocalStorage(["thumb/a"]);
        const originStorage = makeOriginStorage();
        mockOpenStorage
            .mockResolvedValueOnce({
                storage: localStorage as any,
                rawStorage: { __label: "local-raw" } as any,
                encryptionKeyPems: [],
                s3Config: undefined,
                storageOptions: {} as any,
                googleApiKey: undefined,
            })
            .mockResolvedValueOnce({
                storage: originStorage as any,
                rawStorage: { __label: "origin-raw" } as any,
                encryptionKeyPems: [],
                s3Config: undefined,
                storageOptions: {} as any,
                googleApiKey: undefined,
            });
        mockLoadMerkleTree.mockResolvedValue({ databaseMetadata: { isPartial: true } } as any);
        mockLoadDatabaseConfig.mockResolvedValue({ origin: "/fake/origin" } as any);
        mockWalkDirectory.mockImplementation((_storage: any, dir: string) => {
            if (dir === "thumb") {
                return fakeWalk(["thumb/a"]) as any;
            }
            return fakeWalk([]) as any;
        });

        await prefetchDatabaseHandler({ databasePath: "/fake/db" }, makeContext(false));

        expect(originStorage.readStream).not.toHaveBeenCalled();
        expect(localStorage.writeStream).not.toHaveBeenCalled();
    });

    test("stops copying when the task is cancelled", async () => {
        const localStorage = makeLocalStorage([]);
        const originStorage = makeOriginStorage();
        mockOpenStorage
            .mockResolvedValueOnce({
                storage: localStorage as any,
                rawStorage: { __label: "local-raw" } as any,
                encryptionKeyPems: [],
                s3Config: undefined,
                storageOptions: {} as any,
                googleApiKey: undefined,
            })
            .mockResolvedValueOnce({
                storage: originStorage as any,
                rawStorage: { __label: "origin-raw" } as any,
                encryptionKeyPems: [],
                s3Config: undefined,
                storageOptions: {} as any,
                googleApiKey: undefined,
            });
        mockLoadMerkleTree.mockResolvedValue({ databaseMetadata: { isPartial: true } } as any);
        mockLoadDatabaseConfig.mockResolvedValue({ origin: "/fake/origin" } as any);
        mockWalkDirectory.mockImplementation((_storage: any, dir: string) => {
            if (dir === "thumb") {
                return fakeWalk(["thumb/a"]) as any;
            }
            return fakeWalk([]) as any;
        });

        // Cancelled before any batch runs, so nothing is copied.
        await prefetchDatabaseHandler({ databasePath: "/fake/db" }, makeContext(true));

        expect(localStorage.writeStream).not.toHaveBeenCalled();
    });
});
