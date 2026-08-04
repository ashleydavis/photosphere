import * as os from "os";
import * as path from "path";
import * as fs from "fs/promises";
import { PlaintextVault } from "../lib/plaintext-vault";
import { ISecret } from "../lib/vault";

//
// Creates a unique temporary directory for each test so that tests are
// fully isolated from one another and from the real ~/.config/vault.
//
async function makeTempDir(): Promise<string> {
    return fs.mkdtemp(path.join(os.tmpdir(), "vault-test-"));
}

//
// Removes the temporary directory and all its contents after a test.
//
async function removeTempDir(dirPath: string): Promise<void> {
    await fs.rm(dirPath, { recursive: true, force: true });
}

describe("PlaintextVault", () => {
    let tempDir: string;
    let vault: PlaintextVault;

    beforeEach(async () => {
        tempDir = await makeTempDir();
        vault = new PlaintextVault(tempDir);
    });

    afterEach(async () => {
        await removeTempDir(tempDir);
    });

    describe("get", () => {
        test("returns undefined for a secret that does not exist", async () => {
            const result = await vault.get("nonexistent");
            expect(result).toBeUndefined();
        });

        test("returns the secret after it has been set", async () => {
            const secret: ISecret = { name: "my-key", type: "api-key", value: "abc123" };
            await vault.set(secret);
            const result = await vault.get("my-key");
            expect(result).toEqual(secret);
        });

        test("returns the latest value when a secret is overwritten", async () => {
            await vault.set({ name: "token", type: "api-key", value: "old-value" });
            await vault.set({ name: "token", type: "api-key", value: "new-value" });
            const result = await vault.get("token");
            expect(result?.value).toBe("new-value");
        });

        test("returns undefined when the vault file exists but holds no such name", async () => {
            await vault.set({ name: "present", type: "password", value: "here" });
            const result = await vault.get("absent");
            expect(result).toBeUndefined();
        });
    });

    describe("set", () => {
        test("creates the vault directory if it does not exist", async () => {
            const nestedDir = path.join(tempDir, "nested", "vault");
            const nestedVault = new PlaintextVault(nestedDir);
            await nestedVault.set({ name: "key", type: "password", value: "secret" });
            const result = await nestedVault.get("key");
            expect(result?.value).toBe("secret");
        });

        test("stores the name, type, and value of the secret", async () => {
            const secret: ISecret = { name: "db-pass", type: "password", value: "hunter2" };
            await vault.set(secret);
            const result = await vault.get("db-pass");
            expect(result?.name).toBe("db-pass");
            expect(result?.type).toBe("password");
            expect(result?.value).toBe("hunter2");
        });

        test("supports arbitrary type strings", async () => {
            const secret: ISecret = { name: "cred", type: "s3-credentials", value: '{"accessKeyId":"AKIA...","secretAccessKey":"xyz"}' };
            await vault.set(secret);
            const result = await vault.get("cred");
            expect(result?.type).toBe("s3-credentials");
        });

        test("creates the vault file when it does not exist yet", async () => {
            await vault.set({ name: "first", type: "password", value: "one" });
            const stats = await fs.stat(path.join(tempDir, "vault.json"));
            expect(stats.isFile()).toBe(true);
        });

        test("preserves the secrets already held in the vault file", async () => {
            await vault.set({ name: "first", type: "password", value: "one" });
            await vault.set({ name: "second", type: "api-key", value: "two" });
            await vault.set({ name: "third", type: "password", value: "three" });
            const first = await vault.get("first");
            const second = await vault.get("second");
            const third = await vault.get("third");
            expect(first?.value).toBe("one");
            expect(second?.value).toBe("two");
            expect(third?.value).toBe("three");
        });

        test("supports a key pair secret with both private and public key in the value", async () => {
            const keyPairValue = JSON.stringify({ privateKey: "-----BEGIN PRIVATE KEY-----", publicKey: "-----BEGIN PUBLIC KEY-----" });
            await vault.set({ name: "my-keypair", type: "key-pair", value: keyPairValue });
            const result = await vault.get("my-keypair");
            expect(result?.type).toBe("key-pair");
            const parsed = JSON.parse(result!.value);
            expect(parsed.privateKey).toBe("-----BEGIN PRIVATE KEY-----");
            expect(parsed.publicKey).toBe("-----BEGIN PUBLIC KEY-----");
        });
    });

    describe("list", () => {
        test("returns an empty array when the vault is empty", async () => {
            const secrets = await vault.list();
            expect(secrets).toEqual([]);
        });

        test("returns an empty array when the vault file does not exist", async () => {
            const emptyVault = new PlaintextVault(path.join(tempDir, "does-not-exist"));
            const secrets = await emptyVault.list();
            expect(secrets).toEqual([]);
        });

        test("returns all stored secrets", async () => {
            await vault.set({ name: "alpha", type: "password", value: "aaa" });
            await vault.set({ name: "beta", type: "api-key", value: "bbb" });
            const secrets = await vault.list();
            const names = secrets.map(secret => secret.name).sort();
            expect(names).toEqual(["alpha", "beta"]);
        });

        test("does not include deleted secrets", async () => {
            await vault.set({ name: "keep", type: "password", value: "keep-value" });
            await vault.set({ name: "remove", type: "password", value: "remove-value" });
            await vault.delete("remove");
            const secrets = await vault.list();
            expect(secrets).toHaveLength(1);
            expect(secrets[0].name).toBe("keep");
        });

        test("ignores a stray file sitting alongside the vault file", async () => {
            await vault.set({ name: "real", type: "api-key", value: "val" });
            // Write a stray file that should be ignored.
            await fs.writeFile(path.join(tempDir, "noise.txt"), "ignore me", "utf8");
            const secrets = await vault.list();
            expect(secrets).toHaveLength(1);
        });
    });

    describe("a malformed vault file", () => {
        //
        // Writes a vault file that is not valid JSON, so the vault has to
        // fail loudly rather than reporting an empty vault and then
        // overwriting whatever was really in there.
        //
        async function writeMalformedVaultFile(): Promise<void> {
            await fs.writeFile(path.join(tempDir, "vault.json"), "{ this is not json", "utf8");
        }

        test("makes get throw", async () => {
            await writeMalformedVaultFile();
            await expect(vault.get("anything")).rejects.toThrow();
        });

        test("makes list throw", async () => {
            await writeMalformedVaultFile();
            await expect(vault.list()).rejects.toThrow();
        });
    });

    describe("delete", () => {
        test("removes a secret so that get returns undefined afterwards", async () => {
            await vault.set({ name: "gone", type: "password", value: "byebye" });
            await vault.delete("gone");
            const result = await vault.get("gone");
            expect(result).toBeUndefined();
        });

        test("does nothing when the secret does not exist", async () => {
            await expect(vault.delete("no-such-secret")).resolves.toBeUndefined();
        });
    });

    describe("secret names with special characters", () => {
        test("handles names containing spaces", async () => {
            await vault.set({ name: "my secret", type: "password", value: "spaced" });
            const result = await vault.get("my secret");
            expect(result?.value).toBe("spaced");
        });

        test("handles names containing slashes", async () => {
            await vault.set({ name: "org/repo/token", type: "api-key", value: "tok" });
            const result = await vault.get("org/repo/token");
            expect(result?.value).toBe("tok");
        });

        test("handles names containing unicode characters", async () => {
            await vault.set({ name: "clé-secrète", type: "password", value: "motdepasse" });
            const result = await vault.get("clé-secrète");
            expect(result?.value).toBe("motdepasse");
        });

        test("handles multiple specially named secrets without collision", async () => {
            await vault.set({ name: "a/b", type: "password", value: "slash" });
            await vault.set({ name: "a%2Fb", type: "password", value: "percent" });
            const slash = await vault.get("a/b");
            const percent = await vault.get("a%2Fb");
            expect(slash?.value).toBe("slash");
            expect(percent?.value).toBe("percent");
        });
    });

    describe("file permissions", () => {
        // Permission checks are only meaningful on POSIX platforms.
        const isWindows = process.platform === "win32";

        test("vault file is created with owner-only permissions (0o600)", async () => {
            if (isWindows) {
                return;
            }
            await vault.set({ name: "perm-test", type: "password", value: "s3cr3t" });
            const filePath = path.join(tempDir, "vault.json");
            const stats = await fs.stat(filePath);
            const mode = stats.mode & 0o777;
            expect(mode).toBe(0o600);
        });

        test("vault directory is created with owner-only permissions (0o700)", async () => {
            if (isWindows) {
                return;
            }
            const newVaultDir = path.join(tempDir, "new-vault");
            const newVault = new PlaintextVault(newVaultDir);
            await newVault.set({ name: "key", type: "password", value: "val" });
            const stats = await fs.stat(newVaultDir);
            const mode = stats.mode & 0o777;
            expect(mode).toBe(0o700);
        });
    });

    describe("exists", () => {
        test("returns false before any secrets are stored", () => {
            const freshVault = new PlaintextVault(path.join(tempDir, "fresh"));
            expect(freshVault.exists()).toBe(false);
        });

        test("returns false when the vault directory exists but holds no vault file", () => {
            expect(vault.exists()).toBe(false);
        });

        test("returns true after a secret has been stored", async () => {
            await vault.set({ name: "anything", type: "password", value: "val" });
            expect(vault.exists()).toBe(true);
        });
    });
});
