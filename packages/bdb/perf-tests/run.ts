//
// Measures what inserting records into a collection costs as the collection grows.
//
// This exists because a real import on a phone spends more time putting records into the database
// than doing anything else, and the cost per record climbs with the size of the database rather
// than staying flat. That is an algorithmic cost, so it shows up here, on a desktop, without a
// device and without the engine bridge in the way.
//
// Run it with: bun run --filter=bdb perf
//
import { FileStorage, IStorage } from "storage";
import { RandomUuidGenerator } from "utils";
import { BsonDatabase } from "../src/lib/database";
import * as fs from "fs/promises";
import * as os from "os";
import * as path from "path";

//
// Wraps a storage and counts what is asked of it, by method name.
//
// The cost that matters is not the arithmetic: on a desktop an insert takes a tenth of a
// millisecond and on a phone it takes three hundred, because every call here crosses the embedded
// engine bridge. So what the phone pays for is the number of calls, and this counts them.
//
//
// Groups a written path by what part of the database it belongs to, so a commit that makes dozens of
// writes says which kind they are rather than only how many.
//
function writeGroup(filePath: string): string {
    if (filePath.includes("/indexes/")) {
        return filePath.endsWith("tree.dat") ? "index-tree" : "index-page";
    }
    if (filePath.includes("/shards/")) {
        return "shard";
    }
    if (filePath.includes("merkle") || filePath.endsWith(".merkle")) {
        return "merkle";
    }
    return "other";
}

function countingStorage(storage: IStorage, counts: Map<string, number>): IStorage {
    const count = (name: string) => {
        counts.set(name, (counts.get(name) ?? 0) + 1);
    };

    return new Proxy(storage, {
        get(target: any, property: string) {
            const value = target[property];
            if (typeof value !== "function") {
                return value;
            }
            return (...args: any[]) => {
                count(property === "write" ? `write:${writeGroup(String(args[0]))}` : property);
                return value.apply(target, args);
            };
        },
    }) as IStorage;
}

//
// A timestamp provider that counts, so runs are comparable and nothing depends on the clock.
//
class CountingTimestampProvider {
    private counter = 0;

    now(): number {
        this.counter += 1;
        return this.counter;
    }

    dateNow(): number {
        return this.now();
    }
}

//
// One asset record, built to be about the size of a real one: the fields a photo carries plus a
// description long enough to stand in for the text a real record holds.
//
function assetRecord(index: number, uuidGenerator: RandomUuidGenerator): any {
    return {
        // A real record id is a UUID, and the collection shards on its bytes, so it has to be one
        // here too or the records all land in the same shard and the measurement means nothing.
        _id: uuidGenerator.generate(),
        hash: `${index.toString(16).padStart(64, "0")}`,
        photoDate: new Date(2020, 0, 1 + (index % 1000)).toISOString(),
        fileName: `IMG_${index}.jpg`,
        contentType: "image/jpeg",
        width: 4032,
        height: 3024,
        assetPath: `assets/${index}`,
        thumbPath: `thumb/${index}`,
        displayPath: `display/${index}`,
        description: `A photo taken on the ${index}th day of the measurement, with enough text to stand in for what a real record carries.`,
        labels: ["holiday", "family", "2020"],
        micro: "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD",
    };
}

//
// Inserts records in batches, committing after each batch the way an import does, and reports what
// each batch cost. A cost that climbs batch after batch, against a batch size that does not change,
// is the whole point of measuring it this way.
//
async function main(): Promise<void> {
    const batchSize = 50;
    const batches = 12;

    // The import drops the database caches before every batch, so the benchmark can too. Passed as
    // an argument because the difference between the two is the whole question: what a batch costs
    // when it may keep what it read, against what it costs when it may not.
    const flushBetweenBatches = process.argv.includes("--flush");

    const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "bdb-perf-"));
    const insertCounts = new Map<string, number>();
    const storage = countingStorage(new FileStorage(`fs:${tempDir}`), insertCounts);
    const uuidGenerator = new RandomUuidGenerator();
    const timestampProvider = new CountingTimestampProvider();
    // The database path is absolute so everything this writes stays in the temp directory. Storage
    // paths here are used as given rather than resolved against the storage root, so a relative one
    // lands wherever the command happened to be run from, which for this was inside the package.
    const database = new BsonDatabase(storage, path.join(tempDir, ".db", "bson"), uuidGenerator, timestampProvider);
    const collection = database.collection<any>("metadata");

    await collection.sortIndex("hash", "asc").ensure(collection, "string");
    await collection.sortIndex("photoDate", "desc").ensure(collection, "date");

    console.log(`Inserting ${batches} batches of ${batchSize} into ${tempDir}${flushBetweenBatches ? ", flushing between batches" : ""}`);
    console.log("batch  records  insert(ms)  commit(ms)  insert per record(ms)  storage calls per record");

    let inserted = 0;
    for (let batch = 0; batch < batches; batch++) {
        insertCounts.clear();
        const insertStartedAt = Date.now();
        for (let indexInBatch = 0; indexInBatch < batchSize; indexInBatch++) {
            await collection.insertOne(assetRecord(inserted, uuidGenerator));
            inserted += 1;
        }
        const insertMs = Date.now() - insertStartedAt;
        const insertCallsPerRecord = [...insertCounts.entries()]
            .sort((left, right) => right[1] - left[1])
            .map(([name, calls]) => `${name}=${(calls / batchSize).toFixed(1)}`)
            .join(" ");

        insertCounts.clear();
        const commitStartedAt = Date.now();
        await database.commit();
        // Dropped after each batch the way the import does, which drops it at the start of the next
        // one. What a batch has to read back is then measured rather than hidden by caches the
        // import never gets to keep.
        if (flushBetweenBatches) {
            await database.flush();
        }

        const commitMs = Date.now() - commitStartedAt;
        const commitCalls = [...insertCounts.entries()]
            .sort((left, right) => right[1] - left[1])
            .map(([name, calls]) => `${name}=${calls}`)
            .join(" ");

        console.log(`${(batch + 1).toString().padStart(5)}  ${inserted.toString().padStart(7)}  ${insertMs.toString().padStart(10)}  ${commitMs.toString().padStart(10)}  ${(insertMs / batchSize).toFixed(2).padStart(21)}  ${insertCallsPerRecord} | commit: ${commitCalls}`);
    }
}

main()
    .catch(error => {
        console.error(error);
        process.exit(1);
    });
