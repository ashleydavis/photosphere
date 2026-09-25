//
// Interop between the TypeScript EncryptedStorage (packages/storage) and the Zig port, run by the Zig test
// "EncryptedStorage files are readable by TypeScript and TypeScript files are readable by Zig" in
// src/test/encrypted-storage.test.zig as:
//   bun run src/test/fixtures/encrypted-storage-interop.ts write <db-dir>
//       writes, with the TypeScript createStorage and the fixture key, ts-write.bin (storage.write) and
//       ts-stream.bin (storage.writeStream) containing the plaintext in <db-dir>/plain.bin
//   bun run src/test/fixtures/encrypted-storage-interop.ts verify <db-dir>
//       reads zig-write.bin and zig-stream.bin with read and readStream and checks them against plain.bin,
//       and checks that info() returns the raw (encrypted) length
// The key is the TypeScript fixture key of encryption-zig (packages/encryption-zig/src/test/fixtures/ts-*.pem).
// Prints "OK" and exits with 0 when every check passes, otherwise prints the failures and exits with 1.
//
import * as fs from "fs";
import * as path from "path";
import { Readable } from "stream";
import { createStorage, loadEncryptionKeysFromPem } from "storage";

//
// Reads a whole stream into a buffer.
//
function streamToBuffer(stream: NodeJS.ReadableStream): Promise<Buffer> {
    const chunks: Buffer[] = [];
    return new Promise((resolve, reject) => {
        stream.on("data", (chunk: Buffer) => chunks.push(chunk));
        stream.on("end", () => resolve(Buffer.concat(chunks)));
        stream.on("error", reject);
    });
}

//
// Creates the encrypted storage for the database directory.
//
async function openStorage(dbDir: string) {
    const fixturesDir = path.join(__dirname, "../../../../encryption-zig/src/test/fixtures");
    const { options } = await loadEncryptionKeysFromPem([{
        privateKeyPem: fs.readFileSync(path.join(fixturesDir, "ts-private.pem"), "utf8"),
        publicKeyPem: fs.readFileSync(path.join(fixturesDir, "ts-public.pem"), "utf8"),
    }]);
    return createStorage(dbDir, undefined, options);
}

//
// Runs the checks and returns the failures.
//
async function run(mode: string, dbDir: string): Promise<string[]> {
    const failures: string[] = [];
    const { storage, rawStorage } = await openStorage(dbDir);
    const plain = fs.readFileSync(path.join(dbDir, "plain.bin"));
    if (mode === "write") {
        await storage.write("ts-write.bin", undefined, plain);
        await storage.writeStream("ts-stream.bin", undefined, Readable.from([plain]), plain.length);
        return failures;
    }

    for (const fileName of ["zig-write.bin", "zig-stream.bin"]) {
        const raw = await rawStorage.read(fileName);
        if (!raw || raw.subarray(0, 4).toString("ascii") !== "PSEN") {
            failures.push(`${fileName} is not in the encrypted format`);
        }
        const read = await storage.read(fileName);
        if (!read || !read.equals(plain)) {
            failures.push(`storage.read failed for ${fileName}`);
        }
        const streamed = await streamToBuffer(await storage.readStream(fileName));
        if (!streamed.equals(plain)) {
            failures.push(`storage.readStream failed for ${fileName}`);
        }
        const info = await storage.info(fileName);
        if (!info || !raw || info.length !== raw.length) {
            failures.push(`storage.info did not return the raw length for ${fileName}`);
        }
    }
    return failures;
}

//
// Entry point.
//
async function main(): Promise<void> {
    const mode = process.argv[2];
    const dbDir = process.argv[3];
    if ((mode !== "write" && mode !== "verify") || !dbDir) {
        console.error("Usage: bun run encrypted-storage-interop.ts <write|verify> <db-dir>");
        process.exit(1);
    }
    const failures = await run(mode, dbDir);
    if (failures.length > 0) {
        for (const failure of failures) {
            console.error(failure);
        }
        process.exit(1);
    }
    console.log("OK");
}

main().catch(err => {
    console.error(err);
    process.exit(1);
});
