//
// Prints one field out of a database's binary state file, `.db/state.dat`.
//
// Smoke test 64 asserts the config timestamps the app writes, and the only way to see them is to
// decode the binary record. There is no shell answer: this reads little-endian length-prefixed fields
// out of a binary buffer, which shell cannot do.
//
// The layout, from offset 0: 4 bytes of header, the ASCII marker "DBST" at offset 4, then from
// offset 8 a sequence of length-prefixed fields, each a 4-byte little-endian length followed by that
// many bytes. In order: contentHash (raw bytes), lastModifiedAt, lastSyncedAt, lastReplicatedAt
// (each UTF-8 text).
//
// Prints nothing and exits 0 when the file is missing or is not a state file, because the caller
// treats "no value" as a legitimate result rather than an error.
//
// Usage: bun scripts/read-database-state-field.ts --file <path to state.dat> --field <name>
//

import { existsSync, readFileSync } from "node:fs";

//
// The text fields the state file carries, in the order they appear after the content hash.
//
const TEXT_FIELD_NAMES = ["lastModifiedAt", "lastSyncedAt", "lastReplicatedAt"];

//
// The smallest state file that could hold a complete record. Anything shorter is not one.
//
const MINIMUM_STATE_FILE_BYTES = 40;

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
// Decodes the named text field out of a state file buffer, or undefined when it is not a state file.
//
function readStateField(buffer: Buffer, fieldName: string): string | undefined {
    if (buffer.length < MINIMUM_STATE_FILE_BYTES || buffer.subarray(4, 8).toString("ascii") !== "DBST") {
        return undefined;
    }

    // Skip the content hash, which is raw bytes rather than text, to reach the timestamps.
    let position = 8;
    const contentHashLength = buffer.readUInt32LE(position);
    position += 4 + contentHashLength;

    for (const candidateName of TEXT_FIELD_NAMES) {
        const length = buffer.readUInt32LE(position);
        position += 4;
        const text = buffer.toString("utf8", position, position + length);
        position += length;
        if (candidateName === fieldName) {
            return text;
        }
    }
    return undefined;
}

const argv = process.argv.slice(2);
const filePath = requiredArg(argv, "file");
const fieldName = requiredArg(argv, "field");

if (existsSync(filePath)) {
    const fieldValue = readStateField(readFileSync(filePath), fieldName);
    if (fieldValue !== undefined) {
        process.stdout.write(fieldValue);
    }
}
