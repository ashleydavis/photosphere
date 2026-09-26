//
// Generates the golden fixtures used by the serialization-zig unit tests.
// Run from the repo root with: bun run packages-zig/serialization-zig/src/test/fixtures/generate.ts
//
// Every fixture is produced by the TypeScript implementation (the `serialization` package and the npm `bson` library),
// so the Zig tests prove byte-level parity with TypeScript.
//

import * as fs from "fs";
import * as path from "path";
import { createHash } from "crypto";
import { Binary, Double, Int32, Long, ObjectId, UUID, deserialize, serialize } from "bson";
import {
    BinarySerializer,
    CompressedBinaryDeserializer,
    CompressedBinarySerializer,
    load,
    save,
    type IDeserializer,
    type ISerializer,
} from "serialization";

//
// The directory this script lives in (fixtures are written next to it).
//
const fixturesDir = path.dirname(new URL(import.meta.url).pathname);

//
// The directory of the checked in v6 test database.
//
const v6DatabaseDir = path.resolve(fixturesDir, "../../../../../test/dbs/v6");

//
// Writes a fixture file relative to the fixtures directory.
//
function writeFixture(relativePath: string, data: Buffer | string): void {
    const fullPath = path.join(fixturesDir, relativePath);
    fs.mkdirSync(path.dirname(fullPath), { recursive: true });
    fs.writeFileSync(fullPath, data);
}

//
// Throws when a condition does not hold (sanity checks on the TypeScript side).
//
function assert(condition: boolean, message: string): void {
    if (!condition) {
        throw new Error(`Fixture sanity check failed: ${message}`);
    }
}

//
// Minimal in-memory storage with the read/write methods used by save and load.
//
class MemoryStorage {
    // Files stored by path.
    files = new Map<string, Buffer>();

    // Reads a file (undefined when missing).
    async read(filePath: string): Promise<Buffer | undefined> {
        return this.files.get(filePath);
    }

    // Writes a file.
    async write(filePath: string, _contentType: string | undefined, data: Buffer): Promise<void> {
        this.files.set(filePath, Buffer.from(data));
    }
}

//
// Writes the same sequence of values with every write method (used for the plain and compressed fixtures).
//
function writeAllTypes(serializer: ISerializer): void {
    serializer.writeUInt32(0xDEADBEEF);
    serializer.writeInt32(-12345);
    serializer.writeUInt64(BigInt("18446744073709551615"));
    serializer.writeInt64(BigInt("-9223372036854775808"));
    serializer.writeFloat(3.14159);
    serializer.writeDouble(Math.PI);
    serializer.writeBoolean(true);
    serializer.writeBoolean(false);
    serializer.writeUInt8(255);
    serializer.writeString("Hello 🚀 émojis");
    serializer.writeBuffer(Buffer.from([0, 1, 2, 255]));
    serializer.writeBytes(Buffer.from([9, 8, 7]));
    serializer.writeBSON({ name: "test", value: 42, nested: { array: [1, 2, 3], bool: true } });
}

//
// Serializer functions and data used by the save/load fixtures.
//
const saveData = { name: "test", value: 42 };
const serializeJson = (data: any, serializer: ISerializer): void => {
    serializer.writeString(JSON.stringify(data));
};
const deserializeJson = (deserializer: IDeserializer): any => {
    return JSON.parse(deserializer.readString());
};

async function main(): Promise<void> {

    //
    // BinarySerializer output.
    //
    const binarySerializer = new BinarySerializer();
    writeAllTypes(binarySerializer);
    writeFixture("binary-serializer.bin", binarySerializer.getBuffer());

    //
    // CompressedBinarySerializer output from Node's gzip, framed by plain values.
    //
    const compressedMain = new BinarySerializer();
    compressedMain.writeUInt32(7);
    const compressedSerializer = new CompressedBinarySerializer(compressedMain);
    writeAllTypes(compressedSerializer);
    compressedSerializer.finish();
    compressedMain.writeUInt32(8);
    writeFixture("compressed-node.bin", compressedMain.getBuffer());

    const emptyMain = new BinarySerializer();
    new CompressedBinarySerializer(emptyMain).finish();
    writeFixture("compressed-empty-node.bin", emptyMain.getBuffer());

    const largeMain = new BinarySerializer();
    const largeSerializer = new CompressedBinarySerializer(largeMain);
    for (let index = 0; index < 1000; index++) {
        largeSerializer.writeString(`String number ${index} with some content`);
    }
    largeSerializer.finish();
    writeFixture("compressed-large-node.bin", largeMain.getBuffer());

    //
    // save() output and legacy framings.
    //
    const storage = new MemoryStorage();
    await save(storage as any, "save.bin", saveData, 1, "TEST", serializeJson);
    writeFixture("save-v6.bin", storage.files.get("save.bin")!);

    const legacyChecksumData = new BinarySerializer();
    legacyChecksumData.writeUInt32(1);
    legacyChecksumData.writeString(JSON.stringify({ name: "legacy with checksum", value: 1 }));
    const legacyChecksumPayload = legacyChecksumData.getBuffer();
    const legacyChecksum = Buffer.concat([legacyChecksumPayload, createHash("sha256").update(legacyChecksumPayload).digest()]);
    writeFixture("legacy-checksum.bin", legacyChecksum);

    const legacyNoChecksum = new BinarySerializer();
    legacyNoChecksum.writeUInt32(1);
    legacyNoChecksum.writeString(JSON.stringify({ name: "legacy without checksum", value: 2 }));
    writeFixture("legacy-no-checksum.bin", legacyNoChecksum.getBuffer());

    const legacyShort = new BinarySerializer();
    legacyShort.writeUInt32(1);
    legacyShort.writeString(JSON.stringify({ a: 1 }));
    writeFixture("legacy-short.bin", legacyShort.getBuffer());

    for (const fileName of ["save-v6.bin", "legacy-checksum.bin", "legacy-no-checksum.bin", "legacy-short.bin"]) {
        storage.files.set(fileName, fs.readFileSync(path.join(fixturesDir, fileName)));
        const loaded = await load(storage as any, fileName, "TEST", { 1: deserializeJson });
        assert(loaded !== undefined, `load ${fileName}`);
    }

    //
    // BSON documents of every supported type, serialized by npm bson.
    //
    const bsonCases: Record<string, any> = {
        "empty": {},
        "strings": { a: "hello", unicode: "🚀 émojis 中文", empty: "" },
        "numbers": {
            zero: 0,
            one: 1,
            neg: -1,
            int32max: 2147483647,
            int32min: -2147483648,
            above: 2147483648,
            below: -2147483649,
            pi: 3.14159,
            negzero: -0,
            safe: 9007199254740991,
            unsafe: 9007199254740993,
            nan: NaN,
            inf: Infinity,
            ninf: -Infinity,
            frac: 0.5,
        },
        "bigint": { big: BigInt("1234567890123456789"), small: BigInt(5), neg: BigInt(-5) },
        "long": { small: Long.fromNumber(42), limit: Long.fromString("9007199254740992"), large: Long.fromString("9007199254740993"), negLarge: Long.fromString("-9223372036854775808") },
        "constants": { t: true, f: false, n: null, u: undefined },
        "dates": { d: new Date("2023-01-01"), epoch: new Date(0), neg: new Date(-86400000), ms: new Date(1700000000123) },
        "binary": {
            buf: Buffer.from("hello"),
            empty: Buffer.alloc(0),
            uuid: new UUID("89171cd9-a652-4047-b869-1154bf2c95a1"),
            user: new Binary(Buffer.from([1, 2, 3]), 0x80),
            old: new Binary(Buffer.from([4, 5]), 2),
        },
        "object-id": { id: new ObjectId("507f1f77bcf86cd799439011") },
        "wrappers": { i: new Int32(5), d: new Double(5) },
        "nested": {
            name: "test",
            value: 42,
            nested: {
                array: [1, 2, 3],
                bool: true,
                date: new Date("2023-01-01"),
                deep: { level: 3, data: "deep value" },
            },
            tags: ["tag1", "tag2"],
            mixed: [1, "two", null, undefined, { x: 1 }, [2]],
        },
        "key-order": { b: 1, "2": "two", a: 2, "1": "one", "01": "not an index" },
    };
    const bsonSummary: Record<string, string> = {};
    for (const [name, value] of Object.entries(bsonCases)) {
        const bytes = Buffer.from(serialize(value));
        writeFixture(`bson/${name}.bson`, bytes);

        // What TypeScript writes when it re-serializes what it deserialized.
        const reencoded = Buffer.from(serialize(deserialize(bytes)));
        writeFixture(`bson/${name}.reencoded.bson`, reencoded);
        bsonSummary[name] = createHash("sha256").update(bytes).digest("hex");
    }

    // The BSON undefined type (0x06) cannot be produced by npm bson, so it is crafted by hand: { u: undefined(0x06), x: int32 1 }.
    const undefinedWire = Buffer.from([
        0x00, 0x00, 0x00, 0x00,
        0x06, 0x75, 0x00,
        0x10, 0x78, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x00,
    ]);
    undefinedWire.writeInt32LE(undefinedWire.length, 0);
    const undefinedDecoded = deserialize(undefinedWire);
    assert(undefinedDecoded.u === undefined && "u" in undefinedDecoded, "undefined wire value decodes as undefined");
    writeFixture("bson/undefined-wire.bson", undefinedWire);
    writeFixture("bson/undefined-wire.reencoded.bson", Buffer.from(serialize(undefinedDecoded)));

    //
    // Summary of real v6 database files, as TypeScript reads them.
    //
    const shardBuffer = fs.readFileSync(path.join(v6DatabaseDir, ".db/bson/collections/metadata/shards/96"));
    const shardRecords: any[] = [];
    await load(
        { read: async () => shardBuffer } as any,
        "shard",
        "SHAR",
        {
            1: (deserializer: IDeserializer) => {
                const count = deserializer.readUInt32();
                for (let index = 0; index < count; index++) {
                    const id = deserializer.readBytes(16).toString("hex");
                    const fields = deserializer.readBSON<any>();
                    shardRecords.push({ id, keys: Object.keys(fields), hash: fields.hash, width: fields.width });
                }
                return shardRecords;
            },
            2: () => {
                throw new Error("Unexpected v2 shard");
            },
        }
    );
    const filesTreeBuffer = fs.readFileSync(path.join(v6DatabaseDir, ".db/files.dat"));
    let filesTreeSummary: any = undefined;
    await load(
        { read: async () => filesTreeBuffer } as any,
        "files.dat",
        "FTRE",
        {
            6: (deserializer: IDeserializer) => {
                const databaseMetadata = deserializer.readBSON<any>();
                const id = deserializer.readBytes(16).toString("hex");
                const stringTableDeserializer = new CompressedBinaryDeserializer(deserializer);
                const stringCount = stringTableDeserializer.readUInt32();
                const strings: string[] = [];
                for (let index = 0; index < stringCount; index++) {
                    strings.push(stringTableDeserializer.readString());
                }
                filesTreeSummary = { databaseMetadata, id, strings };
                return filesTreeSummary;
            },
        }
    );
    writeFixture("v6-summary.json", JSON.stringify({ shardRecords, filesTree: filesTreeSummary }, null, 4) + "\n");

    console.log(`Wrote fixtures to ${fixturesDir}`);
    console.log(JSON.stringify(bsonSummary, null, 4));
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
