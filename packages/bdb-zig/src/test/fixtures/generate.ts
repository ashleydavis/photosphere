//
// Generates the golden fixtures used by the bdb-zig unit tests.
// Run from the repo root with: bun run packages/bdb-zig/src/test/fixtures/generate.ts
//
// Every fixture is produced by the TypeScript implementation (the `bdb` package, npm `json-stable-stringify`, npm `bson`
// and JavaScript itself), so the Zig tests prove parity with TypeScript:
//
// - hash-records.json: hashRecord (json-stable-stringify + SHA-256) of every record in the checked in test databases
//   and of synthetic records that cover every BSON value type and edge case.
// - js-values.json: Number.prototype.toString, Number(string), Date.parse, String(date) and localeCompare results.
// - scenario-*.json: the files a database contains after replaying a sequence of operations (see the scenario
//   functions below, which scenarios.zig replays in Zig). Plain files are recorded by SHA-256; gzip merkle tree
//   files by their loaded content (gzip bytes are not expected to match).
//

process.env.TZ = "UTC";

import * as fs from "fs";
import * as path from "path";
import { createHash } from "crypto";
import stringify from "json-stable-stringify";
import { Binary, Double, Int32, Long, ObjectId, UUID, deserialize, serialize } from "bson";
import { BsonDatabase, hashRecord, type IInternalRecord } from "bdb";
import { MockStorage } from "storage";
import { TestUuidGenerator, TimestampProvider } from "utils";
import { loadTree } from "merkle-tree";
import { save } from "serialization";

//
// The directory this script lives in (fixtures are written next to it).
//
const fixturesDir = path.dirname(new URL(import.meta.url).pathname);

//
// The directory of the checked in test databases.
//
const testDbsDir = path.resolve(fixturesDir, "../../../../../test/dbs");

//
// Writes a fixture file relative to the fixtures directory.
//
function writeFixture(relativePath: string, data: Buffer | string): void {
    const fullPath = path.join(fixturesDir, relativePath);
    fs.mkdirSync(path.dirname(fullPath), { recursive: true });
    fs.writeFileSync(fullPath, data);
}

//
// Hex SHA-256 of a string or buffer.
//
function sha256Hex(data: string | Buffer): string {
    return createHash("sha256").update(data).digest("hex");
}

//
// Lists every file below a directory (relative paths with forward slashes, sorted).
//
function listFilesRecursive(rootDir: string, relativeDir: string = ""): string[] {
    const results: string[] = [];
    for (const entry of fs.readdirSync(path.join(rootDir, relativeDir), { withFileTypes: true })) {
        const relativePath = relativeDir ? `${relativeDir}/${entry.name}` : entry.name;
        if (entry.isDirectory()) {
            results.push(...listFilesRecursive(rootDir, relativePath));
        }
        else {
            results.push(relativePath);
        }
    }
    return results.sort();
}

//
// Hashes every record of every v6 layout test database (the shards under .db/bson/collections).
//
async function realRecordHashes(): Promise<any[]> {
    const results: any[] = [];
    const databaseDirs = ["v6", "1-asset", "1-asset-2", "50-assets", "no-assets",
        "multi-set/93886ac9-16e4-48e6-983b-ec65566018d0", "multi-set/93886ac9-16e4-48e6-983b-ec65566018d1"];
    for (const databaseDir of databaseDirs) {
        const storage = loadDirectoryIntoStorage(path.join(testDbsDir, databaseDir, ".db/bson"), ".db/bson");
        const database = new BsonDatabase(storage, ".db/bson", new TestUuidGenerator(), new TimestampProvider());
        const collection = database.collection("metadata");
        for await (const record of collection.iterateRecords()) {
            const jsonString = stringify(record.fields) || "";
            const hashedItem = hashRecord(record._id, record.fields);
            results.push({
                database: databaseDir,
                id: record._id,
                stable: jsonString,
                hash: hashedItem.hash.toString("hex"),
                length: hashedItem.length,
            });
        }
    }
    return results;
}

//
// Synthetic records that cover every value type and edge case of json-stable-stringify after BSON deserialization.
//
function syntheticRecords(): { name: string, fields: any }[] {
    return [
        { name: "empty", fields: {} },
        { name: "numbers", fields: { a: 0.1, b: 1e21, c: 1e-7, d: -0, e: 123e-20, f: 2 ** 53 + 2, g: 1.5e300, h: 5e-324, i: 100, j: 1e20, k: 0.000001, l: -12.5, m: 2147483647, n: 2147483648, o: -2147483649, p: 1 / 3, q: 123456789012345680000 } },
        { name: "special numbers", fields: { nan: NaN, inf: Infinity, ninf: -Infinity } },
        { name: "long", fields: { big: Long.fromString("9007199254740993"), negative: Long.fromString("-9007199254740993") } },
        { name: "wrappers", fields: { int32: new Int32(5), double: new Double(5) } },
        { name: "strings", fields: { plain: "hello", quote: "say \"hi\"", backslash: "a\\b", controls: "\b\f\n\r\t\u0000\u001f\u007f", unicode: "café 中文 😀", separators: "  ", empty: "" } },
        { name: "key order", fields: { b: 1, a: 2, "10": 3, "9": 4, "é": 5, Z: 6, "😀": 7, "￿": 8, "": 9, "a b": 10, _id: 11 } },
        { name: "nested", fields: { outer: { z: [1, { y: 2, x: [3, [4, null]] }], a: { } }, list: [[], {}, [[]]] } },
        { name: "dates", fields: { epoch: new Date(0), recent: new Date(Date.UTC(2024, 1, 29, 13, 45, 7, 89)), negative: new Date(-1), ancient: new Date(Date.UTC(-50, 0, 1)), future: new Date(Date.UTC(20000, 5, 1)), inArray: [new Date(86400000)] } },
        { name: "binary", fields: { buffer: new Binary(Buffer.from([1, 2, 3, 250])), empty: new Binary(Buffer.alloc(0)), uuid: new UUID("0f8fad5b-d9cb-469f-a165-70867728950e"), subtype: new Binary(Buffer.from("xyz"), 128), oid: new ObjectId("507f1f77bcf86cd799439011") } },
        { name: "null and undefined", fields: { n: null, u: undefined, arr: [undefined, null, 1], obj: { u: undefined } } },
        { name: "booleans", fields: { t: true, f: false } },
        { name: "asset like", fields: { hash: "abc123", origFileName: "IMG_0001.JPG", photoDate: new Date(Date.UTC(2021, 6, 4, 10, 11, 12)), width: 4032, height: 3024, location: "Brisbane, Australia", coordinates: { lat: -27.4698, lng: 153.0251 }, labels: ["beach", "sunset"], properties: { exif: { Make: "Apple", FNumber: 1.8 } } } },
    ];
}

//
// Hashes the synthetic records after a BSON round trip (records are always hashed after being deserialized).
//
function syntheticRecordHashes(): any[] {
    return syntheticRecords().map(({ name, fields }) => {
        const bsonBytes = serialize(fields, { ignoreUndefined: false });
        const roundTripped = deserialize(bsonBytes);
        const jsonString = stringify(roundTripped) || "";
        const hashedItem = hashRecord("00000000-0000-4000-8000-000000000000", roundTripped);
        return {
            name,
            bson: Buffer.from(bsonBytes).toString("base64"),
            stable: jsonString,
            hash: hashedItem.hash.toString("hex"),
            length: hashedItem.length,
        };
    });
}

//
// A small seeded pseudo random number generator (mulberry32) so the fixtures are reproducible.
//
function makeRandom(seed: number): () => number {
    let state = seed >>> 0;
    return () => {
        state = (state + 0x6D2B79F5) >>> 0;
        let value = state;
        value = Math.imul(value ^ (value >>> 15), value | 1);
        value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
        return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
    };
}

//
// Returns the bits of a double as 16 hex digits.
//
function doubleBits(value: number): string {
    const buffer = Buffer.alloc(8);
    buffer.writeDoubleBE(value);
    return buffer.toString("hex");
}

//
// JavaScript value semantics used by the sort index and json-stable-stringify.
//
function jsValues(): any {
    const random = makeRandom(12345);
    const numbers: number[] = [0.1, 0.2, 0.3, 1e21, 1e-7, 1e-6, 123e-20, 2 ** 53 + 2, 1.5e300, 5e-324, 100, 1e20, 0.000001,
        -12.5, 1 / 3, 2 / 3, 123456789012345680000, 1.7976931348623157e308, 2.2250738585072014e-308, 4.35, 0.5, 9007199254740993,
        1e23, 5e-7, 123.456, -1e-7, 1e100, 3.14159, 2 ** 31, 2 ** 64, 1.2e-5, 999999999999999900000, 0.000123];
    for (let index = 0; index < 3000; index++) {
        const buffer = Buffer.alloc(8);
        buffer.writeUInt32BE(Math.floor(random() * 4294967296), 0);
        buffer.writeUInt32BE(Math.floor(random() * 4294967296), 4);
        const value = buffer.readDoubleBE(0);
        if (Number.isFinite(value)) {
            numbers.push(value);
        }
        numbers.push((random() - 0.5) * Math.pow(10, Math.floor(random() * 60) - 30));
        numbers.push(Math.round(random() * 1e6) / 100);
    }

    const numberStrings = ["", " ", "12", " 12 ", "1.5", ".5", "5.", "1e3", "1E-3", "+4", "-4", "0x1F", "0o17", "0b101", "Infinity",
        "-Infinity", "infinity", "abc", "12abc", "1_000", "--1", "0x", " 12 ", "\t\n7\r", "1e", "NaN", "00012", "-0"];

    const dateStrings = ["2020-01-01", "2020-01-01T10:20:30Z", "2020-01-01T10:20:30.123Z", "2020-01-01T10:20:30.1234567Z",
        "2020-01-01T10:20:30+02:00", "2020-01-01T10:20:30-0530", "2020-01-01T10:20", "2020-01-01T10:20:30", "2020",
        "2020-06", "+020000-01-01T00:00:00.000Z", "-000050-01-01T00:00:00.000Z", "2020-02-30", "2020-13-01", "not a date",
        "", "2020-01-01T24:00:00Z", "2020-01-01T25:00:00Z", "2019-02-29", "2020-02-29T12:00:00.5Z", "1970-01-01T00:00:00.000Z"];

    const dateTimes = [0, -1, 86400000 * 365.25 * 30, Date.UTC(2024, 1, 29, 13, 45, 7, 89), Date.UTC(-50, 0, 1), Date.UTC(20000, 5, 1),
        Date.UTC(1969, 11, 31, 23, 59, 59, 999), 8.64e15, -8.64e15];

    const localeStrings = ["a", "A", "b", "B", "ab", "aB", "Ab", "AB", "a-b", "a_b", "a b", "a.b", "a1", "a10", "a2", "1", "10", "2",
        "0", "9", "-", "_", " ", "", "abc", "abd", "abcd", "ABC", "a~", "a!", "a$", "a/", "a\\", "a@", "a#", "a%", "a^", "a&", "a*",
        "a(", "a)", "a[", "a]", "a{", "a}", "a<", "a>", "a=", "a+", "a|", "a'", "a\"", "a`", "a;", "a:", "a,", "a?",
        "0f8fad5b-d9cb-469f-a165-70867728950e", "0f8fad5b-d9cb-469f-a165-70867728950f", "0f8fad5bd9cb469fa16570867728950e",
        "dup-0", "dup-1", "deadbeef", "DEADBEEF", "h00000001", "h00000010", "Z", "z", "file-1.jpg", "file-10.jpg", "file-2.jpg"];
    const localeMatrix = localeStrings.map(left => localeStrings.map(right => {
        const result = left.localeCompare(right);
        return result < 0 ? "-" : result > 0 ? "+" : "0";
    }).join(""));

    return {
        numbers: numbers.map(value => ({ bits: doubleBits(value), text: String(value) })),
        numberStrings: numberStrings.map(text => {
            const value = Number(text);
            return { text, bits: doubleBits(value), isNaN: Number.isNaN(value) };
        }),
        dates: dateStrings.map(text => {
            const time = Date.parse(text);
            return { text, time: Number.isNaN(time) ? null : time };
        }),
        dateTimes: dateTimes.map(time => ({ time, toString: String(new Date(time)), toJSON: new Date(time).toJSON() })),
        localeStrings,
        localeMatrix,
    };
}

//
// Copies every file below a directory into a MockStorage under a prefix.
//
function loadDirectoryIntoStorage(directory: string, prefix: string): MockStorage {
    const storage = new MockStorage();
    for (const relativePath of listFilesRecursive(directory)) {
        storage.write(`${prefix}/${relativePath}`, undefined, fs.readFileSync(path.join(directory, relativePath)));
    }
    return storage;
}

//
// The time the scenario dates are based on.
//
const BASE_TIME = Date.UTC(2020, 0, 1);

//
// The fields of scenario record `index` (scenarios.zig makeFields builds the same document).
//
function makeFields(index: number, variant: number): any {
    const fields: any = {};
    fields.hash = index % 7 === 0 ? `dup-${variant}` : sha256Hex(`record-${index}-${variant}`);
    fields.name = `file-${index}.jpg`;
    const dateKind = index % 5;
    if (dateKind === 1) {
        fields.photoDate = new Date(BASE_TIME + index * 3600000 * (variant + 1)).toISOString();
    }
    else if (dateKind !== 0) {
        fields.photoDate = new Date(BASE_TIME + index * 3600000 * (variant + 1));
    }
    fields.size = index * 1000 + variant;
    fields.ratio = index / 7;
    fields.tags = ["a", index];
    fields.location = index % 3 === 0 ? null : { lat: index * 0.5, lng: -index };
    return fields;
}

//
// Walks a sort index page by page (like the TS list command) and returns the record ids in page order.
//
async function walkSortIndex(database: BsonDatabase, fieldName: string, direction: "asc" | "desc"): Promise<string[]> {
    const sortIndex = database.collection("metadata").sortIndex(fieldName, direction);
    const ids: string[] = [];
    let pageId: string | undefined = undefined;
    while (true) {
        const page = await sortIndex.getPage(pageId);
        for (const record of page.records) {
            ids.push(record._id);
        }
        if (!page.nextPageId) {
            break;
        }
        pageId = page.nextPageId;
    }
    return ids;
}

//
// Records the files of a storage: every file by size and SHA-256, merkle tree files also by loaded content.
//
async function snapshot(storage: MockStorage, sortIndexes: [string, "asc" | "desc"][]): Promise<any> {
    const listing = await storage.listFiles("", 1000000);
    const files: any[] = [];
    const trees: any = {};
    for (const filePath of listing.names.sort()) {
        const data = (await storage.read(filePath))!;
        const typeCode = data.length >= 8 ? data.subarray(4, 8).toString("latin1") : "";
        if (typeCode !== "COLT" && typeCode !== "BDBT") {
            files.push({ path: filePath, size: data.length, sha256: sha256Hex(data) });
        }
        else {
            // Merkle tree files are gzip compressed and hold lastModified times, so only their content is recorded.
            files.push({ path: filePath });
            const tree = (await loadTree<any>(filePath, storage, typeCode))!;
            const leaves: any[] = [];
            const collectLeaves = (node: any): void => {
                if (!node) {
                    return;
                }
                if (node.nodeCount === 1) {
                    leaves.push([node.name, node.contentHash.toString("hex"), node.size]);
                    return;
                }
                collectLeaves(node.left);
                collectLeaves(node.right);
            };
            collectLeaves(tree.sort);
            const leavesJson = JSON.stringify(leaves);
            trees[filePath] = {
                id: tree.id,
                version: tree.version,
                leafCount: leaves.length,
                leavesSha256: sha256Hex(leavesJson),
                leaves: leaves.length <= 200 ? leaves : undefined,
                merkleHash: tree.merkle ? tree.merkle.hash.toString("hex") : null,
                merkleNodeCount: tree.merkle ? tree.merkle.nodeCount : 0,
            };
        }
    }
    const database = new BsonDatabase(storage, ".db/bson", new TestUuidGenerator(), new TimestampProvider());
    const walks: any = {};
    for (const [fieldName, direction] of sortIndexes) {
        const ids = await walkSortIndex(database, fieldName, direction);
        walks[`${fieldName}_${direction}`] = { count: ids.length, sha256: sha256Hex(ids.join("\n")) };
    }
    const rootTree = trees[".db/bson/db.dat"];
    return { files, trees, walks, rootHash: rootTree ? rootTree.merkleHash : null };
}

//
// The sort indexes a media file database has.
//
const MEDIA_SORT_INDEXES: [string, "asc" | "desc"][] = [["hash", "asc"], ["photoDate", "desc"]];

//
// Number of records in the create, update and build scenarios.
//
const SCENARIO_RECORD_COUNT = 2000;

//
// Scenario "create" (the replicate flow into a new database): ensure both sort indexes on an empty collection,
// set SCENARIO_RECORD_COUNT records, commit. Scenario "update" then opens the same storage with a new database
// instance (continuing the same uuid generators): updates every third record, deletes every record below 1000 and most
// of the others below 1400 (which empties the oldest photoDate_desc leaf), adds 300 new records and commits.
//
async function createAndUpdateScenarios(): Promise<void> {
    const storage = new MockStorage();
    const uuidGenerator = new TestUuidGenerator();
    const recordIdGenerator = new TestUuidGenerator();
    const ids: string[] = [];

    const database = new BsonDatabase(storage, ".db/bson", uuidGenerator, new TimestampProvider());
    const collection = database.collection("metadata");
    await collection.sortIndex("hash", "asc").ensure(collection, "string");
    await collection.sortIndex("photoDate", "desc").ensure(collection, "date");
    for (let index = 0; index < SCENARIO_RECORD_COUNT; index++) {
        ids.push(recordIdGenerator.generate());
        await collection.setInternalRecord({ _id: ids[index], fields: makeFields(index, 0), metadata: { timestamp: 1700000000000 + index } });
    }
    await database.commit();
    writeFixture("scenario-create.json", JSON.stringify(await snapshot(storage, MEDIA_SORT_INDEXES), null, 1));

    const pagesBefore = (await storage.listFiles(".db/bson/indexes", 100000)).names.length;
    const updateDatabase = new BsonDatabase(storage, ".db/bson", uuidGenerator, new TimestampProvider());
    const updateCollection = updateDatabase.collection("metadata");
    for (let index = 0; index < SCENARIO_RECORD_COUNT; index++) {
        if (index % 3 === 0) {
            await updateCollection.setInternalRecord({ _id: ids[index], fields: makeFields(index, 1), metadata: { timestamp: 1800000000000 + index } });
        }
    }
    for (let index = 0; index < SCENARIO_RECORD_COUNT; index++) {
        if (index < 1000 || (index % 3 !== 0 && index < 1400)) {
            await updateCollection.deleteOne(ids[index]);
        }
    }
    for (let index = SCENARIO_RECORD_COUNT; index < SCENARIO_RECORD_COUNT + 300; index++) {
        ids.push(recordIdGenerator.generate());
        await updateCollection.setInternalRecord({ _id: ids[index], fields: makeFields(index, 0), metadata: { timestamp: 1700000000000 + index } });
    }
    await updateDatabase.commit();
    const pagesAfter = (await storage.listFiles(".db/bson/indexes", 100000)).names.length;
    console.log(`update scenario: index files ${pagesBefore} -> ${pagesAfter}`);
    writeFixture("scenario-update.json", JSON.stringify(await snapshot(storage, MEDIA_SORT_INDEXES), null, 1));
}

//
// Scenario "build": set SCENARIO_RECORD_COUNT records without sort indexes and commit, then open the storage with a new
// database instance, ensure both sort indexes (building them from the shards) and commit.
//
async function buildScenario(): Promise<void> {
    const storage = new MockStorage();
    const uuidGenerator = new TestUuidGenerator();
    const recordIdGenerator = new TestUuidGenerator();

    const database = new BsonDatabase(storage, ".db/bson", uuidGenerator, new TimestampProvider());
    const collection = database.collection("metadata");
    for (let index = 0; index < SCENARIO_RECORD_COUNT; index++) {
        await collection.setInternalRecord({ _id: recordIdGenerator.generate(), fields: makeFields(index, 0), metadata: { timestamp: 1700000000000 + index } });
    }
    await database.commit();

    const buildDatabase = new BsonDatabase(storage, ".db/bson", uuidGenerator, new TimestampProvider());
    const buildCollection = buildDatabase.collection("metadata");
    await buildCollection.sortIndex("hash", "asc").ensure(buildCollection, "string");
    await buildCollection.sortIndex("photoDate", "desc").ensure(buildCollection, "date");
    await buildDatabase.commit();
    writeFixture("scenario-build.json", JSON.stringify(await snapshot(storage, MEDIA_SORT_INDEXES), null, 1));
}

//
// Scenario "existing": the 50-assets test database (built by the TypeScript CLI). Every fourth record gets a new hash,
// the next one a new photo date, every fourth from the third on (below 20) is deleted, then 5 new records are added.
//
async function existingScenario(): Promise<void> {
    const storage = loadDirectoryIntoStorage(path.join(testDbsDir, "50-assets/.db/bson"), ".db/bson");
    const uuidGenerator = new TestUuidGenerator();
    const recordIdGenerator = new TestUuidGenerator();
    const database = new BsonDatabase(storage, ".db/bson", uuidGenerator, new TimestampProvider());
    const collection = database.collection("metadata");
    const records: IInternalRecord[] = [];
    for await (const record of collection.iterateRecords()) {
        records.push(record);
    }
    for (let index = 0; index < records.length; index++) {
        const record = records[index];
        if (index % 4 === 0) {
            await collection.setInternalRecord({ _id: record._id, fields: { ...record.fields, hash: sha256Hex(`changed-${index}`) }, metadata: record.metadata });
        }
        else if (index % 4 === 1) {
            await collection.setInternalRecord({ _id: record._id, fields: { ...record.fields, photoDate: new Date(BASE_TIME + index * 86400000) }, metadata: record.metadata });
        }
        else if (index % 4 === 2 && index < 20) {
            await collection.deleteOne(record._id);
        }
    }
    for (let index = 0; index < 5; index++) {
        await collection.setInternalRecord({ _id: recordIdGenerator.generate(), fields: makeFields(index, 0), metadata: { timestamp: 1700000000000 + index } });
    }
    await database.commit();
    writeFixture("scenario-existing.json", JSON.stringify(await snapshot(storage, MEDIA_SORT_INDEXES), null, 1));
}

//
// Scenario "leaves": ensure a hash_asc index on an empty collection and add 1600 records with increasing string hashes
// (one leaf split), commit, then with a new database instance delete the first 800 records (which empties the first
// leaf and deletes the split boundary record through the findByValue fallback), add 50 records and commit.
//
async function leavesScenario(): Promise<void> {
    const storage = new MockStorage();
    const uuidGenerator = new TestUuidGenerator();
    const recordIdGenerator = new TestUuidGenerator();
    const ids: string[] = [];
    const database = new BsonDatabase(storage, ".db/bson", uuidGenerator, new TimestampProvider());
    const collection = database.collection("metadata");
    await collection.sortIndex("hash", "asc").ensure(collection, "string");
    for (let index = 0; index < 1600; index++) {
        ids.push(recordIdGenerator.generate());
        await collection.setInternalRecord({ _id: ids[index], fields: { hash: `h${String(index).padStart(8, "0")}`, n: index }, metadata: {} });
    }
    await database.commit();

    const pagesBefore = (await storage.listFiles(".db/bson/indexes", 100000)).names.length;
    const updateDatabase = new BsonDatabase(storage, ".db/bson", uuidGenerator, new TimestampProvider());
    const updateCollection = updateDatabase.collection("metadata");
    for (let index = 0; index < 800; index++) {
        await updateCollection.deleteOne(ids[index]);
    }
    for (let index = 1600; index < 1650; index++) {
        ids.push(recordIdGenerator.generate());
        await updateCollection.setInternalRecord({ _id: ids[index], fields: { hash: `h${String(index).padStart(8, "0")}`, n: index }, metadata: {} });
    }
    await updateDatabase.commit();
    const pagesAfter = (await storage.listFiles(".db/bson/indexes", 100000)).names.length;
    console.log(`leaves scenario: index files ${pagesBefore} -> ${pagesAfter}`);
    writeFixture("scenario-leaves.json", JSON.stringify(await snapshot(storage, [["hash", "asc"]]), null, 1));
}

//
// Number of records in the large scenario (enough leaf splits for the root internal node to split).
//
const LARGE_RECORD_COUNT = 93000;

//
// Scenario "large": drives a hash_asc SortIndex directly (no shards, so no per record merkle tree work): ensure on an
// empty collection, add LARGE_RECORD_COUNT records whose hashes increase (every insert goes to the last leaf, so the
// root internal node splits), give every seventh of the first 2100 records a smaller hash (updateRecord), delete
// records 5000 to 5999 (deleteRecord) and commit the index.
//
async function largeScenario(): Promise<void> {
    const storage = new MockStorage();
    const uuidGenerator = new TestUuidGenerator();
    const recordIdGenerator = new TestUuidGenerator();
    const database = new BsonDatabase(storage, ".db/bson", uuidGenerator, new TimestampProvider());
    const collection = database.collection("metadata");
    const sortIndex = collection.sortIndex("hash", "asc");
    await sortIndex.ensure(collection, "string");
    const records: IInternalRecord[] = [];
    for (let index = 0; index < LARGE_RECORD_COUNT; index++) {
        records.push({ _id: recordIdGenerator.generate(), fields: { hash: `h${String(index).padStart(8, "0")}` }, metadata: {} });
        await sortIndex.addRecord(records[index]);
    }
    for (let index = 0; index < 2100; index += 7) {
        const updated: IInternalRecord = { _id: records[index]._id, fields: { hash: `g${String(index).padStart(8, "0")}` }, metadata: {} };
        await sortIndex.updateRecord(updated, records[index]);
        records[index] = updated;
    }
    for (let index = 5000; index < 6000; index++) {
        await sortIndex.deleteRecord(records[index]._id, records[index]);
    }
    await sortIndex.commit();
    const internal: any = sortIndex;
    const rootNode = internal.treeNodes.get(internal.rootPageId);
    console.log(`large scenario: ${internal.treeNodes.size} tree nodes, root has ${rootNode.children.length} children`);
    writeFixture("scenario-large.json", JSON.stringify(await snapshot(storage, [["hash", "asc"]]), null, 1));
}

//
// A version 1 shard file (records without metadata), which BsonShard still loads.
//
async function shardV1Fixture(): Promise<void> {
    const storage = new MockStorage();
    const records = [
        { id: "0f8fad5b-d9cb-469f-a165-70867728950e", fields: { hash: "abc", size: 12 } },
        { id: "123e4567-e89b-12d3-a456-426614174000", fields: { hash: "def", photoDate: new Date(Date.UTC(2021, 0, 2)) } },
    ];
    await save(storage, "shard", records, 1, "SHAR", (data, serializer) => {
        serializer.writeUInt32(data.length);
        for (const record of data) {
            serializer.writeBytes(Buffer.from(record.id.replace(/-/g, ""), "hex"));
            serializer.writeBSON(record.fields);
        }
    });
    writeFixture("shard-v1.bin", (await storage.read("shard"))!);
}

//
// Generates every fixture.
//
async function main(): Promise<void> {
    writeFixture("hash-records.json", JSON.stringify({ real: await realRecordHashes(), synthetic: syntheticRecordHashes() }, null, 1));
    writeFixture("js-values.json", JSON.stringify(jsValues(), null, 1));
    await shardV1Fixture();
    await createAndUpdateScenarios();
    await buildScenario();
    await existingScenario();
    await leavesScenario();
    await largeScenario();
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
