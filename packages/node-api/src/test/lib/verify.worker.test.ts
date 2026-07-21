import type { ITaskContext } from "task-queue";
import type { IVerifyFileData } from "../../lib/verify.worker";

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("../../lib/open-storage", () => ({
    openStorage: jest.fn(),
}));

jest.mock("../../lib/hash", () => ({
    computeAssetHash: jest.fn(),
}));

jest.mock("utils", () => ({
    log: { verbose: jest.fn(), verboseEnabled: false },
    formatFileSize: jest.fn().mockImplementation((size: number) => `${size}B`),
    // Call the operation through so the handler's retry-wrapped calls run once.
    retry: jest.fn().mockImplementation((operation: () => Promise<any>) => operation()),
}));

import { openStorage } from "../../lib/open-storage";
import { computeAssetHash } from "../../lib/hash";
import { verifyFileHandler } from "../../lib/verify.worker";

const mockOpenStorage = openStorage as jest.MockedFunction<typeof openStorage>;
const mockComputeAssetHash = computeAssetHash as jest.MockedFunction<typeof computeAssetHash>;

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
        taskId: "verify-task-id",
    };
}

//
// A representative node timestamp shared by the node and its matching file info.
//
const NODE_TIMESTAMP = new Date("2023-01-01T00:00:00.000Z");

//
// Builds verify-file input for a node with the given size, timestamp and content hash.
//
function makeData(size: number, lastModified: Date, contentHash: Buffer): IVerifyFileData {
    return {
        node: {
            name: "thumb/asset.jpg",
            size,
            lastModified,
            contentHash,
        } as any,
        storageDescriptor: { databasePath: "/fake/db", encryptionKey: undefined } as any,
    };
}

//
// Sets openStorage to return a storage whose info/readStream come from the given overrides.
//
function mockStorage(info: any): jest.Mock {
    const infoMock = jest.fn().mockResolvedValue(info);
    mockOpenStorage.mockResolvedValue({
        storage: {
            info: infoMock,
            readStream: jest.fn().mockResolvedValue({ __stream: true }),
        } as any,
        rawStorage: {} as any,
        encryptionKeyPems: [],
        s3Config: undefined,
        storageOptions: {} as any,
        googleApiKey: undefined,
    });
    return infoMock;
}

describe("verifyFileHandler", () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test("reports removed when the file no longer exists in storage", async () => {
        mockStorage(undefined);

        const result = await verifyFileHandler(makeData(100, NODE_TIMESTAMP, Buffer.from("hash")), makeContext());

        expect(result).toEqual({ fileName: "thumb/asset.jpg", status: "removed" });
        expect(mockComputeAssetHash).not.toHaveBeenCalled();
    });

    test("reports unmodified when size and timestamp are unchanged", async () => {
        mockStorage({ length: 100, lastModified: NODE_TIMESTAMP });

        const result = await verifyFileHandler(makeData(100, NODE_TIMESTAMP, Buffer.from("hash")), makeContext());

        expect(result).toEqual({ fileName: "thumb/asset.jpg", status: "unmodified" });
        // No content hash needed when the metadata matches.
        expect(mockComputeAssetHash).not.toHaveBeenCalled();
    });

    test("reports modified when metadata and content hash both changed", async () => {
        mockStorage({ length: 200, lastModified: new Date("2024-06-01T00:00:00.000Z") });
        mockComputeAssetHash.mockResolvedValue({ hash: Buffer.from("different") } as any);

        const result = await verifyFileHandler(makeData(100, NODE_TIMESTAMP, Buffer.from("original")), makeContext());

        expect(result.status).toBe("modified");
        expect(result.reasons).toContain("content hash changed");
        expect(mockComputeAssetHash).toHaveBeenCalledTimes(1);
    });

    test("reports unmodified when metadata changed but content hash matches", async () => {
        mockStorage({ length: 200, lastModified: new Date("2024-06-01T00:00:00.000Z") });
        mockComputeAssetHash.mockResolvedValue({ hash: Buffer.from("same") } as any);

        const result = await verifyFileHandler(makeData(100, NODE_TIMESTAMP, Buffer.from("same")), makeContext());

        expect(result).toEqual({ fileName: "thumb/asset.jpg", status: "unmodified" });
    });
});
