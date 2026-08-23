import fs from "fs";
import pc from "picocolors";
import { getHashCacheDir } from "node-api";
import { exit } from "node-utils";
import { log } from "utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";

export interface IClearCacheCommandOptions extends IBaseCommandOptions {
}

//
// Command to clear the hash cache of one database.
//
// The database has to be named because there is one cache per database. Clearing loses nothing:
// every entry can be recomputed from the files themselves, and the next import simply rehashes.
//
export async function clearCacheCommand(context: ICommandContext, options: IClearCacheCommandOptions): Promise<void> {

    const { uuidGenerator, timestampProvider, sessionId } = context;
    const { databaseDir } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);

    const localHashCachePath = getHashCacheDir(databaseDir);

    if (fs.existsSync(localHashCachePath)) {
        fs.rmSync(localHashCachePath, { recursive: true, force: true });
        log.info(pc.green(`✓ Cleared hash cache at: ${localHashCachePath}`));
    } else {
        log.info(pc.yellow("Local hash cache not found or already empty."));
    }

    await exit(0);
}
