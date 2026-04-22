import { resolveDatabaseSharePayload, resolveSecretSharePayload } from "../lib/lan-share-resolve";
import type { IDatabaseEntry } from "electron-defs";

// Mock the vault module
const mockVaultGet = jest.fn();
jest.mock("vault", () => ({
    getDefaultVaultType: () => "plaintext",
    getVault: () => ({
        get: mockVaultGet,
    }),
}));

beforeEach(() => {
    mockVaultGet.mockReset();
});

test("resolves database payload with all secrets", async () => {
    const entry: IDatabaseEntry = {
        name: "my-photos",
        description: "Family photos",
        path: "/data/photos",
        origin: "https://example.com",
        s3CredentialId: "abc12345",
        encryptionKeyId: "def67890",
        geocodingKeyId: "ghi11111",
    };

    mockVaultGet.mockImplementation(async (name: string) => {
        if (name === "abc12345") {
            return {
                name: "abc12345",
                type: "s3-credentials",
                value: JSON.stringify({
                    label: "My S3",
                    region: "us-east-1",
                    accessKeyId: "AKID",
                    secretAccessKey: "SECRET",
                    endpoint: "https://s3.example.com",
                }),
            };
        }
        if (name === "def67890") {
            return {
                name: "def67890",
                type: "encryption-key",
                value: JSON.stringify({
                    label: "My Key",
                    privateKeyPem: "-----PRIVATE-----",
                    publicKeyPem: "-----PUBLIC-----",
                }),
            };
        }
        if (name === "ghi11111") {
            return {
                name: "ghi11111",
                type: "api-key",
                value: JSON.stringify({
                    label: "Geocoding",
                    apiKey: "geo-key-123",
                }),
            };
        }
        return undefined;
    });

    const payload = await resolveDatabaseSharePayload(entry);

    expect(payload.type).toBe("database");
    expect(payload.name).toBe("my-photos");
    expect(payload.description).toBe("Family photos");
    expect(payload.path).toBe("/data/photos");
    expect(payload.origin).toBe("https://example.com");

    expect(payload.s3Credentials).toBeDefined();
    expect(payload.s3Credentials!.label).toBe("My S3");
    expect(payload.s3Credentials!.region).toBe("us-east-1");
    expect(payload.s3Credentials!.accessKeyId).toBe("AKID");
    expect(payload.s3Credentials!.secretAccessKey).toBe("SECRET");
    expect(payload.s3Credentials!.endpoint).toBe("https://s3.example.com");

    expect(payload.encryptionKey).toBeDefined();
    expect(payload.encryptionKey!.label).toBe("My Key");
    expect(payload.encryptionKey!.privateKeyPem).toBe("-----PRIVATE-----");
    expect(payload.encryptionKey!.publicKeyPem).toBe("-----PUBLIC-----");

    expect(payload.geocodingKey).toBeDefined();
    expect(payload.geocodingKey!.label).toBe("Geocoding");
    expect(payload.geocodingKey!.apiKey).toBe("geo-key-123");
});

test("resolves database payload with no secrets", async () => {
    const entry: IDatabaseEntry = {
        name: "simple-db",
        description: "",
        path: "/data/simple",
    };

    const payload = await resolveDatabaseSharePayload(entry);

    expect(payload.type).toBe("database");
    expect(payload.name).toBe("simple-db");
    expect(payload.s3Credentials).toBeUndefined();
    expect(payload.encryptionKey).toBeUndefined();
    expect(payload.geocodingKey).toBeUndefined();
});

test("resolves database payload when secret ID exists but vault entry is missing", async () => {
    const entry: IDatabaseEntry = {
        name: "orphaned-db",
        description: "",
        path: "/data/orphaned",
        s3CredentialId: "missing123",
    };

    mockVaultGet.mockResolvedValue(undefined);

    const payload = await resolveDatabaseSharePayload(entry);

    expect(payload.s3Credentials).toBeUndefined();
});

test("resolves secret share payload", async () => {
    mockVaultGet.mockResolvedValue({
        name: "shared:abc12345",
        type: "s3-credentials",
        value: JSON.stringify({ label: "My S3", region: "us-east-1", accessKeyId: "AKID", secretAccessKey: "SECRET" }),
    });

    const payload = await resolveSecretSharePayload("shared:abc12345");

    expect(payload.type).toBe("secret");
    expect(payload.secretType).toBe("s3-credentials");
    expect(JSON.parse(payload.value).region).toBe("us-east-1");
});

test("resolves secret share payload throws when secret not found", async () => {
    mockVaultGet.mockResolvedValue(undefined);

    await expect(resolveSecretSharePayload("shared:nonexistent")).rejects.toThrow(
        'Secret "shared:nonexistent" not found in vault.'
    );
});
