//
// Sets the origin database path in .db/config.json.
//

import pc from "picocolors";
import { exit } from "node-utils";
import { log } from "utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { loadDatabaseConfig, updateDatabaseConfig } from "api";

export interface ISetOriginCommandOptions extends IBaseCommandOptions {
}

export async function setOriginCommand(context: ICommandContext, options: ISetOriginCommandOptions, originPath: string): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const { rawAssetStorage } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);
    const existing = await loadDatabaseConfig(rawAssetStorage);
    await updateDatabaseConfig(rawAssetStorage, { ...existing ?? {}, origin: originPath });

    log.info(pc.green(`✓ Origin set to: ${originPath}`));
    await exit(0);
}
