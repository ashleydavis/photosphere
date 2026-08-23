import type { ITaskContext } from "task-queue";
import type { IDatabaseSummary } from "../../lib/media-file-database";
import type { IGetDatabaseSummaryData } from "../../lib/get-database-summary.worker";

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

jest.mock("../../lib/media-file-database", () => ({
    getDatabaseSummary: jest.fn(),
}));

import { openStorage } from "../../lib/open-storage";
import { getDatabaseSummary } from "../../lib/media-file-database";
import { getDatabaseSummaryHandler } from "../../lib/get-database-summary.worker";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;
const mockGetDatabaseSummary = getDatabaseSummary as jest.MockedFunction<typeof getDatabaseSummary>;

//
// Builds a minimal ITaskContext for testing.
//
function makeContext(): ITaskContext {
    return {
        uuidGenerator: { generate: jest.fn().mockReturnValue("test-uuid") },
        timestampProvider: { now: jest.fn().mockReturnValue(Date.now()), dateNow: jest.fn().mockReturnValue(new Date()) },
        sessionId: "session-1",
        maxConcurrentChildTasks: 10,
        sendMessage: jest.fn(),
        isCancelled: jest.fn().mockReturnValue(false),
        taskId: "summary-task-id",
    };
}

//
// A representative summary the mocked getDatabaseSummary returns.
//
const SAMPLE_SUMMARY: IDatabaseSummary = {
    mode: "full",
    totalImports: 12,
    totalFiles: 34,
    totalSize: 5678,
    totalNodes: 46,
    fullHash: "full-hash",
    filesHash: "files-hash",
    databaseHash: "database-hash",
    databaseVersion: 3,
};

describe("getDatabaseSummaryHandler", () => {
    beforeEach(() => {
        jest.clearAllMocks();

        mockOpenStorage.mockImplementation(async (path: string) => ({
            storage: { __label: `${path}-storage` } as any,
            rawStorage: { __label: `${path}-raw` } as any,
            encryptionKeyPems: [],
            s3Config: undefined,
            storageOptions: {} as any,
            googleApiKey: undefined,
        }));

        mockGetDatabaseSummary.mockResolvedValue(SAMPLE_SUMMARY);
    });

    test("opens storage at the requested database path", async () => {
        const data: IGetDatabaseSummaryData = { databasePath: "/fake/db" };

        await getDatabaseSummaryHandler(data, makeContext());

        expect(mockOpenStorage).toHaveBeenCalledWith("/fake/db");
    });

    test("computes the summary against the opened storage", async () => {
        const data: IGetDatabaseSummaryData = { databasePath: "/fake/db" };

        await getDatabaseSummaryHandler(data, makeContext());

        expect(mockGetDatabaseSummary).toHaveBeenCalledTimes(1);
        const storageArg = mockGetDatabaseSummary.mock.calls[0][0] as any;
        expect(storageArg.__label).toBe("/fake/db-storage");
    });

    test("returns the summary produced by getDatabaseSummary", async () => {
        const data: IGetDatabaseSummaryData = { databasePath: "/fake/db" };

        const result = await getDatabaseSummaryHandler(data, makeContext());

        expect(result).toEqual(SAMPLE_SUMMARY);
    });

    test("throws when databasePath is empty", async () => {
        const data: IGetDatabaseSummaryData = { databasePath: "" };

        await expect(getDatabaseSummaryHandler(data, makeContext())).rejects.toThrow("databasePath is required");
        expect(mockOpenStorage).not.toHaveBeenCalled();
    });
});
