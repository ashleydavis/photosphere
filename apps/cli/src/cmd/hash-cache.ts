import { HashCache, getHashCacheDir } from "node-api";
import { exit } from "node-utils";
import pc from "picocolors";
import { log } from "utils";
import { formatBytes } from "../lib/format";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";

export interface IHashCacheCommandOptions extends IBaseCommandOptions {
}

//
// Command to display the hash cache of one database.
//
// The database has to be named because there is one cache per database: an entry records the id
// the file has in that database, and one entry cannot hold the ids of several.
//
export async function hashCacheCommand(context: ICommandContext, options: IHashCacheCommandOptions): Promise<void> {

    try {
        const { uuidGenerator, timestampProvider, sessionId } = context;
        const { databaseDir } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);

        log.info(pc.blue("\n=== Local Hash Cache ==="));
        const localHashCachePath = getHashCacheDir(databaseDir);
        const localHashCache = new HashCache(localHashCachePath);

        const loaded = await localHashCache.load();
        if (!loaded) {
            log.info(pc.yellow("Local hash cache not found or empty."));
        } else {
            const entryCount = localHashCache.getEntryCount();
            log.info(`Database: ${databaseDir}`);
            log.info(`Location: ${localHashCachePath}`);
            log.info(`Entries: ${entryCount}`);

            if (entryCount > 0) {
                log.info("\nCache entries:");
                displayHashCacheEntries(localHashCache);
            }
        }

        log.info(''); // Empty line at end

    } catch (err: any) {
        log.error(pc.red(`Error reading hash cache: ${err.message}`));
        if (options.verbose && err.stack) {
            log.error(pc.red(err.stack));
        }
        await exit(1);
    }
}

//
// Helper function to display hash cache entries
//
function displayHashCacheEntries(hashCache: HashCache): void {
    const entries = hashCache.getAllEntries();

    if (entries.length === 0) {
        log.info("  No entries found.");
        return;
    }

    log.info("");

    // Display entries
    for (const entry of entries) {
        log.info(pc.cyan(`  ${entry.key}`));
        log.info(`    Keyed by: ${entry.keyedBySourceId ? "photo library source id" : "file path"}`);
        log.info(`    Size: ${formatBytes(entry.size)}`);
        log.info(`    Modified: ${entry.lastModified.toISOString().replace('T', ' ').slice(0, 19)}`);
        log.info(`    Hash: ${entry.hash}`);
        log.info(`    Asset id: ${entry.assetId ?? "(not known to be in the database)"}`);
        log.info("");
    }

    log.info(`  Total: ${entries.length} ${entries.length === 1 ? 'entry' : 'entries'}`);
}
