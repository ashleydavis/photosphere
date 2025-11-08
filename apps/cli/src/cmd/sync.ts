import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
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
export async function syncCommand(options: ISyncCommandOptions): Promise<void> {

    log.info("Starting database sync operation...");
    log.info(`  Source:    ${pc.cyan(options.db || ".")}`);
    log.info(`  Target:    ${pc.cyan(options.dest)}`);
    log.info("");

    const { database: sourceDb } = await loadDatabase(options.db, options, false);
    const targetOptions = { ...options, db: options.dest };
    const { database: targetDb } = await loadDatabase(targetOptions.db, targetOptions, false);
    await syncDatabases(sourceDb, targetDb);
        
    log.info("Sync completed successfully!");       

    await exit(0);
}

