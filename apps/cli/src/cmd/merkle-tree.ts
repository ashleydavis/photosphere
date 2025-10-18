import { exit } from "node-utils";
import pc from "picocolors";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { visualizeTreeSimple } from "../../../../packages/adb/src/test/lib/merkle-tree/merkle-verify";

export interface IMerkleTreeCommandOptions extends IBaseCommandOptions {
    simple?: boolean;
}

//
// Command to visualize the merkle tree structure
//
export async function merkleTreeCommand(options: IMerkleTreeCommandOptions): Promise<void> {

    const { database } = await loadDatabase(options.db, options, true, true);

    // Visualize the merkle tree
    console.log(pc.blue("\nMerkle Tree Visualization:"));
    console.log(pc.gray("=".repeat(50)));

    let visualization: string;
    if (options.simple) {
        const merkleTree = database.getAssetDatabase().getMerkleTree();
        visualization = visualizeTreeSimple(merkleTree.root);
    }
    else {
        visualization = database.visualizeMerkleTree();
    }
    console.log(visualization);

    await exit(0);
}