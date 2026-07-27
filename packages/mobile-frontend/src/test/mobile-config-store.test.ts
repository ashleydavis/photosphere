import {
    IKeyValueStore,
    IDatabasesConfig,
    IDatabasesConfigFile,
    getDatabases,
    addDatabase,
    updateDatabase,
    removeDatabase,
    findDatabase,
    findDatabaseByPath,
    setDatabaseOrigin,
    getRecentDatabases,
    addRecentDatabase,
    removeRecentDatabase,
    seedRecentDatabases,
    seedDatabases,
    resetConfig,
    LEGACY_PLAINTEXT_SECRETS_KEY,
    seedNews,
    getShownNewsIds,
    addShownNewsId,
    firstUnshownNews,
    buildNewsNotification,
    databaseBasename,
    getConfigValue,
    setConfigValue,
    resetConfig as resetConfigForNews,
} from "../lib/mobile-config-store";

//
// Builds an in-memory key/value store implementing IKeyValueStore for the tests.
//
function memoryStore(): IKeyValueStore {
    const map = new Map<string, string>();
    return {
        getItem: (key: string) => (map.has(key) ? map.get(key)! : null),
        setItem: (key: string, value: string) => { map.set(key, value); },
        removeItem: (key: string) => { map.delete(key); },
    };
}

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

//
// Builds a database entry for the tests.
//
function entry(name: string, path: string): any {
    return { name, description: "", path };
}

describe("mobile-config-store generic config", () => {

    test("getConfigValue returns undefined when nothing is stored", () => {
        expect(getConfigValue<boolean>(memoryStore(), "developerMode")).toBeUndefined();
    });

    test("setConfigValue then getConfigValue round-trips a value", () => {
        const store = memoryStore();
        setConfigValue<boolean>(store, "developerMode", true);
        expect(getConfigValue<boolean>(store, "developerMode")).toBe(true);
    });

    test("setConfigValue with undefined removes the stored value", () => {
        const store = memoryStore();
        setConfigValue<boolean>(store, "developerMode", true);
        setConfigValue<boolean>(store, "developerMode", undefined as unknown as boolean);
        expect(getConfigValue<boolean>(store, "developerMode")).toBeUndefined();
    });

    test("getConfigValue returns undefined for malformed JSON", () => {
        const store = memoryStore();
        store.setItem("photosphere.config.developerMode", "{not json");
        expect(getConfigValue<boolean>(store, "developerMode")).toBeUndefined();
    });
});

describe("mobile-config-store databases", () => {

    test("getDatabases returns [] when the config file is empty", async () => {
        expect(await getDatabases(memoryConfigFile())).toEqual([]);
    });

    test("addDatabase appends and replaces by case-insensitive name", async () => {
        const configFile = memoryConfigFile();
        await addDatabase(configFile, entry("Alpha", "a"));
        await addDatabase(configFile, entry("Beta", "b"));
        expect((await getDatabases(configFile)).map(database => database.name)).toEqual(["Alpha", "Beta"]);

        // Same name (different case) replaces rather than duplicates.
        await addDatabase(configFile, entry("alpha", "a2"));
        expect(await getDatabases(configFile)).toHaveLength(2);
        expect((await findDatabase(configFile, "ALPHA"))?.path).toBe("a2");
    });

    test("updateDatabase replaces the matching entry", async () => {
        const configFile = memoryConfigFile();
        await addDatabase(configFile, entry("Alpha", "a"));
        await updateDatabase(configFile, "Alpha", entry("Renamed", "a"));
        expect(await findDatabase(configFile, "Alpha")).toBeUndefined();
        expect((await findDatabase(configFile, "Renamed"))?.path).toBe("a");
    });

    test("updateDatabase carries a rename into the recent list", async () => {
        const configFile = memoryConfigFile();
        await addDatabase(configFile, entry("Alpha", "a"));
        await addRecentDatabase(configFile, entry("Alpha", "a"));
        await updateDatabase(configFile, "Alpha", entry("Renamed", "a"));
        expect((await getRecentDatabases(configFile)).map(database => database.name)).toEqual(["Renamed"]);
    });

    test("removeDatabase removes by name", async () => {
        const configFile = memoryConfigFile();
        await addDatabase(configFile, entry("Alpha", "a"));
        await addDatabase(configFile, entry("Beta", "b"));
        await removeDatabase(configFile, "alpha");
        expect((await getDatabases(configFile)).map(database => database.name)).toEqual(["Beta"]);
    });

    test("removeDatabase also drops the name from the recent list", async () => {
        const configFile = memoryConfigFile();
        await addRecentDatabase(configFile, entry("Alpha", "a"));
        await removeDatabase(configFile, "Alpha");
        expect(await getRecentDatabases(configFile)).toEqual([]);
    });

    test("findDatabaseByPath finds by path", async () => {
        const configFile = memoryConfigFile();
        await addDatabase(configFile, entry("Alpha", "a"));
        expect((await findDatabaseByPath(configFile, "a"))?.name).toBe("Alpha");
        expect(await findDatabaseByPath(configFile, "missing")).toBeUndefined();
    });

    test("setDatabaseOrigin sets the origin on the matching path", async () => {
        const configFile = memoryConfigFile();
        await addDatabase(configFile, entry("Alpha", "a"));
        await setDatabaseOrigin(configFile, "a", "s3:bucket:/x");
        expect(((await findDatabase(configFile, "Alpha")) as any).origin).toBe("s3:bucket:/x");
    });

    test("seedDatabases replaces the whole list and resetConfig clears it", async () => {
        const configFile = memoryConfigFile();
        await addDatabase(configFile, entry("Old", "o"));
        await seedDatabases(configFile, [entry("Seed", "s")]);
        expect((await getDatabases(configFile)).map(database => database.name)).toEqual(["Seed"]);
        await resetConfig(memoryStore(), configFile);
        expect(await getDatabases(configFile)).toEqual([]);
    });
});

describe("mobile-config-store secrets", () => {

    test("resetConfig clears the legacy plaintext secrets entry", async () => {
        const store = memoryStore();
        // Written by an earlier build that kept secrets in plaintext localStorage. Nothing writes this
        // key any more, but a device that ran that build still has it, so reset must remove it.
        store.setItem(LEGACY_PLAINTEXT_SECRETS_KEY, JSON.stringify([{ entry: { name: "api", type: "api-key" }, value: "v1" }]));
        await resetConfig(store, memoryConfigFile());
        expect(store.getItem(LEGACY_PLAINTEXT_SECRETS_KEY)).toBeNull();
    });
});

describe("mobile-config-store news", () => {

    test("firstUnshownNews returns the first item not yet shown", () => {
        const store = memoryStore();
        seedNews(store, [{ id: "n1", message: "first" }, { id: "n2", message: "second" }]);
        expect(firstUnshownNews(store)?.id).toBe("n1");

        addShownNewsId(store, "n1");
        expect(firstUnshownNews(store)?.id).toBe("n2");

        addShownNewsId(store, "n2");
        expect(firstUnshownNews(store)).toBeUndefined();
    });

    test("addShownNewsId is idempotent", () => {
        const store = memoryStore();
        addShownNewsId(store, "n1");
        addShownNewsId(store, "n1");
        expect(getShownNewsIds(store)).toEqual(["n1"]);
    });

    test("resetConfig clears news and shown ids", async () => {
        const store = memoryStore();
        seedNews(store, [{ id: "n1", message: "first" }]);
        addShownNewsId(store, "n0");
        await resetConfigForNews(store, memoryConfigFile());
        expect(firstUnshownNews(store)).toBeUndefined();
        expect(getShownNewsIds(store)).toEqual([]);
    });

    test("buildNewsNotification maps a news item to the toast payload with defaults", () => {
        expect(buildNewsNotification({ id: "n1", message: "hi" }))
            .toEqual({ message: "hi", color: "primary", duration: 0, newsId: "n1" });
        expect(buildNewsNotification({ id: "n2", message: "yo", color: "warning", duration: 5000 }))
            .toEqual({ message: "yo", color: "warning", duration: 5000, newsId: "n2" });
    });
});

describe("mobile-config-store databaseBasename", () => {

    test("returns the final path segment", () => {
        expect(databaseBasename("test-db")).toBe("test-db");
        expect(databaseBasename("a/b/c")).toBe("c");
        expect(databaseBasename("a\\b\\c")).toBe("c");
        expect(databaseBasename("/a/b/")).toBe("b");
    });
});

describe("mobile-config-store recent databases", () => {

    test("addRecentDatabase de-duplicates by name and moves to the front", async () => {
        const configFile = memoryConfigFile();
        await addRecentDatabase(configFile, entry("Alpha", "a"));
        await addRecentDatabase(configFile, entry("Beta", "b"));
        await addRecentDatabase(configFile, entry("Alpha", "a"));
        expect((await getRecentDatabases(configFile)).map(database => database.path)).toEqual(["a", "b"]);
    });

    test("addRecentDatabase registers a database the config did not know", async () => {
        // Recents hold names, so an unregistered name would resolve to nothing and be dropped.
        const configFile = memoryConfigFile();
        await addRecentDatabase(configFile, entry("Alpha", "a"));
        expect((await getDatabases(configFile)).map(database => database.name)).toEqual(["Alpha"]);
    });

    test("addRecentDatabase keeps at most five entries", async () => {
        const configFile = memoryConfigFile();
        for (const index of [1, 2, 3, 4, 5, 6]) {
            await addRecentDatabase(configFile, entry(`db${index}`, `p${index}`));
        }
        expect((await getRecentDatabases(configFile)).map(database => database.name))
            .toEqual(["db6", "db5", "db4", "db3", "db2"]);
    });

    test("removeRecentDatabase removes by name and leaves the entry configured", async () => {
        const configFile = memoryConfigFile();
        await addRecentDatabase(configFile, entry("Alpha", "a"));
        await addRecentDatabase(configFile, entry("Beta", "b"));
        await removeRecentDatabase(configFile, "Alpha");
        expect((await getRecentDatabases(configFile)).map(database => database.name)).toEqual(["Beta"]);
        expect((await findDatabase(configFile, "Alpha"))?.path).toBe("a");
    });

    test("seedRecentDatabases replaces the recent list", async () => {
        const configFile = memoryConfigFile();
        await addRecentDatabase(configFile, entry("Old", "o"));
        await seedDatabases(configFile, [entry("Seed", "s")]);
        await seedRecentDatabases(configFile, [entry("Seed", "s")]);
        expect((await getRecentDatabases(configFile)).map(database => database.name)).toEqual(["Seed"]);
    });
});

describe("mobile-config-store concurrent operations", () => {

    //
    // Each mutating operation reads the whole config and writes the whole config back, over two async
    // round-trips. Started together and left to interleave, both read the same starting config and the
    // second write discards the field the first one changed. The test-setup handlers start them exactly
    // this way, which is how seeding the databases list and then the recents list ended up losing one
    // of the two and leaving the sidebar with no recents at all.
    //
    test("seeding databases and recents together keeps both", async () => {
        const configFile = memoryConfigFile();
        await Promise.all([
            seedDatabases(configFile, [entry("Seed", "s")]),
            seedRecentDatabases(configFile, [entry("Seed", "s")]),
        ]);
        expect((await getDatabases(configFile)).map(database => database.name)).toEqual(["Seed"]);
        expect((await getRecentDatabases(configFile)).map(database => database.name)).toEqual(["Seed"]);
    });

    test("adding several databases together keeps every one", async () => {
        const configFile = memoryConfigFile();
        await Promise.all([
            addDatabase(configFile, entry("One", "one")),
            addDatabase(configFile, entry("Two", "two")),
            addDatabase(configFile, entry("Three", "three")),
        ]);
        expect((await getDatabases(configFile)).map(database => database.name).sort()).toEqual(["One", "Three", "Two"]);
    });

    test("a failing operation does not wedge the ones queued behind it", async () => {
        const configFile = memoryConfigFile();
        const realWrite = configFile.write;
        let writeCount = 0;
        configFile.write = async (updated: IDatabasesConfig) => {
            writeCount += 1;
            if (writeCount === 1) {
                throw new Error("write failed");
            }
            await realWrite(updated);
        };
        const rejected = seedDatabases(configFile, [entry("Lost", "lost")]);
        const queued = addDatabase(configFile, entry("Kept", "kept"));
        await expect(rejected).rejects.toThrow("write failed");
        await queued;
        expect((await getDatabases(configFile)).map(database => database.name)).toEqual(["Kept"]);
    });
});
