import { exit } from "node-utils";
import pc from "picocolors";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface IMerkleTreeCommandOptions extends IBaseCommandOptions {
}

//
// Command to visualize the merkle tree structure
//
export async function merkleTreeCommand(options: IMerkleTreeCommandOptions): Promise<void> {
    
    const { database } = await loadDatabase(options.db, options);
    
    // Visualize the merkle tree
    console.log(pc.blue("\nMerkle Tree Visualization:"));
    console.log(pc.gray("=".repeat(50)));
    
    const visualization = database.visualizeMerkleTree();
    console.log(visualization);
   
    await exit(0);
}