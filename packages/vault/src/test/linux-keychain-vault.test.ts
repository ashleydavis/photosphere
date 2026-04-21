import { LinuxKeychainVault } from "../lib/linux-keychain-vault";
import { ISecret } from "../lib/vault";
import * as keychainTypes from "../lib/keychain-types";

//
// In-memory map used as the fake secret-tool backend.
//
type SecretStore = Map<string, string>;

//
// Builds a mock implementation of runCommand backed by an in-memory store.
// Also stubs the stdin-based store path used internally.
//
function makeRunCommandMock(store: SecretStore): jest.SpyInstance {
    return jest.spyOn(keychainTypes, "runCommand").mockImplementation(async (args: string[]) => {
        const tool = args[0];

        if (tool === "which") {
            // which secret-tool — return a fake path to indicate it is available.
            return "/usr/bin/secret-tool";
        }

        if (tool !== "secret-tool") {
            throw new Error(`Unexpected command: ${args.join(" ")}`);
        }

        const subcommand = args[1];

        if (subcommand === "--version") {
            return "secret-tool 0.20.4";
        }

        if (subcommand === "lookup") {
            // args: secret-tool lookup service photosphere account <keychainName>
            const keychainName = args[5];
            const raw = store.get(keychainName);
            if (raw === undefined) {
                throw new Error("No such secret");
            }
            return raw;
        }

        if (subcommand === "clear") {
            // args: secret-tool clear service photosphere account <keychainName>
            const keychainName = args[5];
            store.delete(keychainName);
            return "";
        }

        throw new Error(`Unexpected secret-tool subcommand: ${subcommand}`);
    });
}

//
// Patches child_process.spawn to handle both `secret-tool store` (stdin-based)
// and `secret-tool search` (stderr-based) using the in-memory store.
//
function makeSpawnStub(store: SecretStore): jest.SpyInstance {
    const cp = require("child_process");
    return jest.spyOn(cp, "spawn").mockImplementation((...spawnArgs: any[]) => {
        const args: string[] = spawnArgs[1];

        if (args.indexOf("store") !== -1) {
            // secret-tool store: read JSON from stdin, save to store.
            const labelArg = args.find((arg: string) => arg.startsWith("--label="));
            const keychainName = labelArg ? labelArg.slice("--label=".length) : "";

            const chunks: Buffer[] = [];
            let closeCb: (code: number) => void = () => {};

            const stdinMock = {
                write: (data: string) => {
                    chunks.push(Buffer.from(data, "utf8"));
                },
                end: () => {
                    const json = Buffer.concat(chunks).toString("utf8");
                    store.set(keychainName, json);
                    process.nextTick(() => {
                        closeCb(0);
                    });
                },
            };

            return {
                stdin: stdinMock,
                stdout: { on: () => {} },
                stderr: { on: () => {} },
                on: (event: string, cb: (code: number) => void) => {
                    if (event === "close") {
                        closeCb = cb;
                    }
                },
            };
        }

        if (args.indexOf("search") !== -1) {
            // secret-tool search: emit attribute lines via stderr (matches real behaviour).
            const stderrCallbacks: Map<string, (chunk: Buffer) => void> = new Map();
            let closeCb: (code: number) => void = () => {};

            process.nextTick(() => {
                const dataCallback = stderrCallbacks.get("data");
                if (dataCallback) {
                    for (const keychainName of store.keys()) {
                        dataCallback(Buffer.from(`attribute.service = photosphere\n`, "utf8"));
                        dataCallback(Buffer.from(`attribute.account = ${keychainName}\n`, "utf8"));
                    }
                }
                closeCb(0);
            });

            return {
                stdin: { write: () => {}, end: () => {} },
                stdout: { on: () => {} },
                stderr: {
                    on: (event: string, cb: (chunk: Buffer) => void) => {
                        stderrCallbacks.set(event, cb);
                    },
                },
                on: (event: string, cb: (code: number) => void) => {
                    if (event === "close") {
                        closeCb = cb;
                    }
                },
            };
        }

        throw new Error(`Unexpected spawn call: ${spawnArgs[0]} ${args.join(" ")}`);
    });
}

describe("LinuxKeychainVault", () => {
    let store: SecretStore;
    let runCommandSpy: jest.SpyInstance;
    let spawnSpy: jest.SpyInstance;
    let vault: LinuxKeychainVault;

    beforeEach(() => {
        store = new Map();
        runCommandSpy = makeRunCommandMock(store);
        spawnSpy = makeSpawnStub(store);
        vault = new LinuxKeychainVault();
        // Reset the module-level toolChecked flag between tests by creating a
        // fresh vault instance; the flag is module-level so reset via jest isolation.
    });

    afterEach(() => {
        runCommandSpy.mockRestore();
        spawnSpy.mockRestore();
        jest.resetModules();
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
    });

    describe("delete", () => {
        test("removes the secret (subsequent get returns undefined)", async () => {
            await vault.set({ name: "temp", type: "plain", value: "val" });
            await vault.delete("temp");
            const result = await vault.get("temp");
            expect(result).toBeUndefined();
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
    });
});
