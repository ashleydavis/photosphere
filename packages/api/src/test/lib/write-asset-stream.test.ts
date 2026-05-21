jest.mock("../../lib/write-lock", () => ({
    acquireWriteLock: jest.fn().mockResolvedValue(true),
    releaseWriteLock: jest.fn().mockResolvedValue(undefined),
    refreshWriteLock: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("../../lib/tree", () => ({
    loadMerkleTree: jest.fn().mockResolvedValue({ databaseMetadata: { filesImported: 0 } }),
    saveMerkleTree: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("../../lib/database-config", () => ({
    updateDatabaseConfig: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("../../lib/hash", () => ({
    computeAssetHash: jest.fn().mockResolvedValue({ hash: Buffer.from([1, 2, 3]), length: 4, lastModified: new Date() }),
}));

jest.mock("merkle-tree", () => ({
    addItem: jest.fn((tree) => tree),
}));

jest.mock("utils", () => ({
    log: { verbose: jest.fn(), error: jest.fn(), exception: jest.fn(), info: jest.fn() },
    retry: jest.fn((fn) => fn()),
}));

import { writeAssetStream } from "../../lib/media-file-database";
import { acquireWriteLock, releaseWriteLock } from "../../lib/write-lock";
import { loadMerkleTree, saveMerkleTree } from "../../lib/tree";
import { updateDatabaseConfig } from "../../lib/database-config";
import { addItem } from "merkle-tree";

const mockAcquireWriteLock = acquireWriteLock as jest.MockedFunction<typeof acquireWriteLock>;
const mockLoadMerkleTree = loadMerkleTree as jest.MockedFunction<typeof loadMerkleTree>;
const mockSaveMerkleTree = saveMerkleTree as jest.MockedFunction<typeof saveMerkleTree>;
const mockUpdateDatabaseConfig = updateDatabaseConfig as jest.MockedFunction<typeof updateDatabaseConfig>;
const mockAddItem = addItem as jest.MockedFunction<typeof addItem>;
const mockReleaseWriteLock = releaseWriteLock as jest.MockedFunction<typeof releaseWriteLock>;

//
// Builds a mock IStorage with the given info() response.
//
function makeStorage(infoResult: any): any {
    return {
        writeStream: jest.fn().mockResolvedValue(undefined),
        info: jest.fn().mockResolvedValue(infoResult),
        readStream: jest.fn().mockResolvedValue({}),
        deleteFile: jest.fn().mockResolvedValue(undefined),
    };
}

//
// Builds a fake raw storage (only needs to satisfy the write-lock module, which is mocked).
//
function makeRawStorage(): any {
    return {};
}

describe("writeAssetStream", () => {
    const fakeInfo = { contentType: "image/jpeg", length: 4, lastModified: new Date() };
    const fakeTree: any = { id: "tree-id", dirty: false, version: 1, databaseMetadata: { filesImported: 0 } };
    const fakeStream: any = {};

    beforeEach(() => {
        jest.clearAllMocks();
        mockLoadMerkleTree.mockResolvedValue({ ...fakeTree, databaseMetadata: { filesImported: 0 } });
        mockAddItem.mockImplementation((tree) => tree);
        mockAcquireWriteLock.mockResolvedValue(true);
    });

    test("writes the stream to the correct asset path", async () => {
        const storage = makeStorage(fakeInfo);

        await writeAssetStream(storage, makeRawStorage(), "session-1", "t1", "thumb", "image/jpeg", fakeStream, 4);

        expect(storage.writeStream).toHaveBeenCalledWith("thumb/t1", "image/jpeg", fakeStream, 4);
    });

    test("adds the written file to the merkle tree", async () => {
        const storage = makeStorage(fakeInfo);

        await writeAssetStream(storage, makeRawStorage(), "session-1", "t1", "thumb", "image/jpeg", fakeStream, 4);

        expect(mockAddItem).toHaveBeenCalledWith(
            expect.anything(),
            expect.objectContaining({ name: "thumb/t1" })
        );
        expect(mockSaveMerkleTree).toHaveBeenCalled();
    });

    test("increments filesImported when assetType is asset", async () => {
        const tree: any = { id: "tree-id", dirty: false, version: 1, databaseMetadata: { filesImported: 0 } };
        mockLoadMerkleTree.mockResolvedValue(tree);
        mockAddItem.mockImplementation((t) => t);
        const storage = makeStorage(fakeInfo);

        await writeAssetStream(storage, makeRawStorage(), "session-1", "a1", "asset", "image/jpeg", fakeStream, 4);

        expect(tree.databaseMetadata.filesImported).toBe(1);
    });

    test("does not increment filesImported when assetType is thumb", async () => {
        const tree: any = { id: "tree-id", dirty: false, version: 1, databaseMetadata: { filesImported: 0 } };
        mockLoadMerkleTree.mockResolvedValue(tree);
        mockAddItem.mockImplementation((t) => t);
        const storage = makeStorage(fakeInfo);

        await writeAssetStream(storage, makeRawStorage(), "session-1", "t1", "thumb", "image/jpeg", fakeStream, 4);

        expect(tree.databaseMetadata.filesImported).toBe(0);
    });

    test("does not increment filesImported when assetType is display", async () => {
        const tree: any = { id: "tree-id", dirty: false, version: 1, databaseMetadata: { filesImported: 0 } };
        mockLoadMerkleTree.mockResolvedValue(tree);
        mockAddItem.mockImplementation((t) => t);
        const storage = makeStorage(fakeInfo);

        await writeAssetStream(storage, makeRawStorage(), "session-1", "d1", "display", "image/jpeg", fakeStream, 4);

        expect(tree.databaseMetadata.filesImported).toBe(0);
    });

    test("calls updateDatabaseConfig after writing", async () => {
        const storage = makeStorage(fakeInfo);

        await writeAssetStream(storage, makeRawStorage(), "session-1", "t1", "thumb", "image/jpeg", fakeStream, 4);

        expect(mockUpdateDatabaseConfig).toHaveBeenCalledWith(
            expect.anything(),
            expect.objectContaining({ lastModifiedAt: expect.any(String) })
        );
    });

    test("throws when the write lock cannot be acquired", async () => {
        mockAcquireWriteLock.mockResolvedValue(false);
        const storage = makeStorage(fakeInfo);

        await expect(
            writeAssetStream(storage, makeRawStorage(), "session-1", "t1", "thumb", "image/jpeg", fakeStream, 4)
        ).rejects.toThrow("Failed to acquire write lock");
    });

    test("releases the write lock after writing", async () => {
        const storage = makeStorage(fakeInfo);

        await writeAssetStream(storage, makeRawStorage(), "session-1", "t1", "thumb", "image/jpeg", fakeStream, 4);

        expect(mockReleaseWriteLock).toHaveBeenCalled();
    });

    test("releases the write lock even when the write fails", async () => {
        const storage = makeStorage({ length: 0 });

        await expect(
            writeAssetStream(storage, makeRawStorage(), "session-1", "t1", "thumb", "image/jpeg", fakeStream, 1)
        ).rejects.toThrow("Asset data is empty");

        expect(mockReleaseWriteLock).toHaveBeenCalled();
    });

    test("deletes the partially-written file when the write fails", async () => {
        const storage = makeStorage({ length: 0 });

        await expect(
            writeAssetStream(storage, makeRawStorage(), "session-1", "t1", "thumb", "image/jpeg", fakeStream, 1)
        ).rejects.toThrow("Asset data is empty");

        expect(storage.deleteFile).toHaveBeenCalledWith("thumb/t1");
    });

    test("rejects when announced content length is zero", async () => {
        const storage = makeStorage({ length: 0 });

        await expect(
            writeAssetStream(storage, makeRawStorage(), "session-1", "t1", "thumb", undefined, fakeStream, 0)
        ).rejects.toThrow("Asset data is empty");
    });

    test("rejects when written file has zero length and no length was announced", async () => {
        const storage = makeStorage({ length: 0 });

        await expect(
            writeAssetStream(storage, makeRawStorage(), "session-1", "t1", "thumb", undefined, fakeStream, undefined)
        ).rejects.toThrow("Asset data is empty");
    });
});
