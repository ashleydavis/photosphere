//
// Reads a database that the Zig tests wrote to disk with the TypeScript implementation, the way the TS CLI list,
// summary and root-hash commands do (createStorage, so FileStorage behind the prefix wrapper, BsonDatabase, sort index pages, database merkle tree), and prints
// what it read as JSON so the Zig test can compare it with the golden fixture.
// Usage: bun run read-database.ts <database directory> <field>_<direction> ...
//

import { createHash } from "crypto";
import { BsonDatabase, getDatabaseRootHash } from "bdb";
import { createStorage } from "storage";
import { TestUuidGenerator, TimestampProvider } from "utils";

//
// Walks a sort index page by page and returns the record ids in page order.
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
// Reads the database and prints the result.
//
async function main(): Promise<void> {
    const [databaseDir, ...indexNames] = process.argv.slice(2);
    const { storage } = createStorage(databaseDir);
    const database = new BsonDatabase(storage, ".db/bson", new TestUuidGenerator(), new TimestampProvider());
    const walks: any = {};
    for (const indexName of indexNames) {
        const separator = indexName.lastIndexOf("_");
        const ids = await walkSortIndex(database, indexName.substring(0, separator), indexName.substring(separator + 1) as "asc" | "desc");
        walks[indexName] = { count: ids.length, sha256: createHash("sha256").update(ids.join("\n")).digest("hex") };
    }
    let recordCount = 0;
    for await (const _record of database.collection("metadata").iterateRecords()) {
        recordCount++;
    }
    const rootHash = await getDatabaseRootHash(storage, ".db/bson");
    console.log(JSON.stringify({ walks, recordCount, rootHash: rootHash ? rootHash.toString("hex") : null }));
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
