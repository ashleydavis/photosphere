import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { log } from "utils";

export interface IRootHashCommandOptions extends IBaseCommandOptions {
}

//
// Command to display the aggregate root hash of the database.
//
export async function rootHashCommand(context: ICommandContext, options: IRootHashCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const { assetStorage } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);
    
    const { getDatabaseSummary } = await import("api");
    const summary = await getDatabaseSummary(assetStorage);
    
    log.info(summary.fullHash);
    
    await exit(0);
}

