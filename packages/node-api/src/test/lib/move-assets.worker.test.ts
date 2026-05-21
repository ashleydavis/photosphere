import type { ITaskContext } from "task-queue";
import type { IMoveAssetsData } from "../../lib/move-assets.worker";

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

jest.mock("../../lib/media-file-database", () => ({
    createMediaFileDatabase: jest.fn(),
    loadSortIndexes: jest.fn().mockResolvedValue(undefined),
    streamAsset: jest.fn(),
    writeAssetStreamVerified: jest.fn().mockResolvedValue(undefined),
    removeAsset: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("utils", () => ({
    log: { verbose: jest.fn(), error: jest.fn(), exception: jest.fn(), info: jest.fn() },
    retry: jest.fn((fn: () => any) => fn()),
}));

import { openStorage } from "../../lib/open-storage";
import {
    createMediaFileDatabase,
    loadSortIndexes,
    streamAsset,
    writeAssetStreamVerified,
    removeAsset,
} from "../../lib/media-file-database";
import { moveAssetsHandler } from "../../lib/move-assets.worker";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;
const mockCreateMediaFileDatabase = createMediaFileDatabase as jest.MockedFunction<typeof createMediaFileDatabase>;
const mockLoadSortIndexes = loadSortIndexes as jest.MockedFunction<typeof loadSortIndexes>;
const mockStreamAsset = streamAsset as jest.MockedFunction<typeof streamAsset>;
const mockWriteAssetStreamVerified = writeAssetStreamVerified as jest.MockedFunction<typeof writeAssetStreamVerified>;
const mockRemoveAsset = removeAsset as jest.MockedFunction<typeof removeAsset>;

//
// Builds a minimal ITaskContext for testing.
//
function makeContext(overrides: Partial<ITaskContext> = {}): ITaskContext {
    return {
        uuidGenerator: { generate: jest.fn().mockReturnValue("new-asset-id") },
        timestampProvider: { now: jest.fn().mockReturnValue(Date.now()), dateNow: jest.fn().mockReturnValue(new Date()) },
        sessionId: "test-session",
        sendMessage: jest.fn(),
        isCancelled: jest.fn().mockReturnValue(false),
        taskId: "move-task-id",
        ...overrides,
    };
}

//
// Builds a minimal IMoveAssetsData for testing.
//
function makeData(overrides: Partial<IMoveAssetsData> = {}): IMoveAssetsData {
    return {
        sourceDatabasePath: "/fake/source",
        destDatabasePath: "/fake/dest",
        assetIds: ["asset-1"],
        ...overrides,
    };
}

//
// Returns a mock storage pair for a given path label.
//
function makeStoragePair(label: string) {
    return {
        storage: { __label: `${label}-storage`, fileExists: jest.fn(), info: jest.fn() } as any,
        rawStorage: { __label: `${label}-raw` } as any,
        encryptionKeyPems: [],
        s3Config: undefined,
        storageOptions: {} as any,
        googleApiKey: undefined,
    };
}

//
// Returns a mock database object with a metadata collection and bsonDatabase.
//
function makeDatabase(metadata: Record<string, any>) {
    const mockCollection = {
        getOne: jest.fn((id: string) => Promise.resolve(metadata[id] ?? null)),
        updateOne: jest.fn().mockResolvedValue(undefined),
    };
    const mockBsonDatabase = {
        commit: jest.fn().mockResolvedValue(undefined),
    };
    return {
        metadataCollection: mockCollection,
        bsonDatabase: mockBsonDatabase,
    };
}

describe("moveAssetsHandler", () => {
    let sourceStorage: ReturnType<typeof makeStoragePair>;
    let destStorage: ReturnType<typeof makeStoragePair>;
    let sourceDb: ReturnType<typeof makeDatabase>;
    let destDb: ReturnType<typeof makeDatabase>;

    beforeEach(() => {
        jest.clearAllMocks();

        sourceStorage = makeStoragePair("source");
        destStorage = makeStoragePair("dest");
        sourceDb = makeDatabase({ "asset-1": { _id: "asset-1", hash: "abc123", photoDate: "2024-01-01" } });
        destDb = makeDatabase({});

        mockOpenStorage.mockImplementation(async (path: string) => {
            if (path === "/fake/source") {
                return sourceStorage;
            }
            return destStorage;
        });

        mockCreateMediaFileDatabase.mockImplementation((_storage: any) => {
            if (_storage === sourceStorage.storage) {
                return sourceDb as any;
            }
            return destDb as any;
        });

        (sourceStorage.storage.fileExists as jest.Mock).mockResolvedValue(false);
        (sourceStorage.storage.info as jest.Mock).mockResolvedValue(undefined);
        mockStreamAsset.mockResolvedValue({} as any);
    });

    test("opens source storage with sourceDatabasePath", async () => {
        await moveAssetsHandler(makeData(), makeContext());

        expect(mockOpenStorage).toHaveBeenCalledWith("/fake/source");
    });

    test("opens dest storage with destDatabasePath", async () => {
        await moveAssetsHandler(makeData(), makeContext());

        expect(mockOpenStorage).toHaveBeenCalledWith("/fake/dest");
    });

    test("calls loadSortIndexes for both source and dest", async () => {
        await moveAssetsHandler(makeData(), makeContext());

        expect(mockLoadSortIndexes).toHaveBeenCalledTimes(2);
    });

    test("throws when asset is not found in source", async () => {
        sourceDb.metadataCollection.getOne.mockResolvedValue(null);

        await expect(moveAssetsHandler(makeData(), makeContext())).rejects.toThrow(
            `Asset "asset-1" not found in source database "/fake/source".`
        );
    });

    test("skips writing binary file when it does not exist in source", async () => {
        (sourceStorage.storage.fileExists as jest.Mock).mockResolvedValue(false);

        await moveAssetsHandler(makeData(), makeContext());

        expect(mockWriteAssetStreamVerified).not.toHaveBeenCalled();
    });

    test("copies existing binary files to destination via writeAssetStreamVerified", async () => {
        const fakeStream = {} as any;
        (sourceStorage.storage.fileExists as jest.Mock).mockImplementation(async (path: string) => path === "thumb/asset-1");
        (sourceStorage.storage.info as jest.Mock).mockResolvedValue({ contentType: "image/jpeg", length: 1024 });
        mockStreamAsset.mockResolvedValue(fakeStream);

        await moveAssetsHandler(makeData(), makeContext());

        expect(mockWriteAssetStreamVerified).toHaveBeenCalledWith(
            sourceStorage.storage,
            destStorage.storage,
            destStorage.rawStorage,
            "test-session",
            "asset-1",
            "new-asset-id",
            "thumb",
            "image/jpeg",
            fakeStream,
            1024
        );
    });

    test("writes metadata to destination with new asset ID", async () => {
        await moveAssetsHandler(makeData(), makeContext());

        expect(destDb.metadataCollection.updateOne).toHaveBeenCalledWith(
            "new-asset-id",
            expect.objectContaining({ _id: "new-asset-id" }),
            { upsert: true }
        );
    });

    test("commits the dest bsonDatabase after writing metadata", async () => {
        await moveAssetsHandler(makeData(), makeContext());

        expect(destDb.bsonDatabase.commit).toHaveBeenCalled();
    });

    test("hard-deletes the original asset from source after copying", async () => {
        await moveAssetsHandler(makeData(), makeContext());

        expect(mockRemoveAsset).toHaveBeenCalledWith(
            sourceStorage.storage,
            sourceStorage.rawStorage,
            "test-session",
            sourceDb.bsonDatabase,
            sourceDb.metadataCollection,
            "asset-1",
            true
        );
    });

    test("returns movedCount equal to the number of asset IDs", async () => {
        const context = makeContext({
            uuidGenerator: { generate: jest.fn().mockReturnValueOnce("new-1").mockReturnValueOnce("new-2") },
        });
        sourceDb = makeDatabase({
            "asset-1": { _id: "asset-1" },
            "asset-2": { _id: "asset-2" },
        });
        mockCreateMediaFileDatabase.mockImplementation((_storage: any) => {
            if (_storage === sourceStorage.storage) {
                return sourceDb as any;
            }
            return destDb as any;
        });

        const result = await moveAssetsHandler(makeData({ assetIds: ["asset-1", "asset-2"] }), context);

        expect(result.movedCount).toBe(2);
    });
});
