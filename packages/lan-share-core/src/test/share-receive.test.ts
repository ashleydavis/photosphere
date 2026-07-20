import { importShareSecrets, IDatabaseSharePayload, IShareSecretStore, IConflictResolution } from "../index";

//
// A fake secret store backed by a plain map, recording writes so tests can assert what was persisted.
//
class FakeSecretStore implements IShareSecretStore {
    // The persisted secrets, keyed by name.
    public secrets = new Map<string, { secretType: string; value: string }>();

    // Names that already exist before the import runs (to force a conflict).
    constructor(existing: string[] = []) {
        for (const name of existing) {
            this.secrets.set(name, { secretType: "pre-existing", value: "pre-existing" });
        }
    }

    async has(name: string): Promise<boolean> {
        return this.secrets.has(name);
    }

    async write(name: string, secretType: string, value: string): Promise<void> {
        this.secrets.set(name, { secretType, value });
    }
}

//
// A conflict resolver that always returns the given resolution and records the names it was asked about.
//
function fixedResolver(resolution: IConflictResolution, asked: string[]): (name: string, secretType: string) => Promise<IConflictResolution> {
    return async (name: string) => {
        asked.push(name);
        return resolution;
    };
}

//
// A database payload carrying all three kinds of secret.
//
function fullPayload(): IDatabaseSharePayload {
    return {
        type: "database",
        name: "db",
        description: "",
        path: "/data/db",
        s3Credentials: { name: "s3-secret", region: "us-east-1", accessKeyId: "AK", secretAccessKey: "SK", endpoint: "https://example.com" },
        encryptionKey: { name: "enc-secret", privateKeyPem: "-----PEM-----" },
        geocodingKey: { name: "geo-secret", apiKey: "geo-value" },
    };
}

test("writes each included secret and returns the resolved key names", async () => {
    const store = new FakeSecretStore();
    const asked: string[] = [];

    const resolvedKeys = await importShareSecrets(fullPayload(), store, fixedResolver({ action: "replace" }, asked));

    expect(resolvedKeys).toEqual({ s3Key: "s3-secret", encryptionKey: "enc-secret", geocodingKey: "geo-secret" });
    expect(asked).toEqual([]);
    expect(store.secrets.get("s3-secret")).toEqual({ secretType: "s3-credentials", value: JSON.stringify({ region: "us-east-1", accessKeyId: "AK", secretAccessKey: "SK", endpoint: "https://example.com" }) });
    expect(store.secrets.get("enc-secret")).toEqual({ secretType: "encryption-key", value: "-----PEM-----" });
    expect(store.secrets.get("geo-secret")).toEqual({ secretType: "api-key", value: "geo-value" });
});

test("reuse keeps the existing secret and does not overwrite it", async () => {
    const store = new FakeSecretStore(["geo-secret"]);
    const asked: string[] = [];

    const resolvedKeys = await importShareSecrets(fullPayload(), store, fixedResolver({ action: "reuse" }, asked));

    expect(asked).toEqual(["geo-secret"]);
    expect(resolvedKeys.geocodingKey).toBe("geo-secret");
    // The pre-existing value is retained, not overwritten with the incoming one.
    expect(store.secrets.get("geo-secret")).toEqual({ secretType: "pre-existing", value: "pre-existing" });
});

test("rename stores the incoming secret under the new name", async () => {
    const store = new FakeSecretStore(["geo-secret"]);
    const asked: string[] = [];

    const resolvedKeys = await importShareSecrets(fullPayload(), store, fixedResolver({ action: "rename", newName: "geo-secret-2" }, asked));

    expect(resolvedKeys.geocodingKey).toBe("geo-secret-2");
    expect(store.secrets.get("geo-secret-2")).toEqual({ secretType: "api-key", value: "geo-value" });
    expect(store.secrets.get("geo-secret")).toEqual({ secretType: "pre-existing", value: "pre-existing" });
});

test("replace overwrites an existing secret", async () => {
    const store = new FakeSecretStore(["geo-secret"]);
    const asked: string[] = [];

    await importShareSecrets(fullPayload(), store, fixedResolver({ action: "replace" }, asked));

    expect(asked).toEqual(["geo-secret"]);
    expect(store.secrets.get("geo-secret")).toEqual({ secretType: "api-key", value: "geo-value" });
});

test("omitted secrets leave their resolved key undefined", async () => {
    const store = new FakeSecretStore();
    const payload: IDatabaseSharePayload = { type: "database", name: "db", description: "", path: "/data/db", geocodingKey: { name: "geo-secret", apiKey: "geo-value" } };

    const resolvedKeys = await importShareSecrets(payload, store, fixedResolver({ action: "replace" }, []));

    expect(resolvedKeys).toEqual({ geocodingKey: "geo-secret" });
    expect(store.secrets.has("s3-secret")).toBe(false);
});
