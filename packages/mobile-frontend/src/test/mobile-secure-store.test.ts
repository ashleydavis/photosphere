import {
    MobileSecretStore,
    ISecureStore,
    SECRET_VALUE_KEY_PREFIX,
    SECRET_TYPE_KEY_PREFIX,
    secretValueKey,
    secretTypeKey,
} from "../lib/mobile-secure-store";
import type { ISharedSecretEntry } from "user-interface";

//
// An in-memory fake of the device keychain implementing ISecureStore. Exposes its backing map so a test
// can inspect exactly which keychain items exist and what they hold, and counts reads per key so a test
// can prove listing never reads a secret value.
//
class FakeSecureStore implements ISecureStore {

    //
    // The durable keychain contents, one entry per keychain item. Public so tests can assert on the exact
    // set of items written.
    //
    readonly backing: Map<string, string> = new Map();

    //
    // How many times each key has been read, so a test can assert a value key was never touched.
    //
    readonly readCounts: Map<string, number> = new Map();

    //
    // Keys whose next operation should throw, used to test partial-failure ordering.
    //
    readonly failingKeys: Set<string> = new Set();

    async get(key: string): Promise<string | null> {
        this.readCounts.set(key, (this.readCounts.get(key) ?? 0) + 1);
        if (this.failingKeys.has(key)) {
            throw new Error(`Simulated keychain read failure for '${key}'.`);
        }
        return this.backing.has(key) ? this.backing.get(key)! : null;
    }

    async set(key: string, value: string): Promise<void> {
        if (this.failingKeys.has(key)) {
            throw new Error(`Simulated keychain write failure for '${key}'.`);
        }
        this.backing.set(key, value);
    }

    async delete(key: string): Promise<void> {
        this.backing.delete(key);
    }

    async keys(): Promise<string[]> {
        return Array.from(this.backing.keys());
    }
}

//
// Builds a secret entry for the tests.
//
function secretEntry(name: string, type: string): ISharedSecretEntry {
    return { name, type };
}

describe("mobile secret store", () => {

    test("addSecret stores the value and the type in separate keychain items", async () => {
        const keychain = new FakeSecureStore();
        const store = new MobileSecretStore(keychain);

        await store.addSecret(secretEntry("api", "api-key"), "the-value");

        expect(keychain.backing.get(`${SECRET_VALUE_KEY_PREFIX}api`)).toBe("the-value");
        expect(keychain.backing.get(`${SECRET_TYPE_KEY_PREFIX}api`)).toBe("api-key");
    });

    test("each secret occupies its own keychain items, never a combined blob", async () => {
        const keychain = new FakeSecureStore();
        const store = new MobileSecretStore(keychain);

        await store.addSecret(secretEntry("first", "api-key"), "value-one");
        await store.addSecret(secretEntry("second", "encryption-key"), "value-two");

        expect(Array.from(keychain.backing.keys()).sort()).toEqual([
            `${SECRET_TYPE_KEY_PREFIX}first`,
            `${SECRET_TYPE_KEY_PREFIX}second`,
            `${SECRET_VALUE_KEY_PREFIX}first`,
            `${SECRET_VALUE_KEY_PREFIX}second`,
        ]);

        // No stored item contains more than the one secret it belongs to.
        expect(keychain.backing.get(`${SECRET_VALUE_KEY_PREFIX}first`)).toBe("value-one");
        expect(keychain.backing.get(`${SECRET_VALUE_KEY_PREFIX}first`)).not.toContain("value-two");
    });

    test("listSecrets returns the entries without reading any secret value", async () => {
        const keychain = new FakeSecureStore();
        const store = new MobileSecretStore(keychain);
        await store.addSecret(secretEntry("api", "api-key"), "the-value");
        await store.addSecret(secretEntry("s3", "s3-credentials"), "{}");
        keychain.readCounts.clear();

        const entries = await store.listSecrets();

        expect(entries.sort((left, right) => left.name.localeCompare(right.name))).toEqual([
            { name: "api", type: "api-key" },
            { name: "s3", type: "s3-credentials" },
        ]);
        expect(keychain.readCounts.get(secretValueKey("api"))).toBeUndefined();
        expect(keychain.readCounts.get(secretValueKey("s3"))).toBeUndefined();
    });

    test("getSecretValue reads the keychain on every call and caches nothing", async () => {
        const keychain = new FakeSecureStore();
        const store = new MobileSecretStore(keychain);
        await store.addSecret(secretEntry("api", "api-key"), "the-value");

        expect(await store.getSecretValue("api")).toBe("the-value");

        // A change made behind the store's back is seen immediately, which is only true with no cache.
        keychain.backing.set(secretValueKey("api"), "changed-underneath");
        expect(await store.getSecretValue("api")).toBe("changed-underneath");

        // And a value removed behind its back reads as absent rather than from a stale cache.
        keychain.backing.delete(secretValueKey("api"));
        expect(await store.getSecretValue("api")).toBeUndefined();
    });

    test("getSecretValue returns undefined for a secret that is not stored", async () => {
        const store = new MobileSecretStore(new FakeSecureStore());

        expect(await store.getSecretValue("missing")).toBeUndefined();
    });

    test("addSecret throws the exact duplicate-name message", async () => {
        const store = new MobileSecretStore(new FakeSecureStore());
        await store.addSecret(secretEntry("dup", "api-key"), "v1");

        await expect(store.addSecret(secretEntry("dup", "api-key"), "v2"))
            .rejects.toThrow("A secret named 'dup' already exists.");
    });

    test("updateSecret changes the value in place, leaving the type untouched", async () => {
        const keychain = new FakeSecureStore();
        const store = new MobileSecretStore(keychain);
        await store.addSecret(secretEntry("api", "api-key"), "v1");

        await store.updateSecret("api", secretEntry("api", "api-key"), "v2");

        expect(await store.getSecretValue("api")).toBe("v2");
        expect(keychain.backing.get(secretTypeKey("api"))).toBe("api-key");
    });

    test("updateSecret keeps the existing value when none is given", async () => {
        const store = new MobileSecretStore(new FakeSecureStore());
        await store.addSecret(secretEntry("api", "api-key"), "v1");

        await store.updateSecret("api", secretEntry("api", "encryption-key"));

        expect(await store.listSecrets()).toEqual([{ name: "api", type: "encryption-key" }]);
        expect(await store.getSecretValue("api")).toBe("v1");
    });

    test("updateSecret renames both keychain items and leaves nothing behind", async () => {
        const keychain = new FakeSecureStore();
        const store = new MobileSecretStore(keychain);
        await store.addSecret(secretEntry("old", "api-key"), "v1");

        await store.updateSecret("old", secretEntry("renamed", "api-key"));

        expect(await store.listSecrets()).toEqual([{ name: "renamed", type: "api-key" }]);
        expect(await store.getSecretValue("renamed")).toBe("v1");
        expect(keychain.backing.has(secretValueKey("old"))).toBe(false);
        expect(keychain.backing.has(secretTypeKey("old"))).toBe(false);
    });

    test("updateSecret renames and replaces the value in one call", async () => {
        const keychain = new FakeSecureStore();
        const store = new MobileSecretStore(keychain);
        await store.addSecret(secretEntry("old", "api-key"), "v1");

        await store.updateSecret("old", secretEntry("renamed", "api-key"), "v2");

        expect(await store.getSecretValue("renamed")).toBe("v2");
        expect(keychain.backing.has(secretValueKey("old"))).toBe(false);
    });

    test("updateSecret throws rather than silently losing a rename with no stored value", async () => {
        const store = new MobileSecretStore(new FakeSecureStore());

        await expect(store.updateSecret("ghost", secretEntry("renamed", "api-key")))
            .rejects.toThrow("Cannot rename the secret 'ghost' to 'renamed': the device keychain holds no value for it.");
    });

    test("deleteSecret removes both of the secret's keychain items and no others", async () => {
        const keychain = new FakeSecureStore();
        const store = new MobileSecretStore(keychain);
        await store.addSecret(secretEntry("gone", "api-key"), "v1");
        await store.addSecret(secretEntry("kept", "api-key"), "v2");

        await store.deleteSecret("gone");

        expect(await store.listSecrets()).toEqual([{ name: "kept", type: "api-key" }]);
        expect(keychain.backing.has(secretValueKey("gone"))).toBe(false);
        expect(keychain.backing.has(secretTypeKey("gone"))).toBe(false);
        expect(keychain.backing.get(secretValueKey("kept"))).toBe("v2");
    });

    test("a failed value write leaves the secret unlisted rather than listed with no value", async () => {
        const keychain = new FakeSecureStore();
        const store = new MobileSecretStore(keychain);
        keychain.failingKeys.add(secretValueKey("api"));

        await expect(store.addSecret(secretEntry("api", "api-key"), "v1")).rejects.toThrow();

        expect(await store.listSecrets()).toEqual([]);
    });

    test("clearSecrets removes every secret item and leaves unrelated keychain items alone", async () => {
        const keychain = new FakeSecureStore();
        const store = new MobileSecretStore(keychain);
        await store.addSecret(secretEntry("api", "api-key"), "v1");
        await store.addSecret(secretEntry("s3", "s3-credentials"), "{}");
        keychain.backing.set("something.else", "not-a-secret");

        await store.clearSecrets();

        expect(await store.listSecrets()).toEqual([]);
        expect(Array.from(keychain.backing.keys())).toEqual(["something.else"]);
    });

    test("a secret name containing the type prefix does not confuse the enumeration", async () => {
        const store = new MobileSecretStore(new FakeSecureStore());

        // A name that embeds the other prefix would break any scheme that split keys on a separator.
        await store.addSecret(secretEntry("photosphere.secret-type.tricky", "api-key"), "v1");

        expect(await store.listSecrets()).toEqual([{ name: "photosphere.secret-type.tricky", type: "api-key" }]);
        expect(await store.getSecretValue("photosphere.secret-type.tricky")).toBe("v1");
    });
});
