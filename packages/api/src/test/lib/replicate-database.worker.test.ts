import type { ITaskContext } from "task-queue";
import type { IReplicateDatabaseData, IReplicateProgressMessage } from "../../lib/replicate-database.types";

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

jest.mock("../../lib/media-file-database", () => ({
    createMediaFileDatabase: jest.fn().mockReturnValue({
        bsonDatabase: { __label: "source-bson" },
        metadataCollection: {},
    }),
}));

jest.mock("../../lib/replicate", () => ({
    replicate: jest.fn().mockResolvedValue({
        filesImported: 0,
        copiedFiles: 0,
        copiedRecords: 0,
        prunedFiles: [],
    }),
}));

jest.mock("utils", () => ({
    log: { verbose: jest.fn(), error: jest.fn(), exception: jest.fn(), info: jest.fn() },
}));

import { openStorage } from "../../lib/open-storage";
import { replicate } from "../../lib/replicate";
import { replicateDatabaseHandler } from "../../lib/replicate-database.worker";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;
const mockReplicate = replicate as jest.MockedFunction<typeof replicate>;

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
        taskId: "replicate-task-id",
        ...overrides,
    };
}

//
// Builds a minimal IReplicateDatabaseData for testing.
//
function makeData(overrides: Partial<IReplicateDatabaseData> = {}): IReplicateDatabaseData {
    return {
        sourcePath: "/fake/source",
        destPath: "/fake/dest",
        destEncryptionKey: undefined,
        destS3Key: undefined,
        partial: true,
        force: false,
        ...overrides,
    };
}

describe("replicateDatabaseHandler", () => {
    beforeEach(() => {
        jest.clearAllMocks();

        mockOpenStorage.mockImplementation(async (path: string) => ({
            storage: { __label: `${path}-storage` } as any,
            rawStorage: { __label: `${path}-raw`, write: jest.fn().mockResolvedValue(undefined) } as any,
            encryptionKeyPems: [],
            s3Config: undefined,
            storageOptions: {} as any,
            googleApiKey: undefined,
        }));

        mockReplicate.mockResolvedValue({
            filesImported: 0,
            copiedFiles: 0,
            copiedRecords: 0,
            prunedFiles: [],
        });
    });

    test("opens source storage via openStorage with sourcePath and sourceEncryptionKey", async () => {
        await replicateDatabaseHandler(makeData({ sourceEncryptionKey: "my-source-key" }), makeContext());

        expect(mockOpenStorage).toHaveBeenCalledWith("/fake/source", "my-source-key");
    });

    test("opens destination storage via openStorage with destPath, destEncryptionKey and destS3Key", async () => {
        await replicateDatabaseHandler(makeData({ destEncryptionKey: "dest-key", destS3Key: "dest-s3" }), makeContext());

        expect(mockOpenStorage).toHaveBeenCalledWith("/fake/dest", "dest-key", "dest-s3");
    });

    test("forwards partial flag to replicate() when partial is true", async () => {
        await replicateDatabaseHandler(makeData({ partial: true }), makeContext());

        const options = mockReplicate.mock.calls[0][7];
        expect(options?.partial).toBe(true);
    });

    test("forwards partial flag to replicate() when partial is false", async () => {
        await replicateDatabaseHandler(makeData({ partial: false }), makeContext());

        const options = mockReplicate.mock.calls[0][7];
        expect(options?.partial).toBe(false);
    });

    test("forwards pathFilter to replicate() options", async () => {
        await replicateDatabaseHandler(makeData({ pathFilter: "subdir/" }), makeContext());

        const options = mockReplicate.mock.calls[0][7];
        expect(options?.pathFilter).toBe("subdir/");
    });

    test("emits a replicate-progress task message for each progress callback fired by replicate()", async () => {
        const context = makeContext();

        await replicateDatabaseHandler(makeData(), context);

        const progressCallback = mockReplicate.mock.calls[0][8];
        expect(progressCallback).toBeDefined();
        progressCallback!("Copied 10");
        progressCallback!("Copied 20");

        const sendMessageMock = context.sendMessage as jest.Mock;
        expect(sendMessageMock).toHaveBeenCalledTimes(2);

        const firstMessage = sendMessageMock.mock.calls[0][0] as IReplicateProgressMessage;
        expect(firstMessage).toEqual({
            type: "replicate-progress",
            databasePath: "/fake/source",
            progress: "Copied 10",
        });

        const secondMessage = sendMessageMock.mock.calls[1][0] as IReplicateProgressMessage;
        expect(secondMessage.progress).toBe("Copied 20");
    });

    test("writes encryption.pub to dest raw storage when destination is encrypted", async () => {
        const sourceRawWrite = jest.fn().mockResolvedValue(undefined);
        const destRawWrite = jest.fn().mockResolvedValue(undefined);
        mockOpenStorage
            .mockResolvedValueOnce({
                storage: { __label: "source-storage" } as any,
                rawStorage: { __label: "source-raw", write: sourceRawWrite } as any,
                encryptionKeyPems: [],
                s3Config: undefined,
                storageOptions: {} as any,
                googleApiKey: undefined,
            })
            .mockResolvedValueOnce({
                storage: { __label: "dest-storage" } as any,
                rawStorage: { __label: "dest-raw", write: destRawWrite } as any,
                encryptionKeyPems: [{ privateKeyPem: "priv", publicKeyPem: "pub-from-key" }],
                s3Config: undefined,
                storageOptions: {} as any,
                googleApiKey: undefined,
            });

        await replicateDatabaseHandler(makeData({ destEncryptionKey: "dest-key" }), makeContext());

        expect(destRawWrite).toHaveBeenCalledTimes(1);
        const [path, , buffer] = destRawWrite.mock.calls[0];
        expect(path).toBe(".db/encryption.pub");
        expect(Buffer.isBuffer(buffer)).toBe(true);
        expect((buffer as Buffer).toString("utf-8")).toBe("pub-from-key");
    });

    test("does not write encryption.pub when destination is not encrypted", async () => {
        const destRawWrite = jest.fn().mockResolvedValue(undefined);
        mockOpenStorage.mockImplementation(async (path: string) => ({
            storage: { __label: `${path}-storage` } as any,
            rawStorage: { __label: `${path}-raw`, write: destRawWrite } as any,
            encryptionKeyPems: [],
            s3Config: undefined,
            storageOptions: {} as any,
            googleApiKey: undefined,
        }));

        await replicateDatabaseHandler(makeData({ destEncryptionKey: undefined }), makeContext());

        expect(destRawWrite).not.toHaveBeenCalled();
    });

    test("returns the IReplicationResult from replicate()", async () => {
        mockReplicate.mockResolvedValueOnce({
            filesImported: 5,
            copiedFiles: 3,
            copiedRecords: 2,
            prunedFiles: ["old.jpg"],
        });

        const result = await replicateDatabaseHandler(makeData(), makeContext());

        expect(result).toEqual({
            filesImported: 5,
            copiedFiles: 3,
            copiedRecords: 2,
            prunedFiles: ["old.jpg"],
        });
    });

    test("throws when sourcePath is empty", async () => {
        await expect(replicateDatabaseHandler(makeData({ sourcePath: "" }), makeContext())).rejects.toThrow("sourcePath is required");
    });

    test("throws when destPath is empty", async () => {
        await expect(replicateDatabaseHandler(makeData({ destPath: "" }), makeContext())).rejects.toThrow("destPath is required");
    });
});
