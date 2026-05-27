jest.mock("api", () => ({
    ...jest.requireActual("api"),
    acquireWriteLock: jest.fn().mockResolvedValue(true),
    releaseWriteLock: jest.fn().mockResolvedValue(undefined),
    refreshWriteLock: jest.fn().mockResolvedValue(undefined),
    updateDatabaseConfig: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("../../lib/tree", () => ({
    loadMerkleTree: jest.fn().mockResolvedValue({ databaseMetadata: { filesImported: 0 } }),
    saveMerkleTree: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("../../lib/hash", () => ({
    computeAssetHash: jest.fn(),
}));

jest.mock("merkle-tree", () => ({
    addItem: jest.fn((tree) => tree),
}));

jest.mock("utils", () => ({
    log: { verbose: jest.fn(), error: jest.fn(), exception: jest.fn(), info: jest.fn() },
    retry: jest.fn((fn) => fn()),
}));

import { writeAssetStreamVerified } from "../../lib/media-file-database";
import { computeAssetHash } from "../../lib/hash";

const mockComputeAssetHash = computeAssetHash as jest.MockedFunction<typeof computeAssetHash>;

//
// Builds a mock IStorage with controllable responses.
//
function makeStorage(infoResult: any, stream: any = {}): any {
    return {
        info: jest.fn().mockResolvedValue(infoResult),
        readStream: jest.fn().mockResolvedValue(stream),
        writeStream: jest.fn().mockResolvedValue(undefined),
        deleteFile: jest.fn().mockResolvedValue(undefined),
    };
}

//
// Returns a fake IHashedData with the given hash bytes.
//
function makeHash(bytes: number[]): any {
    return { hash: Buffer.from(bytes), length: 4, lastModified: new Date() };
}

describe("writeAssetStreamVerified", () => {
    const fakeInfo = { contentType: "image/jpeg", length: 4, lastModified: new Date() };
    const fakeStream: any = {};
    const fakeRawStorage: any = {};

    beforeEach(() => {
        jest.clearAllMocks();
    });

    test("calls writeAssetStream with dest storage and correct arguments", async () => {
        const sourceStorage = makeStorage(fakeInfo, fakeStream);
        const destStorage = makeStorage(fakeInfo, fakeStream);
        const inputStream = fakeStream;
        mockComputeAssetHash.mockResolvedValue(makeHash([1, 2, 3]));

        await writeAssetStreamVerified(
            sourceStorage, destStorage, fakeRawStorage,
            "session-1", "src-id", "dst-id", "thumb", "image/jpeg", inputStream, 4,
        );

        expect(destStorage.writeStream).toHaveBeenCalledWith("thumb/dst-id", "image/jpeg", inputStream, 4);
    });

    test("throws when source file is not accessible after write", async () => {
        const sourceStorage = makeStorage(null);
        const destStorage = makeStorage(fakeInfo, fakeStream);

        await expect(
            writeAssetStreamVerified(
                sourceStorage, destStorage, fakeRawStorage,
                "session-1", "src-id", "dst-id", "thumb", "image/jpeg", fakeStream, 4,
            )
        ).rejects.toThrow(`Verification failed: source file "thumb/src-id" is no longer accessible after write.`);
    });

    test("throws when destination file is not found after write", async () => {
        const sourceStorage = makeStorage(fakeInfo, fakeStream);
        const destStorage = makeStorage(fakeInfo, fakeStream);
        mockComputeAssetHash.mockResolvedValue(makeHash([1, 2, 3]));

        //
        // writeAssetStream calls destStorage.info() once to verify the write succeeded.
        // writeAssetStreamVerified then calls it again for its own verification check.
        // Return a valid result on the first call, null on the second.
        //
        destStorage.info
            .mockResolvedValueOnce(fakeInfo)
            .mockResolvedValueOnce(null);

        await expect(
            writeAssetStreamVerified(
                sourceStorage, destStorage, fakeRawStorage,
                "session-1", "src-id", "dst-id", "thumb", "image/jpeg", fakeStream, 4,
            )
        ).rejects.toThrow(`Verification failed: destination file "thumb/dst-id" not found after write.`);
    });

    test("throws when source and dest hashes do not match", async () => {
        const sourceStorage = makeStorage(fakeInfo, fakeStream);
        const destStorage = makeStorage(fakeInfo, fakeStream);
        mockComputeAssetHash
            .mockResolvedValueOnce(makeHash([1, 2, 3]))
            .mockResolvedValueOnce(makeHash([4, 5, 6]));

        await expect(
            writeAssetStreamVerified(
                sourceStorage, destStorage, fakeRawStorage,
                "session-1", "src-id", "dst-id", "thumb", "image/jpeg", fakeStream, 4,
            )
        ).rejects.toThrow(`Verification failed: hash mismatch for "thumb" of asset "src-id"`);
    });

    test("resolves when source and dest hashes match", async () => {
        const sourceStorage = makeStorage(fakeInfo, fakeStream);
        const destStorage = makeStorage(fakeInfo, fakeStream);
        mockComputeAssetHash.mockResolvedValue(makeHash([1, 2, 3]));

        await expect(
            writeAssetStreamVerified(
                sourceStorage, destStorage, fakeRawStorage,
                "session-1", "src-id", "dst-id", "thumb", "image/jpeg", fakeStream, 4,
            )
        ).resolves.toBeUndefined();
    });
});
