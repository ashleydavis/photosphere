import {
    importSharePayload,
    type IReceivedSecretPayload,
} from "../lib/mobile-share-receive";
import type { IDatabaseSharePayload, IConflictResolution } from "lan-share-core";
import {
    IKeyValueStore,
    IDatabasesConfig,
    IDatabasesConfigFile,
    getDatabases,
} from "../lib/mobile-config-store";
import { MobileSecretStore, type ISecureStore } from "../lib/mobile-secure-store";

//
// Builds an in-memory key/value store implementing IKeyValueStore for the tests, plus access to the
// backing map so tests can assert exactly which localStorage keys were written.
//
interface IMemoryStore {
    // The store passed to the module under test.
    store: IKeyValueStore;

    // The backing map (localStorage stand-in).
    map: Map<string, string>;
}

//
// Creates an in-memory store.
//
//
// Builds an in-memory databases.toml for the tests, standing in for the file the embedded worker
// reads and writes on a device.
//
function memoryConfigFile(): IDatabasesConfigFile {
    let config: IDatabasesConfig = { databases: [], recentDatabaseNames: [] };
    return {
        read: async () => ({ databases: [...config.databases], recentDatabaseNames: [...config.recentDatabaseNames] }),
        write: async (updated: IDatabasesConfig) => { config = updated; },
    };
}

function memoryStore(): IMemoryStore {
    const map = new Map<string, string>();
    const store: IKeyValueStore = {
        getItem: (key: string) => (map.has(key) ? map.get(key)! : null),
        setItem: (key: string, value: string) => { map.set(key, value); },
        removeItem: (key: string) => { map.delete(key); },
    };
    return { store, map };
}

//
// Builds a MobileSecretStore over an in-memory keychain fake, standing in for the device keychain the
// secrets are written to on a real device (per step 6b).
//
function memorySecretStore(): MobileSecretStore {
    const secretMap = new Map<string, string>();
    const secureStore: ISecureStore = {
        get: async (key: string) => (secretMap.has(key) ? secretMap.get(key)! : null),
        set: async (key: string, value: string) => { secretMap.set(key, value); },
        delete: async (key: string) => { secretMap.delete(key); },
        keys: async () => [...secretMap.keys()],
    };
    return new MobileSecretStore(secureStore);
}

//
// Builds a database payload with all three secret types for the tests.
//
function databasePayloadWithSecrets(): IDatabaseSharePayload {
    return {
        type: "database",
        name: "shared-photos",
        description: "From another device",
        path: "shared-photos",
        origin: "https://example.com",
        s3Credentials: {
            name: "default:s3",
            region: "us-east-1",
            accessKeyId: "AKID",
            secretAccessKey: "SECRET",
            endpoint: "https://s3.example.com",
        },
        encryptionKey: {
            name: "digital-ocean",
            privateKeyPem: "-----PRIVATE-----",
        },
        geocodingKey: {
            name: "geocoding-key",
            apiKey: "geo-key-123",
        },
    };
}

describe("mobile-share-receive database payload", () => {

    test("imports a database with all secrets and adds the entry", async () => {
        const configFile = memoryConfigFile();
        const secretStore = memorySecretStore();

        await importSharePayload(configFile, secretStore, databasePayloadWithSecrets(), {});

        const databases = await getDatabases(configFile);
        expect(databases).toHaveLength(1);
        expect(databases[0].name).toBe("shared-photos");
        expect(databases[0].path).toBe("shared-photos");
        expect(databases[0].origin).toBe("https://example.com");
        expect(databases[0].s3Key).toBe("default:s3");
        expect(databases[0].encryptionKey).toBe("digital-ocean");
        expect(databases[0].geocodingKey).toBe("geocoding-key");

        // Secrets are stored with the right types and values in the keychain.
        expect(await secretStore.listSecrets()).toEqual(
            expect.arrayContaining([
                { name: "default:s3", type: "s3-credentials" },
                { name: "digital-ocean", type: "encryption-key" },
                { name: "geocoding-key", type: "api-key" },
            ]),
        );
        expect(await secretStore.getSecretValue("digital-ocean")).toBe("-----PRIVATE-----");
        expect(await secretStore.getSecretValue("geocoding-key")).toBe("geo-key-123");
        const s3Value = JSON.parse((await secretStore.getSecretValue("default:s3"))!);
        expect(s3Value.region).toBe("us-east-1");
        expect(s3Value.accessKeyId).toBe("AKID");
        expect(s3Value.secretAccessKey).toBe("SECRET");
        expect(s3Value.endpoint).toBe("https://s3.example.com");
    });

    test("secrets go to the keychain and only the database entry is written to the key/value store", async () => {
        const { map } = memoryStore();
        const configFile = memoryConfigFile();
        const secretStore = memorySecretStore();

        await importSharePayload(configFile, secretStore, databasePayloadWithSecrets(), {});

        // The three secrets are held in the keychain (secret store), not in localStorage.
        expect((await secretStore.listSecrets()).map(secret => secret.name)).toEqual(
            expect.arrayContaining(["default:s3", "digital-ocean", "geocoding-key"]),
        );
        // The database entry goes to databases.toml, so nothing at all is written to localStorage:
        // no secret, and no database list either.
        expect((await getDatabases(configFile)).map(database => database.name)).toEqual(["shared-photos"]);
        expect([...map.keys()]).toEqual([]);
    });

    test("conflict reuse keeps the existing secret and does not overwrite it", async () => {
        const configFile = memoryConfigFile();
        const secretStore = memorySecretStore();
        // An existing s3 secret of the same name.
        await secretStore.addSecret({ name: "default:s3", type: "s3-credentials" }, "EXISTING-VALUE");

        const resolutions: Record<string, IConflictResolution> = { "default:s3": { action: "reuse" } };
        await importSharePayload(configFile, secretStore, databasePayloadWithSecrets(), resolutions);

        // The existing secret value is untouched, and the entry references the original name.
        expect(await secretStore.getSecretValue("default:s3")).toBe("EXISTING-VALUE");
        expect((await getDatabases(configFile))[0].s3Key).toBe("default:s3");
        // There is still exactly one secret of that name.
        expect((await secretStore.listSecrets()).filter(secret => secret.name === "default:s3")).toHaveLength(1);
    });

    test("conflict rename stores the incoming secret under the new name and leaves the original", async () => {
        const configFile = memoryConfigFile();
        const secretStore = memorySecretStore();
        await secretStore.addSecret({ name: "default:s3", type: "s3-credentials" }, "EXISTING-VALUE");

        const resolutions: Record<string, IConflictResolution> = {
            "default:s3": { action: "rename", newName: "default:s3-imported" },
        };
        await importSharePayload(configFile, secretStore, databasePayloadWithSecrets(), resolutions);

        // Original untouched; the incoming value is under the new name; the entry references it.
        expect(await secretStore.getSecretValue("default:s3")).toBe("EXISTING-VALUE");
        expect(await secretStore.getSecretValue("default:s3-imported")).toBeDefined();
        expect(JSON.parse((await secretStore.getSecretValue("default:s3-imported"))!).region).toBe("us-east-1");
        expect((await getDatabases(configFile))[0].s3Key).toBe("default:s3-imported");
    });

    test("conflict replace overwrites the existing secret without throwing on the duplicate name", async () => {
        const configFile = memoryConfigFile();
        const secretStore = memorySecretStore();
        await secretStore.addSecret({ name: "digital-ocean", type: "encryption-key" }, "OLD-PEM");

        const resolutions: Record<string, IConflictResolution> = { "digital-ocean": { action: "replace" } };
        await importSharePayload(configFile, secretStore, databasePayloadWithSecrets(), resolutions);

        // Overwritten in place; exactly one secret of that name remains.
        expect(await secretStore.getSecretValue("digital-ocean")).toBe("-----PRIVATE-----");
        expect((await secretStore.listSecrets()).filter(secret => secret.name === "digital-ocean")).toHaveLength(1);
    });

    test("a missing resolution defaults to replace (matching the desktop handler)", async () => {
        const configFile = memoryConfigFile();
        const secretStore = memorySecretStore();
        await secretStore.addSecret({ name: "geocoding-key", type: "api-key" }, "OLD-GEO");

        // No resolution provided for the conflicting secret.
        await importSharePayload(configFile, secretStore, databasePayloadWithSecrets(), {});

        expect(await secretStore.getSecretValue("geocoding-key")).toBe("geo-key-123");
        expect((await secretStore.listSecrets()).filter(secret => secret.name === "geocoding-key")).toHaveLength(1);
    });

    test("a duplicate database name throws the verbatim desktop message", async () => {
        const configFile = memoryConfigFile();
        const secretStore = memorySecretStore();
        // Import once to seed the database entry.
        await importSharePayload(configFile, secretStore, databasePayloadWithSecrets(), {});

        // A second import of the same database name must reject exactly as desktop's addDatabaseEntry does.
        await expect(importSharePayload(configFile, secretStore, databasePayloadWithSecrets(), {}))
            .rejects.toThrow('A database named "shared-photos" already exists.');
    });

    test("imports a database with no secrets", async () => {
        const configFile = memoryConfigFile();
        const secretStore = memorySecretStore();
        const payload: IDatabaseSharePayload = {
            type: "database",
            name: "simple-db",
            description: "",
            path: "simple-db",
        };

        await importSharePayload(configFile, secretStore, payload, {});

        expect(await getDatabases(configFile)).toHaveLength(1);
        expect(await secretStore.listSecrets()).toHaveLength(0);
        expect((await getDatabases(configFile))[0].s3Key).toBeUndefined();
    });
});

describe("mobile-share-receive secret payload", () => {

    test("imports a standalone secret under the chosen save name", async () => {
        const { map } = memoryStore();
        const configFile = memoryConfigFile();
        const secretStore = memorySecretStore();
        const payload: IReceivedSecretPayload = {
            type: "secret",
            name: "s3:sender-name",
            secretType: "s3-credentials",
            value: JSON.stringify({ region: "us-east-1", accessKeyId: "AK", secretAccessKey: "SK" }),
            saveName: "received-s3",
        };

        await importSharePayload(configFile, secretStore, payload, {});

        expect(await secretStore.getSecretValue("received-s3")).toBe(payload.value);
        expect(await secretStore.listSecrets()).toEqual([{ name: "received-s3", type: "s3-credentials" }]);
        // A standalone secret writes nothing to the key/value store; it lives only in the keychain.
        expect([...map.keys()]).toEqual([]);
    });

    test("importing a standalone secret over an existing name overwrites it", async () => {
        const configFile = memoryConfigFile();
        const secretStore = memorySecretStore();
        await secretStore.addSecret({ name: "received-key", type: "api-key" }, "OLD");

        const payload: IReceivedSecretPayload = {
            type: "secret",
            name: "sender-key",
            secretType: "api-key",
            value: "NEW",
            saveName: "received-key",
        };

        await importSharePayload(configFile, secretStore, payload, {});

        expect(await secretStore.getSecretValue("received-key")).toBe("NEW");
        expect((await secretStore.listSecrets()).filter(secret => secret.name === "received-key")).toHaveLength(1);
    });
});
