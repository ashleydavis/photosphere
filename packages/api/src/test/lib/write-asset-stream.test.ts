import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { Readable } from "stream";
import { createStorage } from "storage";
import { TestUuidGenerator } from "node-utils";
import { MockTimestampProvider } from "utils";
import {
    createDatabase,
    createMediaFileDatabase,
    writeAssetStream,
} from "../../lib/media-file-database";

describe("writeAssetStream", () => {
    test("persists bytes from the stream", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "write-asset-stream-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
            const uuidGenerator = new TestUuidGenerator();
            const timestampProvider = new MockTimestampProvider();
            const { metadataCollection } = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
            await createDatabase(assetStorage, rawStorage, uuidGenerator, metadataCollection);

            const sessionId = uuidGenerator.generate();
            const payload = Buffer.from("hello-stream");

            await writeAssetStream(
                assetStorage,
                rawStorage,
                sessionId,
                "t1",
                "thumb",
                "image/jpeg",
                Readable.from(payload),
                payload.length,
            );

            const written = await assetStorage.read("thumb/t1");
            expect(written?.toString()).toBe("hello-stream");
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("rejects announced zero length before writing", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "write-asset-stream-cl0-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
            const uuidGenerator = new TestUuidGenerator();
            const timestampProvider = new MockTimestampProvider();
            const { metadataCollection } = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
            await createDatabase(assetStorage, rawStorage, uuidGenerator, metadataCollection);

            const sessionId = uuidGenerator.generate();

            await expect(
                writeAssetStream(
                    assetStorage,
                    rawStorage,
                    sessionId,
                    "t0",
                    "thumb",
                    undefined,
                    Readable.from(Buffer.alloc(0)),
                    0,
                ),
            ).rejects.toThrow("Asset data is empty");
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("rejects an empty stream when length is not announced", async () => {
        const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "write-asset-stream-empty-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
            const uuidGenerator = new TestUuidGenerator();
            const timestampProvider = new MockTimestampProvider();
            const { metadataCollection } = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
            await createDatabase(assetStorage, rawStorage, uuidGenerator, metadataCollection);

            const sessionId = uuidGenerator.generate();

            await expect(
                writeAssetStream(
                    assetStorage,
                    rawStorage,
                    sessionId,
                    "t-empty",
                    "thumb",
                    undefined,
                    Readable.from(Buffer.alloc(0)),
                    undefined,
                ),
            ).rejects.toThrow("Asset data is empty");
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });
});
