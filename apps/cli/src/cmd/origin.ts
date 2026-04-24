//
// Shows the origin database path from .db/config.json.
//

import pc from "picocolors";
import { exit } from "node-utils";
import { log } from "utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { loadDatabaseConfig } from "api";

export interface IOriginCommandOptions extends IBaseCommandOptions {
}

export async function originCommand(context: ICommandContext, options: IOriginCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const { rawAssetStorage } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);
    const config = await loadDatabaseConfig(rawAssetStorage);

    if (config?.origin) {
        log.info(config.origin);
    }
    else {
        log.info(pc.gray("(not set)"));
    }

    await exit(0);
}
