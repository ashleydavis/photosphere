import pc from "picocolors";
import { loadTree, visualizeTree } from "merkle-tree";
import { createStorage } from "storage";
import path from "path";

export interface IShowCommandOptions {
    verbose?: boolean;
}

//
// Command to visualize a merkle tree from a saved tree file
//
export async function showCommand(treePath: string, options: IShowCommandOptions): Promise<void> {
    const dirPath = path.dirname(treePath);
    const fileName = path.basename(treePath);
    const { storage, normalizedPath } = createStorage(dirPath);

    if (options.verbose) {
        console.log(pc.gray(`Loading merkle tree from: ${normalizedPath}/${fileName}`));
    }

    // Load the merkle tree
    const merkleTree = await loadTree(fileName, storage);

    if (!merkleTree) {
        console.error(pc.red("Failed to load merkle tree"));
        process.exit(1);
    }

    // Visualize the merkle tree
    console.log(pc.blue("\nMerkle Tree Visualization:"));
    console.log(pc.gray("=".repeat(50)));
    console.log();

    // Full visualization with both sort tree and merkle tree
    const visualization = visualizeTree(merkleTree);
    console.log(visualization);

    process.exit(0);
}

