import { exit } from "node-utils";
import pc from "picocolors";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";

export interface IMerkleTreeCommandOptions extends IBaseCommandOptions {}

//
// Command to visualize the merkle tree structure
//
export async function merkleTreeCommand(databaseDir: string | undefined, options: IMerkleTreeCommandOptions): Promise<void> {
    
    try {
        const database = await loadDatabase(databaseDir, options);
        
        // Visualize the merkle tree
        console.log(pc.green("\nMerkle Tree Visualization:"));
        console.log(pc.gray("=".repeat(50)));
        
        const visualization = database.visualizeMerkleTree();
        console.log(visualization);
        
    } catch (err: any) {
        console.error(pc.red(`Error visualizing merkle tree: ${err.message}`));
        if (options.verbose && err.stack) {
            console.error(pc.red(err.stack));
        }
        await exit(1);
    }
}