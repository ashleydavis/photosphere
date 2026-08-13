import type { ITaskContext } from "task-queue";

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

jest.mock("../../lib/tree", () => ({
    merkleTreeExists: jest.fn(),
}));

jest.mock("../../lib/media-file-database", () => ({
    createMediaFileDatabase: jest.fn(() => ({ bsonDatabase: {} })),
}));

jest.mock("../../lib/consolidate", () => ({
    consolidateDatabases: jest.fn(),
}));

jest.mock("../../lib/prefetch-database.worker", () => ({
    prefetchDatabaseHandler: jest.fn(),
}));

import { openStorage } from "../../lib/open-storage";
import { merkleTreeExists } from "../../lib/tree";
import { consolidateDatabases } from "../../lib/consolidate";
import { prefetchDatabaseHandler } from "../../lib/prefetch-database.worker";
import { consolidateDatabaseHandler, IConsolidateProgressMessage } from "../../lib/consolidate-database.worker";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;
const mockMerkleTreeExists = merkleTreeExists as jest.MockedFunction<typeof merkleTreeExists>;
const mockConsolidateDatabases = consolidateDatabases as jest.MockedFunction<typeof consolidateDatabases>;
const mockPrefetchDatabaseHandler = prefetchDatabaseHandler as jest.MockedFunction<typeof prefetchDatabaseHandler>;

//
// The messages a run streamed, so a test can check what the interface would have been told.
//
let sentMessages: any[] = [];

//
// A task context that records the messages sent through it.
//
function makeContext(): ITaskContext {
    return {
        uuidGenerator: { generate: () => "test-uuid" },
        timestampProvider: { dateNow: () => 0 },
        sendMessage: (message: any) => { sentMessages.push(message); },
        isCancelled: () => false,
    } as unknown as ITaskContext;
}

//
// The payload a normal run is asked for.
//
const VALID_DATA = {
    databasePath: "local",
    remotePath: "remote",
    sessionId: "session-1",
};

describe("consolidateDatabaseHandler", () => {

    beforeEach(() => {
        sentMessages = [];
        mockOpenStorage.mockReset();
        mockMerkleTreeExists.mockReset();
        mockConsolidateDatabases.mockReset();
        mockPrefetchDatabaseHandler.mockReset();

        mockOpenStorage.mockResolvedValue({ storage: {}, rawStorage: {} } as any);
        mockMerkleTreeExists.mockResolvedValue(true);
        mockConsolidateDatabases.mockResolvedValue({ pushedCount: 2, alreadyPresentCount: 1 } as any);
        mockPrefetchDatabaseHandler.mockResolvedValue(undefined as any);
    });

    test("a missing database path is refused rather than acted on", async () => {
        await expect(consolidateDatabaseHandler({ ...VALID_DATA, databasePath: "" }, makeContext()))
            .rejects.toThrow("databasePath is required");
        expect(mockConsolidateDatabases).not.toHaveBeenCalled();
    });

    test("a missing remote path is refused rather than acted on", async () => {
        await expect(consolidateDatabaseHandler({ ...VALID_DATA, remotePath: "" }, makeContext()))
            .rejects.toThrow("remotePath is required");
        expect(mockConsolidateDatabases).not.toHaveBeenCalled();
    });

    test("a remote with no database in it is refused, rather than consolidated into nothing", async () => {
        mockMerkleTreeExists.mockResolvedValue(false);

        await expect(consolidateDatabaseHandler(VALID_DATA, makeContext()))
            .rejects.toThrow("no database at");
        expect(mockConsolidateDatabases).not.toHaveBeenCalled();
    });

    test("returns what the consolidation did", async () => {
        const result = await consolidateDatabaseHandler(VALID_DATA, makeContext());

        expect(result.pushedCount).toBe(2);
        expect(result.alreadyPresentCount).toBe(1);
    });

    test("pulls the remote's records and thumbnails down afterwards", async () => {
        await consolidateDatabaseHandler(VALID_DATA, makeContext());

        // Without this the local database is a partial replica with nothing local to show, so the
        // gallery is empty until something happens to read each file, and a machine that goes
        // offline straight after consolidating shows nothing at all.
        expect(mockPrefetchDatabaseHandler).toHaveBeenCalledWith({ databasePath: "local" }, expect.anything());
    });

    test("does not pull anything down when the consolidation failed", async () => {
        mockConsolidateDatabases.mockRejectedValue(new Error("the push blew up"));

        await expect(consolidateDatabaseHandler(VALID_DATA, makeContext())).rejects.toThrow("the push blew up");

        expect(mockPrefetchDatabaseHandler).not.toHaveBeenCalled();
    });

    test("streams progress as assets are pushed, so a long upload is not silent", async () => {
        mockConsolidateDatabases.mockImplementation(async (...args: any[]) => {
            const onProgress = args[args.length - 1] as (pushed: number, total: number) => void;
            onProgress(1, 2);
            onProgress(2, 2);
            return { pushedCount: 2, alreadyPresentCount: 0 } as any;
        });

        await consolidateDatabaseHandler(VALID_DATA, makeContext());

        const progress = sentMessages as IConsolidateProgressMessage[];
        expect(progress).toHaveLength(2);
        expect(progress[0]).toEqual({ type: "consolidate-progress", pushed: 1, total: 2 });
        expect(progress[1]).toEqual({ type: "consolidate-progress", pushed: 2, total: 2 });
    });
});
