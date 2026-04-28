import * as fs from "node:fs";
import * as path from "node:path";
import { MockCollection } from "bdb";
import type { IAsset } from "../../lib/asset";
import type { IDatabaseOp } from "../../lib/database-op";
import { createStorage } from "storage";
import { TestUuidGenerator, getProcessTmpDir } from "node-utils";
import { MockTimestampProvider } from "utils";
import { applyDatabaseOps, applyMetadataDatabaseOps, groupOpsByDatabaseId } from "../../lib/apply-database-ops";
import { createMediaFileDatabase, createDatabase, loadSortIndexes } from "../../lib/media-file-database";

//
// Valid BSON document id (16-byte hex) for tests that hit the real collection implementation.
//
const BSON_RECORD_ID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";

function minimalAsset(overrides: Partial<IAsset> = {}): IAsset {
    const now = new Date().toISOString();
    return {
        _id: "asset-1",
        origFileName: "x.jpg",
        contentType: "image/jpeg",
        width: 1,
        height: 1,
        hash: "ab",
        fileDate: now,
        uploadDate: now,
        micro: "",
        color: [ 0, 0, 0 ],
        ...overrides,
    };
}

//
// Minimal database op for grouping tests (payload shape is irrelevant to groupOpsByDatabaseId).
//
function groupingOp(databaseId: string, recordId: string): IDatabaseOp {
    return {
        databaseId,
        collectionName: "metadata",
        recordId,
        op: {
            type: "set",
            fields: {},
        },
    };
}

describe("groupOpsByDatabaseId", () => {
    test("returns an empty map for an empty op list", () => {
        const groups = groupOpsByDatabaseId([]);
        expect(groups.size).toBe(0);
    });

    test("places a single op under its databaseId", () => {
        const op = groupingOp("/db/a", "r1");
        const groups = groupOpsByDatabaseId([ op ]);
        expect(groups.size).toBe(1);
        expect(groups.get("/db/a")).toEqual([ op ]);
    });

    test("appends ops for the same databaseId in input order", () => {
        const first = groupingOp("/db/shared", "first");
        const second = groupingOp("/db/shared", "second");
        const groups = groupOpsByDatabaseId([ first, second ]);
        expect(groups.get("/db/shared")).toEqual([ first, second ]);
    });

    test("splits ops with different databaseIds into separate arrays", () => {
        const pathA = groupingOp("/db/a", "x");
        const pathB = groupingOp("/db/b", "y");
        const pathA2 = groupingOp("/db/a", "z");
        const groups = groupOpsByDatabaseId([ pathA, pathB, pathA2 ]);
        expect(groups.size).toBe(2);
        expect(groups.get("/db/a")).toEqual([ pathA, pathA2 ]);
        expect(groups.get("/db/b")).toEqual([ pathB ]);
    });

    test("iterates database keys in first-seen order", () => {
        const bFirst = groupingOp("/db/b", "1");
        const aSecond = groupingOp("/db/a", "2");
        const bThird = groupingOp("/db/b", "3");
        const groups = groupOpsByDatabaseId([ bFirst, aSecond, bThird ]);
        expect([ ...groups.keys() ]).toEqual([ "/db/b", "/db/a" ]);
    });
});

describe("applyMetadataDatabaseOps", () => {
    test("set with upsert creates a new metadata record", async () => {
        const collection = new MockCollection<IAsset>([]);
        const ops: IDatabaseOp[] = [
            {
                databaseId: "/ignored-for-this-test",
                collectionName: "metadata",
                recordId: "new-id",
                op: {
                    type: "set",
                    fields: minimalAsset({ _id: "wrong-id-should-be-stripped" }),
                },
            },
        ];
        await applyMetadataDatabaseOps(collection, ops);
        const saved = await collection.getOne("new-id");
        expect(saved).toBeDefined();
        expect(saved?._id).toBe("new-id");
        expect(saved?.origFileName).toBe("x.jpg");
    });

    test("set merges into an existing record", async () => {
        const collection = new MockCollection<IAsset>([ minimalAsset({ _id: "a1", description: "old" }) ]);
        const ops: IDatabaseOp[] = [
            {
                databaseId: "/x",
                collectionName: "metadata",
                recordId: "a1",
                op: {
                    type: "set",
                    fields: { description: "new" },
                },
            },
        ];
        await applyMetadataDatabaseOps(collection, ops);
        const saved = await collection.getOne("a1");
        expect(saved?.description).toBe("new");
        expect(saved?.origFileName).toBe("x.jpg");
    });

    test("push appends a value to an array field when absent", async () => {
        const collection = new MockCollection<IAsset>([ minimalAsset({ _id: "a1", labels: [ "x" ] }) ]);
        const ops: IDatabaseOp[] = [
            {
                databaseId: "/x",
                collectionName: "metadata",
                recordId: "a1",
                op: {
                    type: "push",
                    field: "labels",
                    value: "y",
                },
            },
        ];
        await applyMetadataDatabaseOps(collection, ops);
        const saved = await collection.getOne("a1");
        expect(saved?.labels).toEqual([ "x", "y" ]);
    });

    test("push does not duplicate an existing value", async () => {
        const collection = new MockCollection<IAsset>([ minimalAsset({ _id: "a1", labels: [ "x" ] }) ]);
        const ops: IDatabaseOp[] = [
            {
                databaseId: "/x",
                collectionName: "metadata",
                recordId: "a1",
                op: {
                    type: "push",
                    field: "labels",
                    value: "x",
                },
            },
        ];
        await applyMetadataDatabaseOps(collection, ops);
        const saved = await collection.getOne("a1");
        expect(saved?.labels).toEqual([ "x" ]);
    });

    test("pull removes a value from an array field", async () => {
        const collection = new MockCollection<IAsset>([ minimalAsset({ _id: "a1", labels: [ "x", "y" ] }) ]);
        const ops: IDatabaseOp[] = [
            {
                databaseId: "/x",
                collectionName: "metadata",
                recordId: "a1",
                op: {
                    type: "pull",
                    field: "labels",
                    value: "x",
                },
            },
        ];
        await applyMetadataDatabaseOps(collection, ops);
        const saved = await collection.getOne("a1");
        expect(saved?.labels).toEqual([ "y" ]);
    });

    test("push throws when the record is missing", async () => {
        const collection = new MockCollection<IAsset>([]);
        const ops: IDatabaseOp[] = [
            {
                databaseId: "/x",
                collectionName: "metadata",
                recordId: "missing",
                op: {
                    type: "push",
                    field: "labels",
                    value: "x",
                },
            },
        ];
        await expect(applyMetadataDatabaseOps(collection, ops)).rejects.toThrow(/does not exist/);
    });

    test("rejects unsupported collection names", async () => {
        const collection = new MockCollection<IAsset>([]);
        const ops: IDatabaseOp[] = [
            {
                databaseId: "/x",
                collectionName: "other",
                recordId: "a1",
                op: {
                    type: "set",
                    fields: { description: "x" },
                },
            },
        ];
        await expect(applyMetadataDatabaseOps(collection, ops)).rejects.toThrow(/Unsupported collection/);
    });
});

describe("applyDatabaseOps", () => {
    test("acquires write lock and persists metadata on a real database directory", async () => {
        const tmpDir = fs.mkdtempSync(path.join(getProcessTmpDir(), "apply-database-ops-lock-"));
        try {
            const { storage: assetStorage, rawStorage } = createStorage(tmpDir, undefined, undefined);
            const uuidGenerator = new TestUuidGenerator();
            const timestampProvider = new MockTimestampProvider();
            const { metadataCollection } = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
            await createDatabase(assetStorage, rawStorage, uuidGenerator, metadataCollection);

            const sessionId = uuidGenerator.generate();
            const asset = minimalAsset({ _id: BSON_RECORD_ID });
            const ops: IDatabaseOp[] = [
                {
                    databaseId: tmpDir,
                    collectionName: "metadata",
                    recordId: BSON_RECORD_ID,
                    op: {
                        type: "set",
                        fields: asset,
                    },
                },
            ];

            await applyDatabaseOps(uuidGenerator, timestampProvider, sessionId, ops);

            const { storage: verifyStorage } = createStorage(tmpDir, undefined, undefined);
            const verifyDb = createMediaFileDatabase(verifyStorage, uuidGenerator, timestampProvider);
            await loadSortIndexes(verifyStorage, verifyDb.metadataCollection);
            const loaded = await verifyDb.metadataCollection.getOne(BSON_RECORD_ID);
            expect(loaded?.origFileName).toBe(asset.origFileName);
        }
        finally {
            fs.rmSync(tmpDir, { recursive: true, force: true });
        }
    });
});
