//
// Prints one top-level field of a JSON file to stdout, verbatim and with no trailing newline.
//
// Smoke tests use this to assert on files the app wrote. There is no shell answer, because parsing
// JSON with grep or sed gets the escaping wrong the moment a value contains a quote or a newline, and
// the values these tests care about are frequently multi-line PEMs.
//
// No trailing newline is deliberate: the caller usually captures this in `$(...)`, which strips
// trailing newlines, so a value whose own trailing newline matters has to be compared by writing this
// to a file and using `cmp` rather than by comparing shell strings.
//
// Exits 1 without printing when the field is absent, so a caller can test for absence with the exit
// code rather than by comparing against an empty string.
//
// Usage: bun scripts/read-json-field.ts --file <path> --field <name>
//

import { readFileSync } from "node:fs";

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

const argv = process.argv.slice(2);
const filePath = requiredArg(argv, "file");
const fieldName = requiredArg(argv, "field");

const document = JSON.parse(readFileSync(filePath, "utf8"));
if (!Object.prototype.hasOwnProperty.call(document, fieldName)) {
    process.exit(1);
}

const fieldValue = document[fieldName];
process.stdout.write(typeof fieldValue === "string" ? fieldValue : JSON.stringify(fieldValue));
