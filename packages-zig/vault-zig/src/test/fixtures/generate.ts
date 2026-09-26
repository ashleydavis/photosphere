//
// Generates the golden fixtures used by the Zig tests of vault-zig.
// Run with: bun run src/test/fixtures/generate.ts (from packages-zig/vault-zig).
//
// Writes secrets with the TypeScript PlaintextVault into ts-vault/vault.json so the Zig tests can check
// that Zig reads a vault file written by TypeScript, and that Zig writes a byte-identical vault file
// (which TypeScript therefore reads back unchanged).
//
import * as fs from "fs";
import * as path from "path";
import { PlaintextVault, getVaultFilePath } from "../../../../../packages/vault/src/lib/plaintext-vault";
import { ISecret } from "../../../../../packages/vault/src/lib/vault";

//
// Secrets with names and values that exercise JSON string escaping and the key order of a
// JavaScript object (names that are array indexes come first, in numeric order).
//
const secrets: ISecret[] = [
    { name: "default:s3", type: "s3-credentials", value: JSON.stringify({ region: "us-east-1", accessKeyId: "AKIA", secretAccessKey: "x/y+z", endpoint: "https://s3.example.com" }) },
    { name: "my-photos", type: "encryption-key", value: "-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBg==\n-----END PRIVATE KEY-----\n" },
    { name: "my secret", type: "password", value: "spaced" },
    { name: "42", type: "password", value: "an array index name" },
    { name: "org/repo/token", type: "api-key", value: "tok" },
    { name: "clé-secrète", type: "password", value: "motdepasse" },
    { name: "7", type: "password", value: "a smaller array index name" },
    { name: "007", type: "password", value: "not an array index name" },
    { name: "a%2Fb", type: "password", value: "percent" },
    { name: "Weird_Name.!~'()", type: "plain", value: "quote \" backslash \\ tab \t cr \r bell \u0007 del \u007f" },
    { name: "emoji-😀", type: "plain", value: "unicode é ü 中文 😀    " },
    { name: "empty", type: "", value: "" },
];

async function main(): Promise<void> {
    const vaultDir = path.join(__dirname, "ts-vault");
    fs.rmSync(getVaultFilePath(vaultDir), { force: true });
    const vault = new PlaintextVault(vaultDir);
    for (const secret of secrets) {
        await vault.set(secret);
    }
    fs.writeFileSync(path.join(__dirname, "secrets.json"), JSON.stringify(secrets, null, 4) + "\n");
}

main();
