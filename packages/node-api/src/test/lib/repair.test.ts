import * as fs from "node:fs";
import * as path from "node:path";
import { createStorage } from "storage";
import { TestUuidGenerator, getProcessTmpDir } from "node-utils";
import { MockTimestampProvider } from "utils";
import { addItem } from "merkle-tree";
import { createMediaFileDatabase, createDatabase } from "../../lib/media-file-database";
import { loadMerkleTree, saveMerkleTree } from "../../lib/tree";
import { loadDatabaseConfig } from "api";
import { computeHash } from "../../lib/hash";
import { repair } from "../../lib/repair";

//
// Valid BSON document id (uuid) for tests that hit the real collection implementation.
//
const ASSET_ID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";

describe("repair", () => {
    test("bumps lastModifiedAt when records are repaired", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "repair-bump-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
            const uuidGenerator = new TestUuidGenerator();
            const timestampProvider = new MockTimestampProvider();
            const { bsonDatabase, metadataCollection } = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
            await createDatabase(assetStorage, rawStorage, uuidGenerator, metadataCollection);

            //
            // Write an asset file and add it to the merkle tree without inserting a metadata record.
            // Repair should detect the missing record and synthesize one.
            //
            const assetFileName = `asset/${ASSET_ID}`;
            const assetContent = Buffer.from("fake asset bytes for repair test", "utf8");
            await assetStorage.write(assetFileName, "application/octet-stream", assetContent);
            const assetInfo = await assetStorage.info(assetFileName);
            if (!assetInfo) {
                throw new Error("asset info missing after write");
            }
            const assetHash = await computeHash(await assetStorage.readStream(assetFileName));

            let merkleTree = await loadMerkleTree(assetStorage);
            if (!merkleTree) {
                throw new Error("merkle tree missing after createDatabase");
            }
            merkleTree = addItem(merkleTree, {
                name: assetFileName,
                hash: assetHash,
                length: assetInfo.length,
                lastModified: assetInfo.lastModified,
            });
            await saveMerkleTree(merkleTree, assetStorage);

            const result = await repair(assetStorage, rawStorage, assetStorage, bsonDatabase, metadataCollection, {
                source: tmpDir,
            });

            expect(result.recordsRepaired).toContain(assetFileName);

            const config = await loadDatabaseConfig(rawStorage);
            expect(config?.lastModifiedAt).toBeDefined();
            expect(typeof config?.lastModifiedAt).toBe("string");
            expect(Date.parse(config!.lastModifiedAt!)).not.toBeNaN();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });

    test("does not bump lastModifiedAt when no repairs were needed", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "repair-no-bump-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
            const uuidGenerator = new TestUuidGenerator();
            const timestampProvider = new MockTimestampProvider();
            const { bsonDatabase, metadataCollection } = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
            await createDatabase(assetStorage, rawStorage, uuidGenerator, metadataCollection);

            const before = await loadDatabaseConfig(rawStorage);
            expect(before?.lastModifiedAt).toBeUndefined();

            const result = await repair(assetStorage, rawStorage, assetStorage, bsonDatabase, metadataCollection, {
                source: tmpDir,
            });

            expect(result.recordsRepaired).toEqual([]);
            expect(result.repaired).toEqual([]);

            const after = await loadDatabaseConfig(rawStorage);
            expect(after?.lastModifiedAt).toBeUndefined();
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });
});
