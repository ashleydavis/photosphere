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
    type?: string;
}

//
// Command to clear hash cache entries
//
export async function clearCacheCommand(options: IClearCacheCommandOptions): Promise<void> {
    
    const databaseDir = options.db || process.cwd();
    
    // Determine which hash cache to clear
    const cacheType = options.type || "both";
    
    if (!["local", "database", "both"].includes(cacheType)) {
        console.error(pc.red(`Invalid cache type: ${cacheType}. Must be 'local', 'database', or 'both'.`));
        await exit(1);
    }
    
    try {
        let localCleared = false;
        let databaseCleared = false;
        
        // Clear local hash cache
        if (cacheType === "local" || cacheType === "both") {
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
                localCleared = true;
            }
        }
        
        // Clear database hash cache
        if (cacheType === "database" || cacheType === "both") {
            console.log(pc.blue("\n=== Clearing Database Hash Cache ==="));
            
            // Set up metadata directory
            const metadataDir = options.meta || path.join(databaseDir, ".db");
            
            // Check if metadata directory exists
            try {
                const { storage: metadataStorage } = createStorage(metadataDir);
                const databaseHashCache = new HashCache(metadataStorage, "");
                
                const loaded = await databaseHashCache.load();
                if (!loaded) {
                    console.log(pc.yellow("Database hash cache not found or already empty."));
                } else {
                    const entryCount = databaseHashCache.getEntryCount();
                    console.log(`Found ${entryCount} entries in database cache at: ${path.join(metadataDir, "hash-cache-x.dat")}`);
                    
                    // Clear the cache by removing all entries
                    const entries = databaseHashCache.getAllEntries();
                    for (const entry of entries) {
                        databaseHashCache.removeHash(entry.filePath);
                    }
                    await databaseHashCache.save();
                    
                    console.log(pc.green(`✓ Cleared ${entryCount} entries from database hash cache`));
                    databaseCleared = true;
                }
            } catch (err: any) {
                console.log(pc.yellow(`Could not access database hash cache: ${err.message}`));
                if (options.verbose && err.stack) {
                    console.error(pc.red(err.stack));
                }
            }
        }
        
        // Summary
        console.log();
        if (localCleared || databaseCleared) {
            console.log(pc.green("✓ Cache clearing completed successfully"));
        } else {
            console.log(pc.yellow("ⓘ No caches needed clearing (all were empty or not found)"));
        }
        
    } catch (err: any) {
        console.error(pc.red(`Error clearing hash cache: ${err.message}`));
        if (options.verbose && err.stack) {
            console.error(pc.red(err.stack));
        }
        await exit(1);
    }
}