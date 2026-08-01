//
// Writes one plaintext-vault secret file, the JSON envelope the vault stores a secret in.
//
// Smoke tests use this to seed a vault from outside the app, the way a test establishes state on
// disk rather than asking the app to do it. There is no shell answer, because the value is frequently
// a multi-line PEM and getting JSON string escaping right in shell is exactly the kind of thing that
// silently produces a file the app cannot parse.
//
// The file written matches what packages/vault produces: an object with name, type and value, where
// value is always a string. For an s3-credentials secret that string is itself JSON, so pass the
// already-encoded JSON as --value.
//
// Usage:
//   bun scripts/write-vault-secret.ts --file <path> --name <name> --type <type> --value <string>
//   bun scripts/write-vault-secret.ts --file <path> --name <name> --type <type> --value-file <path>
//
// --value-file reads the value from a file verbatim, newlines and all, which is how a PEM gets in.
//

import { readFileSync, writeFileSync } from "node:fs";

//
// The secret envelope as the vault stores it on disk.
//
interface IVaultSecret {
    // The secret's name, which is also how the app looks it up.
    name: string;

    // The secret's type, for example "encryption-key", "api-key" or "s3-credentials".
    type: string;

    // The secret's value, always a string. For s3-credentials it is itself a JSON document.
    value: string;
}

//
// Reads a required `--name value` argument, failing loudly and naming it when absent.
//
function requiredArg(argv: string[], name: string): string {
    const index = argv.indexOf(`--${name}`);
    if (index === -1 || index + 1 >= argv.length) {
        throw new Error(`Missing required argument --${name}`);
    }
    return argv[index + 1];
}

//
// Reads an optional `--name value` argument, returning undefined when it is not present.
//
function optionalArg(argv: string[], name: string): string | undefined {
    const index = argv.indexOf(`--${name}`);
    if (index === -1 || index + 1 >= argv.length) {
        return undefined;
    }
    return argv[index + 1];
}

//
// Resolves the secret's value from either --value or --value-file, requiring exactly one of them.
//
function resolveValue(argv: string[]): string {
    const inlineValue = optionalArg(argv, "value");
    const valueFile = optionalArg(argv, "value-file");
    if (inlineValue !== undefined && valueFile !== undefined) {
        throw new Error("Pass either --value or --value-file, not both.");
    }
    if (inlineValue !== undefined) {
        return inlineValue;
    }
    if (valueFile !== undefined) {
        return readFileSync(valueFile, "utf8");
    }
    throw new Error("Missing required argument --value or --value-file");
}

const argv = process.argv.slice(2);
const secret: IVaultSecret = {
    name: requiredArg(argv, "name"),
    type: requiredArg(argv, "type"),
    value: resolveValue(argv),
};
writeFileSync(requiredArg(argv, "file"), JSON.stringify(secret));
