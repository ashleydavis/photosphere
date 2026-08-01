//
// Prints a JSON-encoded form of a string, for building a JSON document from a shell script.
//
// There is no shell answer: escaping a string for JSON by hand gets quotes, backslashes and newlines
// wrong, and the strings these callers pass are frequently multi-line PEMs, which is precisely the
// case hand-rolled escaping breaks on.
//
// Two modes, because the callers need two shapes:
//
//   --string      prints the value as a JSON string, quotes included, for example "a\nb"
//   --url-segment prints the value encoded with encodeURIComponent, which is exactly how
//                 packages/vault names its files (see plaintext-vault.ts). Anything else and the
//                 app looks for a file the test did not write.
//
// The value comes from a file rather than an argument so a multi-line value cannot be mangled by the
// shell on its way in. Pass - to read standard input.
//
// Usage:
//   bun scripts/json-encode.ts --string <file|->
//   bun scripts/json-encode.ts --url-segment <file|->
//

import { readFileSync } from "node:fs";

//
// Reads the value to encode, from a file path or from standard input when the path is "-".
//
function readValue(source: string): string {
    return readFileSync(source === "-" ? 0 : source, "utf8");
}

const argv = process.argv.slice(2);
const stringIndex = argv.indexOf("--string");
const urlSegmentIndex = argv.indexOf("--url-segment");

if (stringIndex !== -1 && stringIndex + 1 < argv.length) {
    process.stdout.write(JSON.stringify(readValue(argv[stringIndex + 1])));
}
else if (urlSegmentIndex !== -1 && urlSegmentIndex + 1 < argv.length) {
    process.stdout.write(encodeURIComponent(readValue(argv[urlSegmentIndex + 1])));
}
else {
    throw new Error("Usage: bun scripts/json-encode.ts (--string | --url-segment) <file|->");
}
