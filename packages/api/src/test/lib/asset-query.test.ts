import * as fs from "node:fs/promises";
import * as path from "node:path";
import * as os from "node:os";
import { MockStorage } from "storage";
import { BsonDatabase, type IBsonCollection } from "bdb";
import { RandomUuidGenerator, TimestampProvider } from "utils";
import type { IAsset } from "../../lib/asset";
import { listAssetPage, searchAssets, getAsset, streamAssetToFile } from "../../lib/asset-query";

//
// UUID v4 record IDs used across the tests. The bdb collection layer rejects non-16-byte IDs.
//
const ID_A = "11111111-1111-4111-a111-111111111111";
const ID_B = "22222222-2222-4222-a222-222222222222";
const ID_C = "33333333-3333-4333-a333-333333333333";

//
// Builds a minimal IAsset for tests; overrides win.
//
function makeAsset(overrides: Partial<IAsset>): IAsset {
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
// Builds a fresh BsonDatabase backed by an in-memory MockStorage and inserts the supplied
// assets. Ensures the photoDate sort index so listAssetPage works.
//
async function buildDatabase(assets: IAsset[]): Promise<{ database: BsonDatabase; collection: IBsonCollection<IAsset> }> {
    const storage = new MockStorage();
    const database = new BsonDatabase(storage, "", new RandomUuidGenerator(), new TimestampProvider());
    const collection = database.collection<IAsset>("metadata");
    await collection.sortIndex("photoDate", "desc").ensure(collection, "date");
    for (const asset of assets) {
        await collection.insertOne(asset);
    }
    return { database, collection };
}

describe("listAssetPage", () => {
    test("returns assets sorted by photoDate descending", async () => {
        const assets = [
            makeAsset({ _id: ID_A, origFileName: "a.jpg", photoDate: "2023-01-01T00:00:00.000Z" }),
            makeAsset({ _id: ID_B, origFileName: "b.jpg", photoDate: "2024-06-15T00:00:00.000Z" }),
            makeAsset({ _id: ID_C, origFileName: "c.jpg", photoDate: "2022-12-31T00:00:00.000Z" }),
        ];
        const { database } = await buildDatabase(assets);

        const page = await listAssetPage(database, 10, undefined);

        expect(page.assets.map(asset => asset._id)).toEqual([ ID_B, ID_A, ID_C ]);
    });

    test("limits the page size", async () => {
        const assets = [
            makeAsset({ _id: ID_A, photoDate: "2023-01-01T00:00:00.000Z" }),
            makeAsset({ _id: ID_B, photoDate: "2024-06-15T00:00:00.000Z" }),
            makeAsset({ _id: ID_C, photoDate: "2022-12-31T00:00:00.000Z" }),
        ];
        const { database } = await buildDatabase(assets);

        const page = await listAssetPage(database, 2, undefined);

        expect(page.assets).toHaveLength(2);
    });
});

describe("searchAssets", () => {
    test("filters by case-insensitive substring on origFileName", async () => {
        const assets = [
            makeAsset({ _id: ID_A, origFileName: "Beach.jpg" }),
            makeAsset({ _id: ID_B, origFileName: "mountain.png" }),
            makeAsset({ _id: ID_C, origFileName: "BEACH_party.mp4" }),
        ];
        const { database } = await buildDatabase(assets);

        const matches = await searchAssets(database, "beach", undefined, undefined, undefined, 10);

        expect(matches.map(asset => asset._id).sort()).toEqual([ ID_A, ID_C ].sort());
    });

    test("filters by content type prefix", async () => {
        const assets = [
            makeAsset({ _id: ID_A, contentType: "image/jpeg" }),
            makeAsset({ _id: ID_B, contentType: "video/mp4" }),
            makeAsset({ _id: ID_C, contentType: "image/png" }),
        ];
        const { database } = await buildDatabase(assets);

        const matches = await searchAssets(database, "", "image/", undefined, undefined, 10);

        expect(matches.map(asset => asset._id).sort()).toEqual([ ID_A, ID_C ].sort());
    });

    test("filters by date range", async () => {
        const assets = [
            makeAsset({ _id: ID_A, photoDate: "2020-01-01T00:00:00.000Z" }),
            makeAsset({ _id: ID_B, photoDate: "2024-01-01T00:00:00.000Z" }),
            makeAsset({ _id: ID_C, photoDate: "2022-06-01T00:00:00.000Z" }),
        ];
        const { database } = await buildDatabase(assets);

        const matches = await searchAssets(database, "", undefined, "2021-01-01", "2023-12-31", 10);

        expect(matches.map(asset => asset._id)).toEqual([ ID_C ]);
    });

    test("stops at the requested limit", async () => {
        const assets = [
            makeAsset({ _id: ID_A, origFileName: "one.jpg" }),
            makeAsset({ _id: ID_B, origFileName: "two.jpg" }),
            makeAsset({ _id: ID_C, origFileName: "three.jpg" }),
        ];
        const { database } = await buildDatabase(assets);

        const matches = await searchAssets(database, ".jpg", undefined, undefined, undefined, 2);

        expect(matches).toHaveLength(2);
    });
});

describe("getAsset", () => {
    test("returns the asset when present", async () => {
        const { database } = await buildDatabase([ makeAsset({ _id: ID_A, origFileName: "found.jpg" }) ]);

        const asset = await getAsset(database, ID_A);

        expect(asset?.origFileName).toBe("found.jpg");
    });

    test("returns undefined when missing", async () => {
        const { database } = await buildDatabase([]);

        const asset = await getAsset(database, ID_B);

        expect(asset).toBeUndefined();
    });
});

describe("streamAssetToFile", () => {
    test("streams bytes from storage to disk, creating parent directories", async () => {
        const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "asset-query-test-"));
        try {
            const storage = new MockStorage();
            const payload = Buffer.from("hello world");
            await storage.write("asset/original-asset-id", "application/octet-stream", payload);

            const outputPath = path.join(tempDir, "out", "nested", "original.bin");
            const bytes = await streamAssetToFile(storage, "original-asset-id", outputPath, "original");

            expect(bytes).toBe(payload.length);
            const written = await fs.readFile(outputPath);
            expect(written.equals(payload)).toBe(true);
        }
        finally {
            await fs.rm(tempDir, { recursive: true, force: true });
        }
    });

    test("maps type 'display' to the display/ storage prefix", async () => {
        const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "asset-query-test-"));
        try {
            const storage = new MockStorage();
            const payload = Buffer.from("display-bytes");
            await storage.write("display/display-asset-id", "image/jpeg", payload);

            const outputPath = path.join(tempDir, "display.bin");
            const bytes = await streamAssetToFile(storage, "display-asset-id", outputPath, "display");

            expect(bytes).toBe(payload.length);
        }
        finally {
            await fs.rm(tempDir, { recursive: true, force: true });
        }
    });
});
