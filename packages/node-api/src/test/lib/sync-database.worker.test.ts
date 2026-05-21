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
    checkConnectivity: jest.fn().mockResolvedValue(true),
}));

jest.mock("api", () => ({
    ...jest.requireActual("api"),
    loadDatabaseConfig: jest.fn().mockResolvedValue({ origin: "/fake/origin" }),
    updateDatabaseConfig: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("../../lib/sync", () => ({
    syncDatabases: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("utils", () => ({
    log: { verbose: jest.fn(), error: jest.fn(), exception: jest.fn(), info: jest.fn() },
}));

import { createStorage } from "storage";
import { updateDatabaseConfig } from "api";
import { syncDatabaseHandler } from "../../lib/sync-database.worker";

const mockCreateStorage = createStorage as jest.MockedFunction<typeof createStorage>;
const mockUpdateDatabaseConfig = updateDatabaseConfig as jest.MockedFunction<typeof updateDatabaseConfig>;

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

    test("stamps lastSyncedAt on both local and origin storage with the same value", async () => {
        await syncDatabaseHandler(makeData(), makeContext());

        expect(mockUpdateDatabaseConfig).toHaveBeenCalledTimes(2);

        const firstCall = mockUpdateDatabaseConfig.mock.calls[0];
        const secondCall = mockUpdateDatabaseConfig.mock.calls[1];

        const firstStorage = firstCall[0] as any;
        const secondStorage = secondCall[0] as any;
        expect(firstStorage.__label).toBe("local-raw");
        expect(secondStorage.__label).toBe("origin-raw");

        const firstPartial = firstCall[1] as { lastSyncedAt: string };
        const secondPartial = secondCall[1] as { lastSyncedAt: string };
        expect(firstPartial.lastSyncedAt).toBeDefined();
        expect(typeof firstPartial.lastSyncedAt).toBe("string");
        expect(firstPartial.lastSyncedAt).toBe(secondPartial.lastSyncedAt);
    });
});
