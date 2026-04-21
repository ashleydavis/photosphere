import { WindowsKeychainVault } from "../lib/windows-keychain-vault";
import { ISecret } from "../lib/vault";
import * as keychainTypes from "../lib/keychain-types";

//
// In-memory map used as the fake Windows Credential Vault backend.
//
type SecretStore = Map<string, string>;

//
// Builds a mock implementation of runCommand that simulates PowerShell
// PasswordVault calls backed by an in-memory store.
//
function makeRunCommandMock(store: SecretStore): jest.SpyInstance {
    return jest.spyOn(keychainTypes, "runCommand").mockImplementation(async (args: string[]) => {
        if (args[0] !== "powershell") {
            throw new Error(`Unexpected command: ${args.join(" ")}`);
        }

        const script = args[args.length - 1];

        if (script.includes("PSVersionTable")) {
            return "5.1.0";
        }

        if (script.includes("Retrieve(") && script.includes("Write-Output $cred.Password")) {
            // get
            const match = script.match(/Retrieve\('[^']+',\s*'([^']+)'\)/);
            const keychainName = match ? match[1] : "";
            const raw = store.get(keychainName);
            if (raw === undefined) {
                throw new Error("Object reference not set to an instance of an object.");
            }
            return raw;
        }

        if (script.includes("PasswordCredential(")) {
            // set
            const resourceMatch = script.match(/PasswordCredential\('([^']+)',\s*'([^']+)',\s*'([^']+)'\)/);
            if (resourceMatch) {
                const keychainName = resourceMatch[2];
                const json = resourceMatch[3].replace(/''/g, "'");
                store.set(keychainName, json);
            }
            return "";
        }

        if (script.includes("FindAllByResource(") && script.includes("Write-Output $cred.UserName")) {
            // list
            const lines: string[] = [];
            for (const keychainName of store.keys()) {
                lines.push(keychainName);
            }
            return lines.join("\n");
        }

        if (script.includes("Retrieve(") && script.includes("$vault.Remove(")) {
            // delete
            const match = script.match(/Retrieve\('[^']+',\s*'([^']+)'\)/);
            const keychainName = match ? match[1] : "";
            store.delete(keychainName);
            return "";
        }

        throw new Error(`Unrecognised PowerShell script: ${script.slice(0, 80)}`);
    });
}

describe("WindowsKeychainVault", () => {
    let store: SecretStore;
    let runCommandSpy: jest.SpyInstance;
    let vault: WindowsKeychainVault;

    beforeEach(() => {
        store = new Map();
        runCommandSpy = makeRunCommandMock(store);
        vault = new WindowsKeychainVault();
    });

    afterEach(() => {
        runCommandSpy.mockRestore();
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
