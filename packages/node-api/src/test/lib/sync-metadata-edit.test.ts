import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { createStorage } from "storage";
import { TestUuidGenerator } from "node-utils";
import { createDatabase, createMediaFileDatabase } from "../../lib/media-file-database";
import { applyDatabaseOps } from "../../lib/apply-database-ops";
import { syncDatabases } from "../../lib/sync";
import { replicate } from "../../lib/replicate";
import type { IDatabaseOp } from "api";
import type { ITimestampProvider } from "utils";

//
// A clock the test drives, so "the device edited this after the origin was written" is stated rather
// than hoped for. Sync merges records field by field on timestamp, so a test that used the wall clock
// would be asserting something about how fast it happened to run.
//
class SettableTimestampProvider implements ITimestampProvider {
    //
    // The current time in milliseconds that now() reports.
    //
    private current: number;

    //
    // Starts the clock at the given time.
    //
    constructor(start: number) {
        this.current = start;
    }

    //
    // Moves the clock forward by the given number of milliseconds.
    //
    advance(milliseconds: number): void {
        this.current += milliseconds;
    }

    //
    // The current time in milliseconds.
    //
    now(): number {
        return this.current;
    }

    //
    // The current time as a Date.
    //
    dateNow(): Date {
        return new Date(this.current);
    }
}

describe("a metadata edit reaches the origin through a sync", () => {
    let workingDir: string;

    beforeEach(() => {
        workingDir = fs.mkdtempSync(path.join(os.tmpdir(), "psphere-sync-edit-"));
    });

    afterEach(() => {
        fs.rmSync(workingDir, { recursive: true, force: true });
    });

    //
    // Builds a database at the given directory holding one metadata record, and returns its path.
    // `originDescription` is the description the record is created with. Passing undefined leaves the
    // field off the record entirely; passing "" is what the real add path does, because
    // upload-asset.worker.ts writes `description: description || ""` on every asset it imports. The
    // two are not interchangeable in a merge: an absent field loses to any present one outright,
    // while an empty string is a value that competes on its timestamp like any other.
    //
    async function makeOriginDatabase(timestampProvider: ITimestampProvider, assetId: string, originDescription: string | undefined): Promise<string> {
        const originPath = path.join(workingDir, "origin");
        fs.mkdirSync(originPath, { recursive: true });

        const uuidGenerator = new TestUuidGenerator();
        const { storage, rawStorage } = createStorage(originPath, undefined, undefined);
        const database = createMediaFileDatabase(storage, uuidGenerator, timestampProvider);
        await createDatabase(storage, rawStorage, uuidGenerator, database.metadataCollection);

        const originRecord: any = {
            _id: assetId,
            origFileName: "test.jpg",
            contentType: "image/jpeg",
        };
        if (originDescription !== undefined) {
            originRecord.description = originDescription;
        }

        await database.metadataCollection.insertOne(originRecord);
        await database.bsonDatabase.commit();
        database.bsonDatabase.flush();

        return originPath;
    }

    //
    // Runs the whole journey and returns what the origin ends up holding as the description:
    // build an origin, replicate it, edit the replica through applyDatabaseOps, sync back up, then
    // reopen the origin from disk. `editClockOffsetMs` shifts the clock the edit is stamped with, so
    // a device running behind the machine that wrote the origin can be expressed directly.
    // `originDescription` is what the origin's record holds before the edit.
    //
    async function runEditAndSync(partial: boolean, editClockOffsetMs: number, originDescription: string | undefined): Promise<string | undefined> {
        const assetId = "11111111-2222-3333-4444-555555555555";

        // The origin is written first, so its record carries the earlier timestamp.
        const clock = new SettableTimestampProvider(Date.parse("2026-01-01T00:00:00.000Z"));
        const originPath = await makeOriginDatabase(clock, assetId, originDescription);

        // The replica, exactly as the app makes it: a replicate of the origin, which records the
        // origin path in the replica's own config.
        const replicaPath = path.join(workingDir, "replica");
        const sourceForReplicate = createStorage(originPath, undefined, undefined);
        const sourceDbForReplicate = createMediaFileDatabase(sourceForReplicate.storage, new TestUuidGenerator(), clock);
        const destForReplicate = createStorage(replicaPath, undefined, undefined);
        await replicate(
            originPath,
            sourceForReplicate.storage,
            sourceDbForReplicate.bsonDatabase,
            new TestUuidGenerator(),
            clock,
            destForReplicate.storage,
            destForReplicate.rawStorage,
            { partial }
        );

        // The edit happens after the origin was written, so on a last-write-wins merge it must win,
        // unless the caller has asked for a clock far enough behind to change that.
        clock.advance(60_000 + editClockOffsetMs);

        const ops: IDatabaseOp[] = [{
            collectionName: "metadata",
            recordId: assetId,
            databaseId: replicaPath,
            op: {
                type: "set",
                fields: { description: "Edited on the replica" },
            },
        }];
        await applyDatabaseOps(new TestUuidGenerator(), clock, "session-edit", ops);

        // Sync the replica up to its origin, the way syncDatabaseHandler does: source is the local
        // replica, target is the origin.
        const replicaStorage = createStorage(replicaPath, undefined, undefined);
        const originStorage = createStorage(originPath, undefined, undefined);
        const replicaDb = createMediaFileDatabase(replicaStorage.storage, new TestUuidGenerator(), clock);
        const originDb = createMediaFileDatabase(originStorage.storage, new TestUuidGenerator(), clock);

        const result = await syncDatabases(
            replicaStorage.storage,
            replicaStorage.rawStorage,
            replicaDb.bsonDatabase,
            originStorage.storage,
            originStorage.rawStorage,
            originDb.bsonDatabase,
            "session-sync"
        );

        expect(result.synced).toBe(true);

        // Read the origin back from disk with a database of its own, so this cannot pass on anything
        // the sync left cached in memory.
        originDb.bsonDatabase.flush();
        replicaDb.bsonDatabase.flush();

        const verifyStorage = createStorage(originPath, undefined, undefined);
        const verifyDb = createMediaFileDatabase(verifyStorage.storage, new TestUuidGenerator(), clock);
        const originRecord = await verifyDb.metadataCollection.getOne(assetId);
        verifyDb.bsonDatabase.flush();

        return originRecord?.description;
    }

    test("a description set on a full replica reaches the origin", async () => {
        expect(await runEditAndSync(false, 0, undefined)).toBe("Edited on the replica");
    });

    test("a description set on a partial replica reaches the origin", async () => {
        expect(await runEditAndSync(true, 0, undefined)).toBe("Edited on the replica");
    });

    test("a description set on a device whose clock is behind still reaches the origin", async () => {
        // The emulator the mobile suite runs on was measured 30 seconds behind the host that wrote
        // the origin. The edit is made a minute after the origin, so even 30 seconds behind it is
        // still the later write and must win.
        expect(await runEditAndSync(true, -30_000, undefined)).toBe("Edited on the replica");
    });

    test("a description set on a device whose clock is far behind still reaches the origin", async () => {
        // The failure this guards against is silent: last-write-wins compares timestamps taken from
        // two different machines' clocks, so a device far enough behind loses an edit it genuinely
        // made later, and the sync still reports that it pushed changes.
        expect(await runEditAndSync(true, -600_000, undefined)).toBe("Edited on the replica");
    });

    // The four cases above all leave the description off the origin record, and an absent field wins
    // nothing and loses nothing: mergeValues returns the other side outright when one value is
    // undefined, before it compares timestamps at all. That is why they passed while smoke test 45
    // failed. Every asset the real import path writes carries `description: ""`
    // (upload-asset.worker.ts), which is a value, not an absence, so it competes on its timestamp.
    // These are the cases test 45 actually exercises.

    test("a description set over an empty one reaches the origin", async () => {
        expect(await runEditAndSync(true, 0, "")).toBe("Edited on the replica");
    });

    test("a description set over an empty one on a device whose clock is behind reaches the origin", async () => {
        expect(await runEditAndSync(true, -30_000, "")).toBe("Edited on the replica");
    });

    test("a description set over an empty one on a device whose clock is far behind reaches the origin", async () => {
        // This is smoke test 45's failure, reproduced on the host in a second. The device edits the
        // description a minute after the origin was written, but its clock is far enough behind that
        // the edit is stamped earlier than the origin's record, so the origin's empty string wins and
        // the edit is dropped. The sync still reports that it pushed changes, so nothing fails loudly.
        expect(await runEditAndSync(true, -600_000, "")).toBe("Edited on the replica");
    });
});
