//
// Replicates a database with the TypeScript replicate-database handler, for the Zig parity tests.
// Usage: bun run replicate-ts.ts <source path> <dest path> <full|partial> [dest key] [source key] [path filter]
// Uses TestUuidGenerator (counter in TEST_TMP_DIR) like the Zig test, and prints the replication result as JSON.
//

import { replicateDatabaseHandler } from "node-api";
import { TestUuidGenerator } from "node-utils";
import { TimestampProvider } from "utils";

//
// Runs the replication.
//
async function main(): Promise<void> {
    const [sourcePath, destPath, mode, destKey, sourceKey, pathFilter] = process.argv.slice(2);
    const context = {
        uuidGenerator: new TestUuidGenerator(),
        timestampProvider: new TimestampProvider(),
        sessionId: "parity",
        taskId: "parity-task",
        sendMessage: () => {},
        isCancelled: () => false,
    };
    const result = await replicateDatabaseHandler({
        sourcePath,
        destPath,
        sourceEncryptionKey: sourceKey || undefined,
        destEncryptionKey: destKey || undefined,
        destS3Key: undefined,
        partial: mode === "partial",
        force: false,
        pathFilter: pathFilter || undefined,
    }, context);
    console.log(JSON.stringify(result));
}

main().catch(error => {
    console.error(error);
    process.exit(1);
});
