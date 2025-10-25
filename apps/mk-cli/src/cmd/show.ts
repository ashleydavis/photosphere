import pc from "picocolors";
import { loadTree, visualizeSortTreeSimple, visualizeTree } from "merkle-tree";
import { createStorage } from "storage";

export interface IShowCommandOptions {
    simple?: boolean;
    verbose?: boolean;
}

//
// Command to visualize a merkle tree from a saved tree file
//
export async function showCommand(treePath: string, options: IShowCommandOptions): Promise<void> {
    if (options.verbose) {
        console.log(pc.gray(`Loading merkle tree from: ${treePath}`));
    }

    // Create storage for loading the tree
    const { storage } = createStorage(treePath);

    // Load the merkle tree
    const merkleTree = await loadTree("tree.dat", storage);

    if (!merkleTree) {
        console.error(pc.red("Failed to load merkle tree"));
        process.exit(1);
    }

    // Visualize the merkle tree
    console.log(pc.blue("\nMerkle Tree Visualization:"));
    console.log(pc.gray("=".repeat(50)));

    let visualization: string;
    if (options.simple) {
        // Simple visualization showing only file structure
        visualization = visualizeSortTreeSimple(merkleTree.sort);
    } else {
        // Full visualization with hashes and metadata
        visualization = visualizeTree(merkleTree);
    }
    
    console.log(visualization);

    // Display tree metadata
    console.log(pc.gray("=".repeat(50)));
    console.log(pc.cyan(`Files: ${merkleTree.metadata.totalFiles}`));
    console.log(pc.cyan(`Total Size: ${merkleTree.metadata.totalSize} bytes`));
    console.log(pc.cyan(`Database Version: ${merkleTree.version}`));
    console.log(pc.cyan(`ID: ${merkleTree.metadata.id}`));
    
    if (merkleTree.merkle) {
        console.log(pc.cyan(`Root Hash: ${merkleTree.merkle.hash.toString('hex')}`));
    }

    process.exit(0);
}

