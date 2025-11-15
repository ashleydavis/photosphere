import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { loadMerkleTree } from "api";

export interface IDatabaseIdCommandOptions extends IBaseCommandOptions {
}

//
// Command to display the database ID (UUID) of the database.
//
export async function databaseIdCommand(options: IDatabaseIdCommandOptions): Promise<void> {
    
    const { database } = await loadDatabase(options.db, options, true);
    
    const merkleTree = await loadMerkleTree(database.getAssetStorage());
    
    if (!merkleTree) {
        throw new Error("Failed to load merkle tree");
    }
    
    console.log(merkleTree.id);
    
    await exit(0);
}

