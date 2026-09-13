import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { createStorage } from "storage";
import { TestUuidGenerator } from "node-utils";
import { createDatabase, createMediaFileDatabase } from "../../lib/media-file-database";
import { replicate } from "../../lib/replicate";
import { loadMerkleTree, saveMerkleTree } from "../../lib/tree";
import { addItem } from "merkle-tree";
import { createHash } from "crypto";
import type { ITimestampProvider } from "utils";

//
// What a full replica taken from a partial one is marked as.
//
// A full replica is full by definition: it holds everything its source could give it, and full is
// what was asked for by name. The flag said otherwise. Full mode copied the source's metadata across
// whole, partial flag included, so a full copy of a phone's replica, taken to rebuild a lost origin,
// came out marked partial, and a sync then refused every original and display version pushed at it,
// for ever. Measured on a Pixel 6, the phone imported and pushed 1,937 photos and the origin ended
// up holding the 250 originals it started with, while its thumbnails went from 8,481 to 10,199.
//

//
// A clock that stands still, so every stamp in these databases is the same.
//
class FixedTimestampProvider implements ITimestampProvider {

    //
    // The current time in milliseconds since the epoch.
    //
    now(): number {
        return Date.parse("2026-01-01T00:00:00.000Z");
    }

    //
    // The current time as a Date.
    //
    dateNow(): Date {
        return new Date(this.now());
    }
}

describe("a full replica taken from a partial one", () => {
    let workingDir: string;

    beforeEach(() => {
        workingDir = fs.mkdtempSync(path.join(os.tmpdir(), "psphere-replicate-full-"));
    });

    afterEach(() => {
        fs.rmSync(workingDir, { recursive: true, force: true });
    });

    //
    // Builds an origin at the given directory holding one record, and returns its path.
    //
    async function makeOriginDatabase(clock: ITimestampProvider): Promise<string> {
        const originPath = path.join(workingDir, "origin");
        fs.mkdirSync(originPath, { recursive: true });

        const uuidGenerator = new TestUuidGenerator();
        const { storage, rawStorage } = createStorage(originPath, undefined, undefined);
        const database = createMediaFileDatabase(storage, uuidGenerator, clock);
        await createDatabase(storage, rawStorage, uuidGenerator, database.metadataCollection);

        await database.metadataCollection.insertOne({
            _id: "11111111-2222-3333-4444-555555555555",
            origFileName: "test.jpg",
            contentType: "image/jpeg",
        } as any);
        await database.bsonDatabase.commit();
        database.bsonDatabase.flush();

        // One thumbnail, so a replicate has a file to copy. A replicate that copies nothing never
        // writes the destination's tree back, and it is the write that carries the metadata.
        const thumbnail = Buffer.from("a thumbnail's worth of bytes", "utf-8");
        await storage.write("thumb/11111111-2222-3333-4444-555555555555", "image/jpeg", thumbnail);
        const tree = await loadMerkleTree(storage);
        await saveMerkleTree(addItem(tree!, {
            name: "thumb/11111111-2222-3333-4444-555555555555",
            hash: createHash("sha256").update(thumbnail).digest(),
            length: thumbnail.length,
            lastModified: clock.dateNow(),
        }), storage);

        return originPath;
    }

    //
    // Replicates from one path to another in the given mode, and returns the destination path.
    //
    async function replicateTo(sourcePath: string, destName: string, partial: boolean, clock: ITimestampProvider): Promise<string> {
        const destPath = path.join(workingDir, destName);
        const source = createStorage(sourcePath, undefined, undefined);
        const sourceDb = createMediaFileDatabase(source.storage, new TestUuidGenerator(), clock);
        const dest = createStorage(destPath, undefined, undefined);
        await replicate(
            sourcePath,
            source.storage,
            sourceDb.bsonDatabase,
            new TestUuidGenerator(),
            clock,
            dest.storage,
            dest.rawStorage,
            { partial }
        );
        return destPath;
    }

    test("is not marked partial", async () => {
        const clock = new FixedTimestampProvider();
        const originPath = await makeOriginDatabase(clock);

        // The phone's replica: partial, and marked so.
        const partialPath = await replicateTo(originPath, "partial", true, clock);
        const partialTree = await loadMerkleTree(createStorage(partialPath, undefined, undefined).storage);
        expect(partialTree!.databaseMetadata!.isPartial).toBe(true);

        // A lost origin rebuilt from it, in full.
        const rebuiltPath = await replicateTo(partialPath, "rebuilt", false, clock);
        const rebuiltTree = await loadMerkleTree(createStorage(rebuiltPath, undefined, undefined).storage);

        expect(rebuiltTree!.databaseMetadata!.isPartial).toBe(false);
    });

    test("keeps the rest of the source's metadata", async () => {
        const clock = new FixedTimestampProvider();
        const originPath = await makeOriginDatabase(clock);
        const partialPath = await replicateTo(originPath, "partial", true, clock);
        const partialTree = await loadMerkleTree(createStorage(partialPath, undefined, undefined).storage);

        const rebuiltPath = await replicateTo(partialPath, "rebuilt", false, clock);
        const rebuiltTree = await loadMerkleTree(createStorage(rebuiltPath, undefined, undefined).storage);

        expect(rebuiltTree!.databaseMetadata!.filesImported).toBe(partialTree!.databaseMetadata!.filesImported);
    });
});
