//
// Changes a database with the TypeScript node-api, for the Zig parity tests (the source side changes that a second
// replication has to carry over).
// Usage: bun run modify-db.ts <database path> edit <asset id>     sets the description field of the asset's record
//        bun run modify-db.ts <database path> remove <asset id>   removes the asset (files, record and tree entries)
//

import { openStorage, createMediaFileDatabase, removeAsset } from "node-api";
import { TestUuidGenerator } from "node-utils";
import { TimestampProvider } from "utils";

//
// Applies the change.
//
async function main(): Promise<void> {
    const [databasePath, operation, assetId] = process.argv.slice(2);
    const { storage, rawStorage } = await openStorage(databasePath);
    const database = createMediaFileDatabase(storage, new TestUuidGenerator(), new TimestampProvider());
    if (operation === "edit") {
        await database.metadataCollection.updateOne(assetId, { description: "Edited by the parity test" } as any);
        await database.bsonDatabase.commit();
    }
    else if (operation === "remove") {
        await removeAsset(storage, rawStorage, "parity-session", database.bsonDatabase, database.metadataCollection, assetId, true);
    }
    else {
        throw new Error(`Unknown operation: ${operation}`);
    }
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
