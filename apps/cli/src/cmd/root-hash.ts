import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";

export interface IRootHashCommandOptions extends IBaseCommandOptions {
}

//
// Command to display the aggregate root hash of the database.
//
export async function rootHashCommand(context: ICommandContext, options: IRootHashCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const { assetStorage, metadataStorage } = await loadDatabase(options.db, options, true, uuidGenerator, timestampProvider, sessionId);
    
    const { getDatabaseSummary } = await import("api");
    const summary = await getDatabaseSummary(assetStorage, metadataStorage);
    
    console.log(summary.fullHash);
    
    await exit(0);
}

