import pc from "picocolors";
import { loadTree } from "merkle-tree";
import { createStorage } from "storage";
import path from "path";

export interface IRootHashCommandOptions {
    verbose?: boolean;
}

//
// Command to print the root hash of a merkle tree
//
export async function rootHashCommand(treePath: string, options: IRootHashCommandOptions): Promise<void> {
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

    // Print only the root hash
    if (merkleTree.merkle) {
        console.log(merkleTree.merkle.hash.toString('hex'));
    } else {
        console.error(pc.red("Merkle tree has no root hash"));
        process.exit(1);
    }

    process.exit(0);
}

