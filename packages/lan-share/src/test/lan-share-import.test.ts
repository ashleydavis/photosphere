import { importDatabasePayload, importSecretPayload } from "../lib/lan-share-import";
import type { ConflictResolver, IDatabaseSharePayload, ISecretSharePayload } from "../lib/lan-share-types";

// Mock the vault module
const mockVaultSet = jest.fn();
const mockVaultGet = jest.fn();
jest.mock("vault", () => ({
    getDefaultVaultType: () => "plaintext",
    getVault: () => ({
        set: mockVaultSet,
        get: mockVaultGet,
    }),
}));

// Resolver that always replaces; used in tests where no conflict is expected.
const noConflictResolver: ConflictResolver = jest.fn().mockResolvedValue({ action: "replace" });

beforeEach(() => {
    mockVaultSet.mockReset();
    mockVaultGet.mockReset();
    mockVaultGet.mockResolvedValue(undefined);
});

test("imports database payload with all secrets", async () => {
    const payload: IDatabaseSharePayload = {
        type: "database",
        name: "shared-photos",
        description: "Photos from another device",
        path: "/data/shared-photos",
        origin: "https://example.com",
        s3Credentials: {
            name: "default:s3",
            label: "My S3",
            region: "us-east-1",
            accessKeyId: "AKID",
            secretAccessKey: "SECRET",
            endpoint: "https://s3.example.com",
        },
        encryptionKey: {
            name: "digital-ocean",
            label: "My Key",
            privateKeyPem: "-----PRIVATE-----",
            publicKeyPem: "-----PUBLIC-----",
        },
        geocodingKey: {
            name: "geocoding-key",
            label: "Geocoding",
            apiKey: "geo-key-123",
        },
    };

    const entry = await importDatabasePayload(payload, noConflictResolver);

    expect(entry.name).toBe("shared-photos");
    expect(entry.description).toBe("Photos from another device");
    expect(entry.path).toBe("/data/shared-photos");
    expect(entry.origin).toBe("https://example.com");
    expect(entry.s3Key).toBeDefined();
    expect(entry.encryptionKey).toBeDefined();
    expect(entry.geocodingKey).toBeDefined();

    // Verify vault.set was called 3 times (one for each secret)
    expect(mockVaultSet).toHaveBeenCalledTimes(3);

    // Verify S3 credential was stored
    const s3Call = mockVaultSet.mock.calls.find(
        (call: unknown[]) => (call[0] as { type: string }).type === "s3-credentials"
    );
    expect(s3Call).toBeDefined();
    const s3Value = JSON.parse(s3Call[0].value);
    expect(s3Value.label).toBe("My S3");
    expect(s3Value.region).toBe("us-east-1");

    // Verify encryption key was stored
    const encCall = mockVaultSet.mock.calls.find(
        (call: unknown[]) => (call[0] as { type: string }).type === "encryption-key"
    );
    expect(encCall).toBeDefined();
    const encValue = JSON.parse(encCall[0].value);
    expect(encValue.privateKeyPem).toBe("-----PRIVATE-----");

    // Verify geocoding key was stored
    const geoCall = mockVaultSet.mock.calls.find(
        (call: unknown[]) => (call[0] as { type: string }).type === "api-key"
    );
    expect(geoCall).toBeDefined();
    const geoValue = JSON.parse(geoCall[0].value);
    expect(geoValue.apiKey).toBe("geo-key-123");
});

test("imports database payload with no secrets", async () => {
    const payload: IDatabaseSharePayload = {
        type: "database",
        name: "simple-db",
        description: "",
        path: "/data/simple",
    };

    const entry = await importDatabasePayload(payload, noConflictResolver);

    expect(entry.name).toBe("simple-db");
    expect(entry.s3Key).toBeUndefined();
    expect(entry.encryptionKey).toBeUndefined();
    expect(entry.geocodingKey).toBeUndefined();
    expect(mockVaultSet).not.toHaveBeenCalled();
});

test("imports secret payload", async () => {
    const payload: ISecretSharePayload = {
        type: "secret",
        name: "s3:my-s3",
        secretType: "s3-credentials",
        value: JSON.stringify({ label: "My S3", region: "us-east-1", accessKeyId: "AKID", secretAccessKey: "SECRET" }),
    };

    await importSecretPayload(payload, "shared:imported1");

    expect(mockVaultSet).toHaveBeenCalledTimes(1);
    expect(mockVaultSet).toHaveBeenCalledWith({
        name: "shared:imported1",
        type: "s3-credentials",
        value: payload.value,
    });
});

test("imported database entry uses secret names from payload", async () => {
    const payload: IDatabaseSharePayload = {
        type: "database",
        name: "test-db",
        description: "",
        path: "/data/test",
        s3Credentials: {
            name: "default:s3",
            label: "S3",
            region: "us-east-1",
            accessKeyId: "AK",
            secretAccessKey: "SK",
        },
        encryptionKey: {
            name: "digital-ocean",
            label: "Key",
            privateKeyPem: "priv",
            publicKeyPem: "pub",
        },
    };

    const entry = await importDatabasePayload(payload, noConflictResolver);

    // Secret names should match those in the payload, not random IDs.
    expect(entry.s3Key).toBe("default:s3");
    expect(entry.encryptionKey).toBe("digital-ocean");
});

test("conflict resolver reuse: skips vault.set and keeps original name", async () => {
    mockVaultGet.mockResolvedValue({ name: "default:s3", type: "s3-credentials", value: "{}" });

    const resolver: ConflictResolver = jest.fn().mockResolvedValue({ action: "reuse" });

    const payload: IDatabaseSharePayload = {
        type: "database",
        name: "test-db",
        description: "",
        path: "/data/test",
        s3Credentials: {
            name: "default:s3",
            label: "S3",
            region: "us-east-1",
            accessKeyId: "AK",
            secretAccessKey: "SK",
        },
    };

    const entry = await importDatabasePayload(payload, resolver);

    expect(resolver).toHaveBeenCalledWith("default:s3", "s3-credentials");
    expect(mockVaultSet).not.toHaveBeenCalled();
    expect(entry.s3Key).toBe("default:s3");
});

test("conflict resolver replace: calls vault.set with original name", async () => {
    mockVaultGet.mockResolvedValue({ name: "default:s3", type: "s3-credentials", value: "{}" });

    const resolver: ConflictResolver = jest.fn().mockResolvedValue({ action: "replace" });

    const payload: IDatabaseSharePayload = {
        type: "database",
        name: "test-db",
        description: "",
        path: "/data/test",
        s3Credentials: {
            name: "default:s3",
            label: "S3",
            region: "us-east-1",
            accessKeyId: "AK",
            secretAccessKey: "SK",
        },
    };

    const entry = await importDatabasePayload(payload, resolver);

    expect(resolver).toHaveBeenCalledWith("default:s3", "s3-credentials");
    expect(mockVaultSet).toHaveBeenCalledTimes(1);
    expect(mockVaultSet.mock.calls[0][0].name).toBe("default:s3");
    expect(entry.s3Key).toBe("default:s3");
});

test("conflict resolver rename: calls vault.set with new name and updates entry", async () => {
    mockVaultGet.mockResolvedValue({ name: "default:s3", type: "s3-credentials", value: "{}" });

    const resolver: ConflictResolver = jest.fn().mockResolvedValue({ action: "rename", newName: "default:s3-imported" });

    const payload: IDatabaseSharePayload = {
        type: "database",
        name: "test-db",
        description: "",
        path: "/data/test",
        s3Credentials: {
            name: "default:s3",
            label: "S3",
            region: "us-east-1",
            accessKeyId: "AK",
            secretAccessKey: "SK",
        },
    };

    const entry = await importDatabasePayload(payload, resolver);

    expect(resolver).toHaveBeenCalledWith("default:s3", "s3-credentials");
    expect(mockVaultSet).toHaveBeenCalledTimes(1);
    expect(mockVaultSet.mock.calls[0][0].name).toBe("default:s3-imported");
    expect(entry.s3Key).toBe("default:s3-imported");
});

test("conflict resolver not called when no existing secret", async () => {
    mockVaultGet.mockResolvedValue(undefined);

    const resolver: ConflictResolver = jest.fn();

    const payload: IDatabaseSharePayload = {
        type: "database",
        name: "test-db",
        description: "",
        path: "/data/test",
        s3Credentials: {
            name: "default:s3",
            label: "S3",
            region: "us-east-1",
            accessKeyId: "AK",
            secretAccessKey: "SK",
        },
    };

    await importDatabasePayload(payload, resolver);

    expect(resolver).not.toHaveBeenCalled();
    expect(mockVaultSet).toHaveBeenCalledTimes(1);
});
