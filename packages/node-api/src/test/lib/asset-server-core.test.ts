import type { IDatabaseOp } from "api";

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("storage", () => ({
    createStorage: jest.fn(),
    loadEncryptionKeysFromPem: jest.fn(),
}));

jest.mock("../../lib/media-file-database", () => ({
    streamAsset: jest.fn(),
    writeAssetStream: jest.fn(),
    createLazyDatabaseStorage: jest.fn(),
}));

jest.mock("../../lib/resolve-storage-credentials", () => ({
    resolveStorageCredentials: jest.fn(),
}));

jest.mock("../../lib/apply-database-ops", () => ({
    applyDatabaseOps: jest.fn(),
}));

import { createStorage, loadEncryptionKeysFromPem } from "storage";
import { streamAsset, writeAssetStream, createLazyDatabaseStorage } from "../../lib/media-file-database";
import { resolveStorageCredentials } from "../../lib/resolve-storage-credentials";
import { applyDatabaseOps } from "../../lib/apply-database-ops";
import { createAssetServerCore } from "../../lib/asset-server-core";

const mockCreateStorage = createStorage as jest.MockedFunction<typeof createStorage>;
const mockLoadEncryptionKeysFromPem = loadEncryptionKeysFromPem as jest.MockedFunction<typeof loadEncryptionKeysFromPem>;
const mockStreamAsset = streamAsset as jest.MockedFunction<typeof streamAsset>;
const mockWriteAssetStream = writeAssetStream as jest.MockedFunction<typeof writeAssetStream>;
const mockCreateLazyDatabaseStorage = createLazyDatabaseStorage as jest.MockedFunction<typeof createLazyDatabaseStorage>;
const mockResolveStorageCredentials = resolveStorageCredentials as jest.MockedFunction<typeof resolveStorageCredentials>;
const mockApplyDatabaseOps = applyDatabaseOps as jest.MockedFunction<typeof applyDatabaseOps>;

//
// Builds a core with stub uuid/timestamp providers.
//
function makeCore() {
    return createAssetServerCore({
        uuidGenerator: { generate: jest.fn().mockReturnValue("uuid-1") },
        timestampProvider: { now: jest.fn().mockReturnValue(0), dateNow: jest.fn().mockReturnValue(new Date(0)) },
        sessionId: "test-session",
    });
}

describe("createAssetServerCore", () => {
    beforeEach(() => {
        jest.clearAllMocks();
        mockResolveStorageCredentials.mockResolvedValue({ s3Config: undefined, encryptionKeyPems: [] } as any);
        mockLoadEncryptionKeysFromPem.mockResolvedValue({ options: {} } as any);
        mockCreateLazyDatabaseStorage.mockResolvedValue({ __label: "lazy-storage" } as any);
    });

    test("serveAsset streams the asset bytes for the given id/type/db", async () => {
        const fakeStream = { __label: "asset-stream" } as any;
        mockStreamAsset.mockResolvedValue(fakeStream);

        const core = makeCore();
        const result = await core.serveAsset("asset-1", "thumb", "/db/path");

        expect(result).toBe(fakeStream);
        expect(mockStreamAsset).toHaveBeenCalledWith({ __label: "lazy-storage" }, "asset-1", "thumb");
    });

    test("serveAsset serves each asset type from the same storage", async () => {
        mockStreamAsset.mockResolvedValue({} as any);

        const core = makeCore();
        await core.serveAsset("asset-1", "thumb", "/db/path");
        await core.serveAsset("asset-1", "display", "/db/path");
        await core.serveAsset("asset-1", "asset", "/db/path");

        expect(mockStreamAsset).toHaveBeenNthCalledWith(1, expect.anything(), "asset-1", "thumb");
        expect(mockStreamAsset).toHaveBeenNthCalledWith(2, expect.anything(), "asset-1", "display");
        expect(mockStreamAsset).toHaveBeenNthCalledWith(3, expect.anything(), "asset-1", "asset");
    });

    test("serveAsset caches storage per database path", async () => {
        mockStreamAsset.mockResolvedValue({} as any);

        const core = makeCore();
        await core.serveAsset("asset-1", "thumb", "/db/path");
        await core.serveAsset("asset-2", "thumb", "/db/path");

        // Storage is only created once for the same database path.
        expect(mockCreateLazyDatabaseStorage).toHaveBeenCalledTimes(1);
    });

    test("serveAsset creates separate storage for different database paths", async () => {
        mockStreamAsset.mockResolvedValue({} as any);

        const core = makeCore();
        await core.serveAsset("asset-1", "thumb", "/db/one");
        await core.serveAsset("asset-1", "thumb", "/db/two");

        expect(mockCreateLazyDatabaseStorage).toHaveBeenCalledTimes(2);
    });

    test("serveAsset propagates a missing-asset error", async () => {
        mockStreamAsset.mockRejectedValue(new Error("FileNotFound"));

        const core = makeCore();
        await expect(core.serveAsset("missing", "thumb", "/db/path")).rejects.toThrow("FileNotFound");
    });

    test("writeAsset writes the stream via writeAssetStream with the session id", async () => {
        mockCreateStorage.mockReturnValue({ storage: { __label: "w-storage" }, rawStorage: { __label: "w-raw" } } as any);
        mockWriteAssetStream.mockResolvedValue(undefined);
        const inputStream = { __label: "input" } as any;

        const core = makeCore();
        await core.writeAsset("asset-1", "display", "/db/path", "image/jpeg", inputStream, 1024);

        expect(mockCreateStorage).toHaveBeenCalledWith("/db/path", undefined, undefined);
        expect(mockWriteAssetStream).toHaveBeenCalledWith(
            { __label: "w-storage" },
            { __label: "w-raw" },
            "test-session",
            "asset-1",
            "display",
            "image/jpeg",
            inputStream,
            1024
        );
    });

    test("applyDatabaseOps delegates to the apply-database-ops library with context identity", async () => {
        mockApplyDatabaseOps.mockResolvedValue(undefined);
        const ops: IDatabaseOp[] = [{ databaseId: "/db/path", collectionName: "metadata", recordId: "asset-1", op: { type: "set", fields: {} } }] as any;

        const core = makeCore();
        await core.applyDatabaseOps(ops);

        expect(mockApplyDatabaseOps).toHaveBeenCalledWith(
            expect.objectContaining({ generate: expect.any(Function) }),
            expect.objectContaining({ now: expect.any(Function) }),
            "test-session",
            ops
        );
    });
});
