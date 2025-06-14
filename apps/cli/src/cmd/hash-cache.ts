import { IStorage, FileStorage, createStorage } from "storage";
import { HashCache } from "adb";
import { exit } from "node-utils";
import path from "path";
import os from "os";
import pc from "picocolors";
import { formatBytes } from "../lib/format";

export interface IHashCacheCommandOptions {
    meta?: string;
    key?: string;
    verbose?: boolean;
    yes?: boolean;
    type?: string;
}

//
// Command to display hash cache entries
//
export async function hashCacheCommand(databaseDir: string | undefined, options: IHashCacheCommandOptions): Promise<void> {
    
    databaseDir = databaseDir || process.cwd();
    
    // Determine which hash cache to show
    const cacheType = options.type || "both";
    
    if (!["local", "database", "both"].includes(cacheType)) {
        console.error(pc.red(`Invalid cache type: ${cacheType}. Must be 'local', 'database', or 'both'.`));
        await exit(1);
    }
    
    try {
        // Show local hash cache
        if (cacheType === "local" || cacheType === "both") {
            console.log(pc.blue("\n=== Local Hash Cache ==="));
            const localHashCachePath = path.join(os.tmpdir(), "photosphere");
            const localHashCache = new HashCache(new FileStorage(localHashCachePath), localHashCachePath);
            
            const loaded = await localHashCache.load();
            if (!loaded) {
                console.log(pc.yellow("Local hash cache not found or empty."));
            } else {
                const entryCount = localHashCache.getEntryCount();
                console.log(`Location: ${localHashCachePath}`);
                console.log(`Entries: ${entryCount}`);
                
                if (entryCount > 0) {
                    console.log("\nCache entries:");
                    displayHashCacheEntries(localHashCache);
                }
            }
        }
        
        // Show database hash cache
        if (cacheType === "database" || cacheType === "both") {
            console.log(pc.blue("\n=== Database Hash Cache ==="));
            
            // Set up metadata directory
            const metadataDir = options.meta || path.join(databaseDir, ".db");
            
            // Check if metadata directory exists
            try {
                const { storage: metadataStorage } = createStorage(metadataDir);
                const databaseHashCache = new HashCache(metadataStorage, "");
                
                const loaded = await databaseHashCache.load();
                if (!loaded) {
                    console.log(pc.yellow("Database hash cache not found or empty."));
                } else {
                    const entryCount = databaseHashCache.getEntryCount();
                    console.log(`Location: ${path.join(metadataDir, "hash-cache-x.dat")}`);
                    console.log(`Entries: ${entryCount}`);
                    
                    if (entryCount > 0) {
                        console.log("\nCache entries:");
                        displayHashCacheEntries(databaseHashCache);
                    }
                }
            } catch (err: any) {
                console.log(pc.yellow(`Could not access database hash cache: ${err.message}`));
            }
        }
        
        console.log(); // Empty line at end
        
    } catch (err: any) {
        console.error(pc.red(`Error reading hash cache: ${err.message}`));
        if (options.verbose && err.stack) {
            console.error(pc.red(err.stack));
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
        console.log("  No entries found.");
        return;
    }
    
    console.log("");
    
    // Display entries
    for (const entry of entries) {
        console.log(pc.cyan(`  ${entry.filePath}`));
        console.log(`    Size: ${formatBytes(entry.size)}`);
        console.log(`    Modified: ${entry.lastModified.toISOString().replace('T', ' ').slice(0, 19)}`);
        console.log(`    Hash: ${entry.hash}`);
        console.log("");
    }
    
    console.log(pc.gray(`  Total: ${entries.length} ${entries.length === 1 ? 'entry' : 'entries'}`));
}