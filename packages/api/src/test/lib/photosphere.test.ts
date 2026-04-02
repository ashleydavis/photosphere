import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { Readable } from "stream";
import { createStorage } from "storage";
import { TestUuidGenerator } from "node-utils";
import { MockTimestampProvider } from "utils";
import { createDatabase } from "../../lib/media-file-database";
import { Psi } from "../../lib/photosphere";

//
// Creates a temp-dir-backed Psi instance with an initialised database.
// Returns the psi and a cleanup function.
//
async function makePsi(tmpDir: string): Promise<Psi> {
    const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
    const uuidGenerator = new TestUuidGenerator();
    const timestampProvider = new MockTimestampProvider();
    const sessionId = uuidGenerator.generate();
    const psi = new Psi(assetStorage, rawStorage, sessionId, uuidGenerator, timestampProvider);
    await createDatabase(assetStorage, rawStorage, uuidGenerator, psi.metadata());
    return psi;
}

describe("Psi", () => {
    test("database() returns the BSON database", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "psi-db-"));
        try {
            const psi = await makePsi(tmpDir);
            expect(psi.database()).toBeDefined();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("files() returns a merkle ref", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "psi-files-"));
        try {
            const psi = await makePsi(tmpDir);
            const ref = psi.files();
            expect(ref).toBeDefined();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("files() returns the same ref on repeated calls", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "psi-files-cache-"));
        try {
            const psi = await makePsi(tmpDir);
            expect(psi.files()).toBe(psi.files());
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("metadata() returns the metadata collection", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "psi-meta-"));
        try {
            const psi = await makePsi(tmpDir);
            expect(psi.metadata()).toBeDefined();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("write() and stream() round-trip", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "psi-write-"));
        try {
            const psi = await makePsi(tmpDir);
            const payload = Buffer.from("hello-write");
            await psi.write("asset1", "thumb", "image/jpeg", payload);
            const stream = await psi.stream("asset1", "thumb");
            const chunks: Buffer[] = [];
            for await (const chunk of stream) {
                chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
            }
            expect(Buffer.concat(chunks).toString()).toBe("hello-write");
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("writeStream() and stream() round-trip", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "psi-writestream-"));
        try {
            const psi = await makePsi(tmpDir);
            const payload = Buffer.from("hello-stream");
            await psi.writeStream("asset2", "thumb", "image/jpeg", Readable.from(payload), payload.length);
            const stream = await psi.stream("asset2", "thumb");
            const chunks: Buffer[] = [];
            for await (const chunk of stream) {
                chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
            }
            expect(Buffer.concat(chunks).toString()).toBe("hello-stream");
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("summary() returns database stats", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "psi-summary-"));
        try {
            const psi = await makePsi(tmpDir);
            const summary = await psi.summary();
            expect(summary).toBeDefined();
            expect(typeof summary.totalImports).toBe("number");
            expect(typeof summary.fullHash).toBe("string");
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("commit() and flush() complete without error on a clean database", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "psi-commit-"));
        try {
            const psi = await makePsi(tmpDir);
            await psi.commit();
            psi.flush();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });
});
