import path from "path";
import fs from "fs";
import pc from "picocolors";
import { exit, getProcessTmpDir } from "node-utils";
import { log } from "utils";

//
// Command to clear hash cache entries
//
export async function clearCacheCommand(): Promise<void> {

    const localHashCachePath = path.join(getProcessTmpDir(), "photosphere");
    
    if (fs.existsSync(localHashCachePath)) {
        fs.rmSync(localHashCachePath, { recursive: true, force: true });
        log.info(pc.green(`✓ Cleared hash cache at: ${localHashCachePath}`));
    } else {
        log.info(pc.yellow("Local hash cache not found or already empty."));
    }
    
    await exit(0);
}