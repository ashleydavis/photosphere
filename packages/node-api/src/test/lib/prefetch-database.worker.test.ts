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
    // The real value, because the handler passes it to retry as the timeout for one file's copy and
    // the test below is about that timeout. Left out of the mock it arrives as undefined, retry falls
    // back to its 30 second default, and the test measures the default while appearing to measure
    // the long one.
    LARGE_FILE_TIMEOUT: 90 * 60 * 1_000,
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
        maxConcurrentChildTasks: 10,
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

    test("copies a file that takes longer than the default retry timeout to read", async () => {
        // How long the one file takes to come out of the origin, in fake milliseconds. Comfortably
        // over retry's 30 second default and far under the long timeout a file copy is meant to get,
        // so it separates the two: with the default the copy is abandoned, with the long one it
        // finishes. The metadata hash index of a real database is nine files of about 13 MB each, and
        // a phone cannot pull one of those down and write it inside thirty seconds.
        const readDelayMs = 45_000;

        jest.useFakeTimers();

        try {
            const localStorage = makeLocalStorage([]);
            const originStorage = makeOriginStorage();

            // The origin hands the file over slowly. Wrapped on the fake rather than replaced so
            // everything else about it is untouched.
            const readStreamNormally = originStorage.readStream;
            originStorage.readStream = jest.fn().mockImplementation(async (fileName: string) => {
                await new Promise<void>(resolve => setTimeout(resolve, readDelayMs));
                return readStreamNormally(fileName);
            });

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
                    return fakeWalk([]) as any;
                }
                return fakeWalk([".db/bson/collections/metadata/shards/1"]) as any;
            });

            const prefetch = prefetchDatabaseHandler({ databasePath: "/fake/db" }, makeContext(false));

            // Time is pushed past the read in steps, so each delay resolves before the next is
            // scheduled. More steps than reads, because a retry that has given up schedules its
            // wait before the next attempt.
            for (let step = 0; step < 4; step++) {
                await jest.advanceTimersByTimeAsync(readDelayMs);
            }

            await prefetch;

            expect(localStorage.writeStream).toHaveBeenCalledTimes(1);
            expect(localStorage.writeStream).toHaveBeenCalledWith(".db/bson/collections/metadata/shards/1", undefined, { __stream: ".db/bson/collections/metadata/shards/1" });
        }
        finally {
            jest.useRealTimers();
        }
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
