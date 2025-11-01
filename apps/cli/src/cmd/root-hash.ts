import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface IRootHashCommandOptions extends IBaseCommandOptions {
}

//
// Command to display the aggregate root hash of the database.
//
export async function rootHashCommand(options: IRootHashCommandOptions): Promise<void> {
    
    const { database } = await loadDatabase(options.db, options, true, true);
    
    const hashes = await database.getDatabaseHashes();
    
    console.log(hashes.fullHash);
    
    await exit(0);
}

