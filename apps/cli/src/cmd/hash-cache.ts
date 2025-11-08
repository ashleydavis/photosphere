import { IStorage, FileStorage, createStorage } from "storage";
import { HashCache } from "api";
import { exit } from "node-utils";
import path from "path";
import os from "os";
import pc from "picocolors";
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