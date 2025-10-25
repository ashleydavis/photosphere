import pc from "picocolors";
import { loadTree } from "merkle-tree";
import { createStorage } from "storage";

export interface IRootHashCommandOptions {
    verbose?: boolean;
}

//
// Command to print the root hash of a merkle tree
//
export async function rootHashCommand(treePath: string, options: IRootHashCommandOptions): Promise<void> {
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

    // Print only the root hash
    if (merkleTree.merkle) {
        console.log(merkleTree.merkle.hash.toString('hex'));
    } else {
        console.error(pc.red("Merkle tree has no root hash"));
        process.exit(1);
    }

    process.exit(0);
}

