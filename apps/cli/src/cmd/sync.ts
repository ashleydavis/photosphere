import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { syncDatabases } from "api";

//
// Options for the sync command.
//
export interface ISyncCommandOptions extends IBaseCommandOptions {
    dest: string;
}

//
// Sync command implementation - synchronizes databases according to the sync specification.
//
export async function syncCommand(context: ICommandContext, options: ISyncCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    log.info("Starting database sync operation...");
    log.info(`  Source:    ${pc.cyan(options.db || ".")}`);
    log.info(`  Target:    ${pc.cyan(options.dest)}`);
    log.info("");

    const targetSessionId = uuidGenerator.generate();
    const { assetStorage: sourceAssetStorage, bsonDatabase: sourceBsonDatabase } = await loadDatabase(options.db, options, false, uuidGenerator, timestampProvider, sessionId);
    const targetOptions = { ...options, db: options.dest };
    const { assetStorage: targetAssetStorage, bsonDatabase: targetBsonDatabase } = await loadDatabase(targetOptions.db, targetOptions, false, uuidGenerator, timestampProvider, targetSessionId);
    await syncDatabases(sourceAssetStorage, sourceBsonDatabase, sessionId, targetAssetStorage, targetBsonDatabase, targetSessionId);
        
    log.info("Sync completed successfully!");       

    await exit(0);
}

