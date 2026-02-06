//
// Sets the origin database path in .db/config.json.
//

import pc from "picocolors";
import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { loadDatabaseConfig, updateDatabaseConfig } from "api";

export interface ISetOriginCommandOptions extends IBaseCommandOptions {
}

export async function setOriginCommand(context: ICommandContext, options: ISetOriginCommandOptions, originPath: string): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const { metadataStorage } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);
    const existing = await loadDatabaseConfig(metadataStorage);
    await updateDatabaseConfig(metadataStorage, { ...existing ?? {}, origin: originPath });

    console.log(pc.green(`✓ Origin set to: ${originPath}`));
    await exit(0);
}
