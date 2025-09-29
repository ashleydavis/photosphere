import { IStorage, FileStorage, createStorage } from "storage";
import { HashCache } from "adb";
import { exit } from "node-utils";
import path from "path";
import os from "os";
import pc from "picocolors";

export interface IClearCacheCommandOptions {
    db?: string;
    meta?: string;
    key?: string;
    verbose?: boolean;
    yes?: boolean;
}

//
// Command to clear hash cache entries
//
export async function clearCacheCommand(options: IClearCacheCommandOptions): Promise<void> {
    
    const databaseDir = options.db || process.cwd();
    
    console.log(pc.blue("=== Clearing Local Hash Cache ==="));
    const localHashCachePath = path.join(os.tmpdir(), "photosphere");
    const localHashCache = new HashCache(new FileStorage(localHashCachePath), localHashCachePath);
    
    const loaded = await localHashCache.load();
    if (!loaded) {
        console.log(pc.yellow("Local hash cache not found or already empty."));
    } else {
        const entryCount = localHashCache.getEntryCount();
        console.log(`Found ${entryCount} entries in local cache at: ${localHashCachePath}`);
        
        // Clear the cache by removing all entries
        const entries = localHashCache.getAllEntries();
        for (const entry of entries) {
            localHashCache.removeHash(entry.filePath);
        }
        await localHashCache.save();
        
        console.log(pc.green(`✓ Cleared ${entryCount} entries from local hash cache`));
    }
    
    // Summary
    console.log();
    console.log(pc.green("✓ Cache clearing completed successfully"));
}