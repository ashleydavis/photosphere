import {
    IKeyValueStore,
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
    listSecrets,
    addSecret,
    updateSecret,
    deleteSecret,
    getSecretValue,
    seedSecrets,
    seedNews,
    getShownNewsIds,
    addShownNewsId,
    firstUnshownNews,
    buildNewsNotification,
    databaseBasename,
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
// Builds a database entry for the tests.
//
function entry(name: string, path: string): any {
    return { name, description: "", path };
}

describe("mobile-config-store databases", () => {

    test("getDatabases returns [] when nothing is stored", () => {
        expect(getDatabases(memoryStore())).toEqual([]);
    });

    test("addDatabase appends and replaces by case-insensitive name", () => {
        const store = memoryStore();
        addDatabase(store, entry("Alpha", "a"));
        addDatabase(store, entry("Beta", "b"));
        expect(getDatabases(store).map(database => database.name)).toEqual(["Alpha", "Beta"]);

        // Same name (different case) replaces rather than duplicates.
        addDatabase(store, entry("alpha", "a2"));
        const databases = getDatabases(store);
        expect(databases).toHaveLength(2);
        expect(findDatabase(store, "ALPHA")?.path).toBe("a2");
    });

    test("updateDatabase replaces the matching entry", () => {
        const store = memoryStore();
        addDatabase(store, entry("Alpha", "a"));
        updateDatabase(store, "Alpha", entry("Renamed", "a"));
        expect(findDatabase(store, "Alpha")).toBeUndefined();
        expect(findDatabase(store, "Renamed")?.path).toBe("a");
    });

    test("removeDatabase removes by name", () => {
        const store = memoryStore();
        addDatabase(store, entry("Alpha", "a"));
        addDatabase(store, entry("Beta", "b"));
        removeDatabase(store, "alpha");
        expect(getDatabases(store).map(database => database.name)).toEqual(["Beta"]);
    });

    test("findDatabaseByPath finds by path", () => {
        const store = memoryStore();
        addDatabase(store, entry("Alpha", "a"));
        expect(findDatabaseByPath(store, "a")?.name).toBe("Alpha");
        expect(findDatabaseByPath(store, "missing")).toBeUndefined();
    });

    test("setDatabaseOrigin sets the origin on the matching path", () => {
        const store = memoryStore();
        addDatabase(store, entry("Alpha", "a"));
        setDatabaseOrigin(store, "a", "s3:bucket:/x");
        expect((findDatabase(store, "Alpha") as any).origin).toBe("s3:bucket:/x");
    });

    test("seedDatabases replaces the whole list and resetConfig clears it", () => {
        const store = memoryStore();
        addDatabase(store, entry("Old", "o"));
        seedDatabases(store, [entry("Seed", "s")]);
        expect(getDatabases(store).map(database => database.name)).toEqual(["Seed"]);
        resetConfig(store);
        expect(getDatabases(store)).toEqual([]);
    });
});

describe("mobile-config-store secrets", () => {

    //
    // Builds a secret entry for the tests.
    //
    function secret(name: string, type: string): any {
        return { name, type };
    }

    test("addSecret then listSecrets returns the entry (without value)", () => {
        const store = memoryStore();
        addSecret(store, secret("api", "api-key"), "the-value");
        expect(listSecrets(store)).toEqual([{ name: "api", type: "api-key" }]);
    });

    test("getSecretValue returns the stored value", () => {
        const store = memoryStore();
        addSecret(store, secret("api", "api-key"), "the-value");
        expect(getSecretValue(store, "api")).toBe("the-value");
        expect(getSecretValue(store, "missing")).toBeUndefined();
    });

    test("addSecret throws the exact duplicate-name message", () => {
        const store = memoryStore();
        addSecret(store, secret("dup", "api-key"), "v1");
        expect(() => addSecret(store, secret("dup", "api-key"), "v2"))
            .toThrow("A secret named 'dup' already exists.");
    });

    test("updateSecret replaces the entry and keeps the value when none is given", () => {
        const store = memoryStore();
        addSecret(store, secret("old", "api-key"), "v1");
        updateSecret(store, "old", secret("renamed", "api-key"));
        expect(listSecrets(store)).toEqual([{ name: "renamed", type: "api-key" }]);
        expect(getSecretValue(store, "renamed")).toBe("v1");
    });

    test("updateSecret updates the value when one is given", () => {
        const store = memoryStore();
        addSecret(store, secret("api", "api-key"), "v1");
        updateSecret(store, "api", secret("api", "api-key"), "v2");
        expect(getSecretValue(store, "api")).toBe("v2");
    });

    test("deleteSecret removes the secret", () => {
        const store = memoryStore();
        addSecret(store, secret("api", "api-key"), "v1");
        deleteSecret(store, "api");
        expect(listSecrets(store)).toEqual([]);
    });

    test("resetConfig clears secrets", () => {
        const store = memoryStore();
        addSecret(store, secret("api", "api-key"), "v1");
        resetConfig(store);
        expect(listSecrets(store)).toEqual([]);
    });

    test("seedSecrets replaces the secrets list wholesale", () => {
        const store = memoryStore();
        addSecret(store, secret("old", "api-key"), "v1");
        seedSecrets(store, [{ entry: { name: "seeded", type: "api-key" }, value: "sv" }]);
        expect(listSecrets(store)).toEqual([{ name: "seeded", type: "api-key" }]);
        expect(getSecretValue(store, "seeded")).toBe("sv");
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

    test("resetConfig clears news and shown ids", () => {
        const store = memoryStore();
        seedNews(store, [{ id: "n1", message: "first" }]);
        addShownNewsId(store, "n0");
        resetConfigForNews(store);
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

    test("addRecentDatabase de-duplicates by path and moves to the front", () => {
        const store = memoryStore();
        addRecentDatabase(store, entry("Alpha", "a"));
        addRecentDatabase(store, entry("Beta", "b"));
        addRecentDatabase(store, entry("Alpha", "a"));
        expect(getRecentDatabases(store).map(database => database.path)).toEqual(["a", "b"]);
    });

    test("removeRecentDatabase removes by name", () => {
        const store = memoryStore();
        addRecentDatabase(store, entry("Alpha", "a"));
        addRecentDatabase(store, entry("Beta", "b"));
        removeRecentDatabase(store, "Alpha");
        expect(getRecentDatabases(store).map(database => database.name)).toEqual(["Beta"]);
    });

    test("seedRecentDatabases replaces the recent list", () => {
        const store = memoryStore();
        addRecentDatabase(store, entry("Old", "o"));
        seedRecentDatabases(store, [entry("Seed", "s")]);
        expect(getRecentDatabases(store).map(database => database.name)).toEqual(["Seed"]);
    });
});
