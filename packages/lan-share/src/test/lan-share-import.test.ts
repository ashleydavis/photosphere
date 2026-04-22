import { importDatabasePayload, importSecretPayload } from "../lib/lan-share-import";
import type { IDatabaseSharePayload, ISecretSharePayload } from "../lib/lan-share-types";

// Mock the vault module
const mockVaultSet = jest.fn();
jest.mock("vault", () => ({
    getDefaultVaultType: () => "plaintext",
    getVault: () => ({
        set: mockVaultSet,
    }),
}));

beforeEach(() => {
    mockVaultSet.mockReset();
});

test("imports database payload with all secrets", async () => {
    const payload: IDatabaseSharePayload = {
        type: "database",
        name: "shared-photos",
        description: "Photos from another device",
        path: "/data/shared-photos",
        origin: "https://example.com",
        s3Credentials: {
            label: "My S3",
            region: "us-east-1",
            accessKeyId: "AKID",
            secretAccessKey: "SECRET",
            endpoint: "https://s3.example.com",
        },
        encryptionKey: {
            label: "My Key",
            privateKeyPem: "-----PRIVATE-----",
            publicKeyPem: "-----PUBLIC-----",
        },
        geocodingKey: {
            label: "Geocoding",
            apiKey: "geo-key-123",
        },
    };

    const entry = await importDatabasePayload(payload);

    expect(entry.name).toBe("shared-photos");
    expect(entry.description).toBe("Photos from another device");
    expect(entry.path).toBe("/data/shared-photos");
    expect(entry.origin).toBe("https://example.com");
    expect(entry.s3CredentialId).toBeDefined();
    expect(entry.encryptionKeyId).toBeDefined();
    expect(entry.geocodingKeyId).toBeDefined();

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

    const entry = await importDatabasePayload(payload);

    expect(entry.name).toBe("simple-db");
    expect(entry.s3CredentialId).toBeUndefined();
    expect(entry.encryptionKeyId).toBeUndefined();
    expect(entry.geocodingKeyId).toBeUndefined();
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

test("imported database entry has unique secret IDs", async () => {
    const payload: IDatabaseSharePayload = {
        type: "database",
        name: "test-db",
        description: "",
        path: "/data/test",
        s3Credentials: {
            label: "S3",
            region: "us-east-1",
            accessKeyId: "AK",
            secretAccessKey: "SK",
        },
        encryptionKey: {
            label: "Key",
            privateKeyPem: "priv",
            publicKeyPem: "pub",
        },
    };

    const entry = await importDatabasePayload(payload);

    // The two secret IDs should be different
    expect(entry.s3CredentialId).not.toBe(entry.encryptionKeyId);
    // Each ID should be 8 characters
    expect(entry.s3CredentialId!.length).toBe(8);
    expect(entry.encryptionKeyId!.length).toBe(8);
});
