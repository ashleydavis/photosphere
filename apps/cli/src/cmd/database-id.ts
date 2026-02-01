import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { loadMerkleTree } from "api";

export interface IDatabaseIdCommandOptions extends IBaseCommandOptions {
}

//
// Command to display the database ID (UUID) of the database.
//
export async function databaseIdCommand(context: ICommandContext, options: IDatabaseIdCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;
    const { assetStorage } = await loadDatabase(options.db, options, uuidGenerator, timestampProvider, sessionId);
    
    const merkleTree = await loadMerkleTree(assetStorage);
    
    if (!merkleTree) {
        throw new Error("Failed to load merkle tree");
    }
    
    console.log(merkleTree.id);
    
    await exit(0);
}

