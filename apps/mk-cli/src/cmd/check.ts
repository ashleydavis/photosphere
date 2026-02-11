import pc from "picocolors";
import { loadTree, iterateLeaves, compareNames, SortNode, MerkleNode } from "merkle-tree";
import { createStorage } from "storage";
import path from "path";

export interface ICheckCommandOptions {
    verbose?: boolean;
}

//
// Verify that leaf nodes are sorted using natural/numeric sorting
//
function verifyLeafNodesAreSorted(leafNodes: string[]): boolean {
    for (let i = 1; i < leafNodes.length; i++) {
        if (compareNames(leafNodes[i - 1], leafNodes[i]) > 0) {
            return false;
        }
    }
    return true;
}

//
// Command to check that leaf nodes of the merkle tree are in sorted order
//
export async function checkCommand(treePath: string, options: ICheckCommandOptions): Promise<void> {
    const dirPath = path.dirname(treePath);
    const fileName = path.basename(treePath);
    const { storage, normalizedPath } = createStorage(dirPath);

    if (options.verbose) {
        console.log(`Loading merkle tree from: ${normalizedPath}/${fileName}`);
    }

    // Load the merkle tree
    const merkleTree = await loadTree(fileName, storage);
    if (!merkleTree) {
        console.error(pc.red("Failed to load merkle tree"));
        process.exit(1);
    }

    if (!merkleTree.sort) {
        console.error(pc.red("Merkle tree has no sort tree"));
        process.exit(1);
    }

    if (!merkleTree.merkle) {
        console.error(pc.red("Merkle tree has no merkle tree"));
        process.exit(1);
    }

    // Check sort tree leaf nodes using iterateLeaves
    const sortLeafNodes = Array.from(iterateLeaves<SortNode>(merkleTree.sort))
        .map(node => node.name!);
    
    if (options.verbose) {
        console.log(`Found ${sortLeafNodes.length} leaf nodes in sort tree`);
    }

    const isSortTreeSorted = verifyLeafNodesAreSorted(sortLeafNodes);
    if (!isSortTreeSorted) {
        console.error(pc.red("Sort tree leaf nodes are not in sorted order"));
        if (options.verbose) {
            console.error(pc.red("Sort tree leaf node order:"));
            sortLeafNodes.forEach((name, index) => {
                if (index > 0 && compareNames(sortLeafNodes[index - 1], name) > 0) {
                    console.error(pc.red(`  ${index}: ${name} (❌ out of order)`));
                } else {
                    console.error(`  ${index}: ${name}`);
                }
            });
        }
        process.exit(1);
    }

    const merkleLeafNodes = Array.from(iterateLeaves<MerkleNode>(merkleTree.merkle))
        .map(node => node.name!);

    if (options.verbose) {
        console.log(`Found ${merkleLeafNodes.length} leaf nodes in merkle tree`);
    }

    const isMerkleTreeSorted = verifyLeafNodesAreSorted(merkleLeafNodes);
    if (!isMerkleTreeSorted) {
        console.error(pc.red("Merkle tree leaf nodes are not in sorted order"));
        if (options.verbose) {
            console.error(pc.red("Merkle tree leaf node order:"));
            merkleLeafNodes.forEach((name, index) => {
                if (index > 0 && compareNames(merkleLeafNodes[index - 1], name) > 0) {
                    console.error(pc.red(`  ${index}: ${name} (❌ out of order)`));
                } else {
                    console.error(`  ${index}: ${name}`);
                }
            });
        }
        process.exit(1);
    }

    // Print success message
    if (options.verbose) {
        console.log(pc.green(`✓ All ${sortLeafNodes.length} sort tree leaf nodes are in sorted order`));
        console.log(pc.green(`✓ All ${merkleLeafNodes.length} merkle tree leaf nodes are in sorted order`));
    } else {
        console.log(pc.green(`✓ Leaf nodes are in sorted order (sort tree: ${sortLeafNodes.length}, merkle tree: ${merkleLeafNodes.length} nodes)`));
    }

    process.exit(0);
}

