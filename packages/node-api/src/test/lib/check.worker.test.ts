import type { ITaskContext } from "task-queue";
import type { ICheckFileData } from "../../lib/check.worker";

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

jest.mock("../../lib/hash", () => ({
    getHashFromCache: jest.fn(),
    validateAndHash: jest.fn(),
}));

jest.mock("../../lib/hash-cache", () => ({
    HashCache: jest.fn().mockImplementation(() => ({
        load: jest.fn().mockResolvedValue(undefined),
    })),
}));

jest.mock("../../lib/media-file-database", () => ({
    createMediaFileDatabase: jest.fn(),
}));

import { openStorage } from "../../lib/open-storage";
import { getHashFromCache, validateAndHash } from "../../lib/hash";
import { createMediaFileDatabase } from "../../lib/media-file-database";
import { checkFileHandler } from "../../lib/check.worker";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;
const mockGetHashFromCache = getHashFromCache as jest.MockedFunction<typeof getHashFromCache>;
const mockValidateAndHash = validateAndHash as jest.MockedFunction<typeof validateAndHash>;
const mockCreateMediaFileDatabase = createMediaFileDatabase as jest.MockedFunction<typeof createMediaFileDatabase>;

//
// Builds a minimal ITaskContext for testing.
//
function makeContext(): ITaskContext {
    return {
        uuidGenerator: { generate: jest.fn().mockReturnValue("test-uuid") },
        timestampProvider: { now: jest.fn().mockReturnValue(Date.now()), dateNow: jest.fn().mockReturnValue(new Date()) },
        sessionId: "session-1",
        sendMessage: jest.fn(),
        isCancelled: jest.fn().mockReturnValue(false),
        taskId: "check-task-id",
    };
}

//
// Builds check-file input for a file at the given path.
//
function makeData(): ICheckFileData {
    return {
        filePath: "/tmp/asset.jpg",
        fileStat: { length: 100, lastModified: new Date("2023-01-01T00:00:00.000Z") } as any,
        contentType: "image/jpeg",
        storageDescriptor: { databasePath: "/fake/db", encryptionKey: undefined } as any,
        hashCacheDir: "/tmp/hash-cache",
        logicalPath: "/tmp/asset.jpg",
    };
}

//
// A hashed-file result as produced by the cache or by validateAndHash.
//
const HASHED_FILE = {
    hash: Buffer.from("abcd", "hex"),
    lastModified: new Date("2023-01-01T00:00:00.000Z"),
    length: 100,
};

//
// Points createMediaFileDatabase at a metadata collection whose hash index returns `records`.
//
function mockDatabaseWithMatches(records: unknown[]): void {
    mockOpenStorage.mockResolvedValue({
        storage: { __label: "db-storage" } as any,
        rawStorage: {} as any,
        encryptionKeyPems: [],
        s3Config: undefined,
        storageOptions: {} as any,
        googleApiKey: undefined,
    });
    mockCreateMediaFileDatabase.mockReturnValue({
        metadataCollection: {
            sortIndex: jest.fn().mockReturnValue({
                findByValue: jest.fn().mockResolvedValue(records),
            }),
        },
    } as any);
}

describe("checkFileHandler", () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test("uses the cached hash and counts matching database records", async () => {
        mockGetHashFromCache.mockResolvedValue(HASHED_FILE as any);
        mockDatabaseWithMatches([{ _id: "1" }, { _id: "2" }]);

        const result = await checkFileHandler(makeData(), makeContext());

        expect(result.hashFromCache).toBe(true);
        expect(result.matchingRecordsCount).toBe(2);
        expect(result.hashedFile).toEqual({
            hash: "abcd",
            lastModified: "2023-01-01T00:00:00.000Z",
            length: 100,
        });
        // A cache hit means the file is not re-hashed.
        expect(mockValidateAndHash).not.toHaveBeenCalled();
    });

    test("computes the hash on a cache miss and reports hashFromCache false", async () => {
        mockGetHashFromCache.mockResolvedValue(undefined);
        mockValidateAndHash.mockResolvedValue(HASHED_FILE as any);
        mockDatabaseWithMatches([]);

        const result = await checkFileHandler(makeData(), makeContext());

        expect(mockValidateAndHash).toHaveBeenCalledTimes(1);
        expect(result.hashFromCache).toBe(false);
        expect(result.matchingRecordsCount).toBe(0);
        expect(result.hashedFile?.hash).toBe("abcd");
    });

    test("returns an empty result without opening storage when the file cannot be hashed", async () => {
        mockGetHashFromCache.mockResolvedValue(undefined);
        mockValidateAndHash.mockResolvedValue(undefined);

        const result = await checkFileHandler(makeData(), makeContext());

        expect(result).toEqual({ hashedFile: undefined, matchingRecordsCount: 0, hashFromCache: false });
        expect(mockOpenStorage).not.toHaveBeenCalled();
    });
});
