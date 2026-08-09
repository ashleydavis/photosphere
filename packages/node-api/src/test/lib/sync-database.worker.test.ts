import type { ITaskContext } from "task-queue";
import type { ISyncDatabaseData } from "api";

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("storage", () => ({
    createStorage: jest.fn(),
    loadEncryptionKeysFromPem: jest.fn().mockResolvedValue({ options: {} }),
}));

jest.mock("../../lib/resolve-storage-credentials", () => ({
    resolveStorageCredentials: jest.fn().mockResolvedValue({
        s3Config: undefined,
        encryptionKeyPems: [],
        googleApiKey: undefined,
    }),
}));

jest.mock("../../lib/media-file-database", () => ({
    createMediaFileDatabase: jest.fn().mockReturnValue({
        bsonDatabase: {},
        metadataCollection: {},
    }),
}));

jest.mock("../../lib/tree", () => ({
    merkleTreeExists: jest.fn().mockResolvedValue(true),
}));

jest.mock("api", () => ({
    ...jest.requireActual("api"),
    loadDatabaseConfig: jest.fn().mockResolvedValue({ origin: "/fake/origin" }),
}));

jest.mock("../../lib/sync", () => ({
    syncDatabases: jest.fn().mockResolvedValue({ synced: true }),
}));

jest.mock("utils", () => ({
    log: { verbose: jest.fn(), error: jest.fn(), exception: jest.fn(), info: jest.fn() },
}));

import { createStorage } from "storage";
import { loadDatabaseConfig } from "api";
import { merkleTreeExists } from "../../lib/tree";
import { syncDatabases } from "../../lib/sync";
import { syncDatabaseHandler } from "../../lib/sync-database.worker";

const mockCreateStorage = createStorage as jest.MockedFunction<typeof createStorage>;
const mockMerkleTreeExists = merkleTreeExists as jest.MockedFunction<typeof merkleTreeExists>;
const mockSyncDatabases = syncDatabases as jest.MockedFunction<typeof syncDatabases>;
const mockLoadDatabaseConfig = loadDatabaseConfig as jest.MockedFunction<typeof loadDatabaseConfig>;

//
// Builds a minimal ITaskContext for testing.
//
function makeContext(overrides: Partial<ITaskContext> = {}): ITaskContext {
    return {
        uuidGenerator: { generate: jest.fn().mockReturnValue("test-uuid") },
        timestampProvider: { now: jest.fn().mockReturnValue(Date.now()), dateNow: jest.fn().mockReturnValue(new Date()) },
        sessionId: "session-1",
        sendMessage: jest.fn(),
        isCancelled: jest.fn().mockReturnValue(false),
        taskId: "sync-task-id",
        ...overrides,
    };
}

//
// Builds a minimal ISyncDatabaseData for testing.
//
function makeData(overrides: Partial<ISyncDatabaseData> = {}): ISyncDatabaseData {
    return {
        databasePath: "/fake/local",
        ...overrides,
    };
}

describe("syncDatabaseHandler", () => {
    beforeEach(() => {
        jest.clearAllMocks();

        const localRawStorage = { __label: "local-raw" } as any;
        const originRawStorage = { __label: "origin-raw" } as any;

        mockCreateStorage
            .mockReturnValueOnce({
                storage: {} as any,
                rawStorage: localRawStorage,
                normalizedPath: "/fake/local",
                type: "fs",
            })
            .mockReturnValueOnce({
                storage: {} as any,
                rawStorage: originRawStorage,
                normalizedPath: "/fake/origin",
                type: "fs",
            });
    });

    test("syncs the local database against its origin", async () => {
        await syncDatabaseHandler(makeData(), makeContext());

        expect(mockSyncDatabases).toHaveBeenCalledTimes(1);

        // syncDatabases(sourceAssetStorage, sourceRawStorage, sourceBson, targetAssetStorage, targetRawStorage, ...)
        // Source is the local database, target is the origin.
        const call = mockSyncDatabases.mock.calls[0];
        const sourceRawStorage = call[1] as any;
        const targetRawStorage = call[4] as any;
        expect(sourceRawStorage.__label).toBe("local-raw");
        expect(targetRawStorage.__label).toBe("origin-raw");
    });

    test("skips sync when the origin storage has no merkle tree", async () => {
        mockMerkleTreeExists.mockResolvedValueOnce(false);

        await syncDatabaseHandler(makeData(), makeContext());

        expect(mockSyncDatabases).not.toHaveBeenCalled();
    });

    test("reports a sync-skipped message when the origin storage has no merkle tree", async () => {
        mockMerkleTreeExists.mockResolvedValueOnce(false);
        const context = makeContext();

        await syncDatabaseHandler(makeData(), context);

        expect(context.sendMessage).toHaveBeenCalledWith({
            type: "sync-skipped",
            databasePath: "/fake/local",
            reason: "origin not accessible (/fake/origin)",
        });
    });

    test("reports a sync-skipped message when the database has no origin configured", async () => {
        mockLoadDatabaseConfig.mockResolvedValueOnce(null);
        const context = makeContext();

        await syncDatabaseHandler(makeData(), context);

        expect(mockSyncDatabases).not.toHaveBeenCalled();
        expect(context.sendMessage).toHaveBeenCalledWith({
            type: "sync-skipped",
            databasePath: "/fake/local",
            reason: "no origin configured",
        });
    });

    test("sends sync-started and sync-completed around a sync that runs", async () => {
        const context = makeContext();

        await syncDatabaseHandler(makeData(), context);

        const messageTypes = (context.sendMessage as jest.Mock).mock.calls
            .map(call => call[0].type);
        expect(messageTypes).toEqual(["sync-started", "sync-completed"]);
    });

    test("the sync-completed message reports synced true when records were transferred", async () => {
        mockSyncDatabases.mockResolvedValueOnce({ synced: true });
        const context = makeContext();

        await syncDatabaseHandler(makeData(), context);

        expect(context.sendMessage).toHaveBeenCalledWith({
            type: "sync-completed",
            databasePath: "/fake/local",
            synced: true,
        });
    });

    test("the sync-completed message reports synced false when both sides were already identical", async () => {
        mockSyncDatabases.mockResolvedValueOnce({ synced: false });
        const context = makeContext();

        await syncDatabaseHandler(makeData(), context);

        expect(context.sendMessage).toHaveBeenCalledWith({
            type: "sync-completed",
            databasePath: "/fake/local",
            synced: false,
        });
    });
});
