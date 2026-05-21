// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock("storage", () => ({
    createStorage: jest.fn(),
    loadEncryptionKeysFromPem: jest.fn(),
}));

jest.mock("../../lib/resolve-storage-credentials", () => ({
    resolveStorageCredentials: jest.fn(),
}));

// ── imports after mocks ───────────────────────────────────────────────────────

import { createStorage, loadEncryptionKeysFromPem } from "storage";
import { resolveStorageCredentials } from "../../lib/resolve-storage-credentials";
import { openStorage } from "../../lib/open-storage";

const mockCreateStorage = createStorage as jest.MockedFunction<typeof createStorage>;
const mockLoadEncryptionKeysFromPem = loadEncryptionKeysFromPem as jest.MockedFunction<typeof loadEncryptionKeysFromPem>;
const mockResolveStorageCredentials = resolveStorageCredentials as jest.MockedFunction<typeof resolveStorageCredentials>;

describe("openStorage", () => {
    beforeEach(() => {
        jest.clearAllMocks();

        mockResolveStorageCredentials.mockResolvedValue({
            s3Config: undefined,
            encryptionKeyPems: [],
            googleApiKey: undefined,
        });

        mockLoadEncryptionKeysFromPem.mockResolvedValue({ options: { __label: "storage-options" } as any, isEncrypted: false } as any);

        mockCreateStorage.mockReturnValue({
            storage: { __label: "storage" } as any,
            rawStorage: { __label: "raw-storage" } as any,
            normalizedPath: "/normalized",
            type: "fs",
        });
    });

    test("forwards databasePath, encryptionKey, and s3Key to resolveStorageCredentials", async () => {
        await openStorage("/some/path", "my-encryption-key", "my-s3-key");

        expect(mockResolveStorageCredentials).toHaveBeenCalledTimes(1);
        expect(mockResolveStorageCredentials).toHaveBeenCalledWith("/some/path", "my-encryption-key", "my-s3-key");
    });

    test("passes the resolved encryption PEMs to loadEncryptionKeysFromPem", async () => {
        const pems = [{ privateKeyPem: "priv", publicKeyPem: "pub" }];
        mockResolveStorageCredentials.mockResolvedValueOnce({
            s3Config: undefined,
            encryptionKeyPems: pems,
            googleApiKey: undefined,
        });

        await openStorage("/some/path");

        expect(mockLoadEncryptionKeysFromPem).toHaveBeenCalledWith(pems);
    });

    test("passes the resolved s3Config and storage options into createStorage", async () => {
        const s3Config = { region: "us-east-1", accessKeyId: "AKID", secretAccessKey: "SECRET" };
        const storageOptions = { __label: "opts" } as any;
        mockResolveStorageCredentials.mockResolvedValueOnce({
            s3Config,
            encryptionKeyPems: [],
            googleApiKey: undefined,
        });
        mockLoadEncryptionKeysFromPem.mockResolvedValueOnce({ options: storageOptions, isEncrypted: false } as any);

        await openStorage("s3:bucket/prefix");

        expect(mockCreateStorage).toHaveBeenCalledWith("s3:bucket/prefix", s3Config, storageOptions);
    });

    test("returns storage, rawStorage, encryptionKeyPems, s3Config, storageOptions, and googleApiKey", async () => {
        const pems = [{ privateKeyPem: "priv", publicKeyPem: "pub" }];
        const s3Config = { region: "us-east-1", accessKeyId: "AKID", secretAccessKey: "SECRET" };
        const storageOptions = { __label: "opts" } as any;
        const storage = { __label: "storage" } as any;
        const rawStorage = { __label: "raw" } as any;
        mockResolveStorageCredentials.mockResolvedValueOnce({
            s3Config,
            encryptionKeyPems: pems,
            googleApiKey: "google-api-key",
        });
        mockLoadEncryptionKeysFromPem.mockResolvedValueOnce({ options: storageOptions, isEncrypted: true } as any);
        mockCreateStorage.mockReturnValueOnce({ storage, rawStorage, normalizedPath: "/n", type: "fs" });

        const result = await openStorage("/some/path");

        expect(result).toEqual({
            storage,
            rawStorage,
            encryptionKeyPems: pems,
            s3Config,
            storageOptions,
            googleApiKey: "google-api-key",
        });
    });

    test("works without encryptionKey or s3Key arguments", async () => {
        await openStorage("/some/path");

        expect(mockResolveStorageCredentials).toHaveBeenCalledWith("/some/path", undefined, undefined);
    });
});
