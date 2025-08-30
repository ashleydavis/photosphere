import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface IRootHashCommandOptions extends IBaseCommandOptions {
}

//
// Command that prints just the root hash of the Photosphere media file database.
//
export async function rootHashCommand(options: IRootHashCommandOptions): Promise<void> {
    
    const { database } = await loadDatabase(options.db, options, true, true);

    // Get database summary information
    const summary = await database.getDatabaseSummary();

    // Print only the root hash
    console.log(summary.fullHash);

    await exit(0);
}