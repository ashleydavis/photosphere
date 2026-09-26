//
// Reads a database with the TypeScript node-api the way the CLI summary, database-id, root-hash and verify
// commands do, for the Zig parity tests, and prints what it read as JSON.
// Usage: bun run inspect-db.ts <database path> [key]
//

import { openStorage, getDatabaseSummary, loadMerkleTree, verify, verifyDatabaseFiles, createMediaFileDatabase, verifyFileHandler } from "node-api";
import { registerHandler, setQueueBackend } from "task-queue";
import { TestUuidGenerator } from "node-utils";
import { TimestampProvider } from "utils";
import { MockWorkerPool } from "../../../../../packages/task-queue/test/mock-worker-pool";

//
// Reads the database and prints the result.
//
async function main(): Promise<void> {
    const [databasePath, key] = process.argv.slice(2);
    const uuidGenerator = new TestUuidGenerator();
    const timestampProvider = new TimestampProvider();
    registerHandler("verify-file", verifyFileHandler);
    setQueueBackend(new MockWorkerPool(4, { uuidGenerator, timestampProvider, sessionId: "parity" }));

    const { storage } = await openStorage(databasePath, key || undefined);
    const summary = await getDatabaseSummary(storage);
    const merkleTree = await loadMerkleTree(storage);
    const database = createMediaFileDatabase(storage, uuidGenerator, timestampProvider);
    const verifyResult = await verify({ databasePath, encryptionKey: key || undefined }, storage, uuidGenerator, database.metadataCollection, {});
    verifyResult.modified.sort();
    verifyResult.removed.sort();
    verifyResult.recordMismatches?.sort();
    const databaseFiles = await verifyDatabaseFiles(storage);
    console.log(JSON.stringify({
        summary,
        databaseId: merkleTree?.id,
        databaseMetadata: merkleTree?.databaseMetadata,
        verify: verifyResult,
        databaseFiles,
    }));
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
