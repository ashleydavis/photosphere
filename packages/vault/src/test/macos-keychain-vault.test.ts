import { MacOSKeychainVault } from "../lib/macos-keychain-vault";
import { ISecret } from "../lib/vault";
import * as keychainTypes from "../lib/keychain-types";

//
// In-memory map used as the fake macOS security-tool backend.
//
type SecretStore = Map<string, string>;

//
// Builds a mock implementation of runCommand backed by an in-memory store.
// The dump-keychain subcommand emits output in the real security(1) format so
// that parseKeychainDump() exercises the same code path as production.
//
function makeRunCommandMock(store: SecretStore): jest.SpyInstance {
    return jest.spyOn(keychainTypes, "runCommand").mockImplementation(async (args: string[]) => {
        const tool = args[0];
        if (tool !== "/usr/bin/security") {
            throw new Error(`Unexpected command: ${args.join(" ")}`);
        }

        const subcommand = args[1];

        if (subcommand === "version") {
            return "security-2375 (SecureTransport-59754.140.13)";
        }

        if (subcommand === "add-generic-password") {
            // args: security add-generic-password -U -s photosphere -a <name> -w <json>
            const accountIndex = args.indexOf("-a");
            const passwordIndex = args.indexOf("-w");
            const keychainName = args[accountIndex + 1];
            const json = args[passwordIndex + 1];
            store.set(keychainName, json);
            return "";
        }

        if (subcommand === "find-generic-password") {
            // args: security find-generic-password -s photosphere -a <name> -w
            const accountIndex = args.indexOf("-a");
            const keychainName = args[accountIndex + 1];
            const raw = store.get(keychainName);
            if (raw === undefined) {
                throw new Error("SecKeychainSearchCopyNext: The specified item could not be found in the keychain.");
            }
            return raw;
        }

        if (subcommand === "delete-generic-password") {
            // args: security delete-generic-password -s photosphere -a <name>
            const accountIndex = args.indexOf("-a");
            const keychainName = args[accountIndex + 1];
            store.delete(keychainName);
            return "";
        }

        if (subcommand === "dump-keychain") {
            // Emit one block per store entry in real security dump-keychain format.
            const blocks: string[] = [];
            for (const [keychainName] of store.entries()) {
                blocks.push(
                    `keychain: "/Users/test/Library/Keychains/login.keychain-db"\n` +
                    `version: 512\n` +
                    `class: "genp"\n` +
                    `attributes:\n` +
                    `    "acct"<blob>="${keychainName}"\n` +
                    `    "svce"<blob>="photosphere"\n`
                );
            }
            return blocks.join("\n");
        }

        throw new Error(`Unexpected security subcommand: ${subcommand}`);
    });
}

describe("MacOSKeychainVault", () => {
    let store: SecretStore;
    let runCommandSpy: jest.SpyInstance;
    let vault: MacOSKeychainVault;

    beforeEach(() => {
        store = new Map();
        runCommandSpy = makeRunCommandMock(store);
        vault = new MacOSKeychainVault();
    });

    afterEach(() => {
        runCommandSpy.mockRestore();
    });

    describe("get", () => {
        test("returns undefined for a missing secret", async () => {
            const result = await vault.get("missing");
            expect(result).toBeUndefined();
        });

        test("returns the secret after set", async () => {
            const secret: ISecret = { name: "my-key", type: "api-key", value: "abc123" };
            await vault.set(secret);
            const result = await vault.get("my-key");
            expect(result).toEqual(secret);
        });
    });

    describe("set", () => {
        test("stores name, type, and value correctly", async () => {
            await vault.set({ name: "s3key", type: "s3-credentials", value: "creds" });
            const result = await vault.get("s3key");
            expect(result?.name).toBe("s3key");
            expect(result?.type).toBe("s3-credentials");
            expect(result?.value).toBe("creds");
        });

        test("does not duplicate entry on overwrite", async () => {
            await vault.set({ name: "dup", type: "plain", value: "v1" });
            await vault.set({ name: "dup", type: "plain", value: "v2" });
            const secrets = await vault.list();
            const names = secrets.map((secret: ISecret) => secret.name);
            expect(names.filter((n: string) => n === "dup")).toHaveLength(1);
        });
    });

    describe("list", () => {
        test("returns empty array when no secrets exist", async () => {
            const result = await vault.list();
            expect(result).toEqual([]);
        });

        test("returns all stored secrets", async () => {
            await vault.set({ name: "a", type: "plain", value: "1" });
            await vault.set({ name: "b", type: "plain", value: "2" });
            const result = await vault.list();
            const names = result.map((secret: ISecret) => secret.name).sort();
            expect(names).toEqual(["a", "b"]);
        });

        test("excludes entries from other services", async () => {
            // Inject a non-photosphere entry directly into the raw store with a
            // different service so dump-keychain would surface it — list() must ignore it.
            store.set("other-service-key", '{"type":"plain","value":"x"}');
            const result = await vault.list();
            expect(result).toEqual([]);
        });
    });

    describe("delete", () => {
        test("removes the secret (subsequent get returns undefined)", async () => {
            await vault.set({ name: "temp", type: "plain", value: "val" });
            await vault.delete("temp");
            const result = await vault.get("temp");
            expect(result).toBeUndefined();
        });

        test("no longer appears in list after delete", async () => {
            await vault.set({ name: "gone", type: "plain", value: "v" });
            await vault.delete("gone");
            const secrets = await vault.list();
            expect(secrets).toHaveLength(0);
        });

        test("does nothing when the secret does not exist", async () => {
            await expect(vault.delete("nonexistent")).resolves.toBeUndefined();
        });
    });

    describe("psi- prefix", () => {
        test("adds psi- prefix on write and strips it on read", async () => {
            await vault.set({ name: "mykey", type: "plain", value: "v" });
            expect(store.has("psi-mykey")).toBe(true);
            const result = await vault.get("mykey");
            expect(result?.name).toBe("mykey");
        });
    });

    describe("special characters", () => {
        test("handles names with colons", async () => {
            const secret: ISecret = { name: "shared:s3test01", type: "s3-credentials", value: "data" };
            await vault.set(secret);
            const result = await vault.get("shared:s3test01");
            expect(result).toEqual(secret);
        });

        test("handles names with slashes", async () => {
            const secret: ISecret = { name: "cli/key/one", type: "plain", value: "x" };
            await vault.set(secret);
            const result = await vault.get("cli/key/one");
            expect(result).toEqual(secret);
        });
    });
});
