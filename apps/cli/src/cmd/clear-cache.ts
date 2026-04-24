import path from "path";
import os from "os";
import fs from "fs";
import pc from "picocolors";
import { exit } from "node-utils";
import { log } from "utils";

//
// Command to clear hash cache entries
//
export async function clearCacheCommand(): Promise<void> {

    const localHashCachePath = path.join(os.tmpdir(), "photosphere");
    
    if (fs.existsSync(localHashCachePath)) {
        fs.rmSync(localHashCachePath, { recursive: true, force: true });
        log.info(pc.green(`✓ Cleared hash cache at: ${localHashCachePath}`));
    } else {
        log.info(pc.yellow("Local hash cache not found or already empty."));
    }
    
    await exit(0);
}