//
// Shows the origin database path from .db/config.json.
//

import pc from "picocolors";
import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { loadDatabaseConfig } from "api";

export interface IOriginCommandOptions extends IBaseCommandOptions {
}

export async function originCommand(context: ICommandContext, options: IOriginCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const { metadataStorage } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);
    const config = await loadDatabaseConfig(metadataStorage);

    if (config?.origin) {
        console.log(config.origin);
    }
    else {
        console.log(pc.gray("(not set)"));
    }

    await exit(0);
}
