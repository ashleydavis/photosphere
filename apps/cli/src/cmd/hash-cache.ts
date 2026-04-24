import { IStorage, FileStorage, createStorage } from "storage";
import { HashCache } from "api";
import { exit } from "node-utils";
import path from "path";
import os from "os";
import pc from "picocolors";
import { log } from "utils";
import { formatBytes } from "../lib/format";

export interface IHashCacheCommandOptions {
    db?: string;
    key?: string;
    verbose?: boolean;
    yes?: boolean;
}

//
// Command to display local hash cache entries
//
export async function hashCacheCommand(options: IHashCacheCommandOptions): Promise<void> {
    
    try {
        log.info(pc.blue("\n=== Local Hash Cache ==="));
        const localHashCachePath = path.join(os.tmpdir(), "photosphere");
        const localHashCache = new HashCache(localHashCachePath);
        
        const loaded = await localHashCache.load();
        if (!loaded) {
            log.info(pc.yellow("Local hash cache not found or empty."));
        } else {
            const entryCount = localHashCache.getEntryCount();
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
        log.info(pc.cyan(`  ${entry.filePath}`));
        log.info(`    Size: ${formatBytes(entry.size)}`);
        log.info(`    Modified: ${entry.lastModified.toISOString().replace('T', ' ').slice(0, 19)}`);
        log.info(`    Hash: ${entry.hash}`);
        log.info("");
    }
    
    log.info(`  Total: ${entries.length} ${entries.length === 1 ? 'entry' : 'entries'}`);
}