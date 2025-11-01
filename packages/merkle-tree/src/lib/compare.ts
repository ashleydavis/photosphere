import { IMerkleTree, MerkleNode } from "./merkle-tree";
import { findMerkleTreeDifferences } from "./merkle-diff";

//
// The result of a comparison between two Merkle trees.
// 
export interface ICompareResult {
    onlyInA: string[];
    onlyInB: string[];
    modified: string[];
}

//
// Helper function to extract leaf node names from MerkleNode arrays.
//
function extractLeafNames(nodes: MerkleNode[]): string[] {
    const names: string[] = [];
    for (const node of nodes) {
        if (!node.left && !node.right && node.name) {
            // Leaf node
            names.push(node.name);
        } else {
            // Internal node - recursively extract leaf names
            if (node.left) {
                names.push(...extractLeafNames([node.left]));
            }
            if (node.right) {
                names.push(...extractLeafNames([node.right]));
            }
        }
    }
    return names;
}

/**
 * Compare two Merkle trees and show the differences between them
 * 
 * @param treeA The first Merkle tree
 * @param treeB The second Merkle tree
 * @returns An object containing the differences between the trees
 */
export function compareTrees<DatabaseMetadata>(treeA: IMerkleTree<DatabaseMetadata>, treeB: IMerkleTree<DatabaseMetadata>, progressCallback?: (progress: string) => void): ICompareResult {
    if (progressCallback) {
        progressCallback("Comparing merkle trees...");
    }
    
    // Use findMerkleTreeDifferences to find differences in merkle trees
    const diff = findMerkleTreeDifferences(treeA.merkle, treeB.merkle);
    
    // Extract leaf node names from the differing nodes
    const namesOnlyInA = extractLeafNames(diff.onlyInTree1);
    const namesOnlyInB = extractLeafNames(diff.onlyInTree2);
    
    // Files that appear in both arrays are modified (same name, different hash)
    const namesInA = new Set(namesOnlyInA);
    const namesInB = new Set(namesOnlyInB);
    const modified: string[] = [];
    const onlyInA: string[] = [];
    const onlyInB: string[] = [];
    
    // Find modified files (present in both with different hashes)
    for (const name of namesOnlyInA) {
        if (namesInB.has(name)) {
            modified.push(name);
        } else {
            onlyInA.push(name);
        }
    }
    
    // Find files only in B (not in modified)
    for (const name of namesOnlyInB) {
        if (!namesInA.has(name)) {
            onlyInB.push(name);
        }
    }
    
    return {
        onlyInA,
        onlyInB,
        modified
    };
}

/**
 * Generate a human-readable report of differences between two Merkle trees
 * 
 * @param treeA The first Merkle tree
 * @param treeB The second Merkle tree
 * @returns A string containing a formatted report of the differences
 */
export function generateTreeDiffReport<DatabaseMetadata>(treeA: IMerkleTree<DatabaseMetadata>, treeB: IMerkleTree<DatabaseMetadata>): string {
    const diff = compareTrees(treeA, treeB);
    
    let report = "Merkle Tree Comparison Report\n";
    report += "===========================\n\n";
    
    // Files only in tree A
    report += "Files only in first tree:\n";
    if (diff.onlyInA.length === 0) {
        report += "  (None)\n";
    } else {
        diff.onlyInA.forEach(file => {
            report += `  + ${file}\n`;
        });
    }
    
    // Files only in tree B
    report += "\nFiles only in second tree:\n";
    if (diff.onlyInB.length === 0) {
        report += "  (None)\n";
    } else {
        diff.onlyInB.forEach(file => {
            report += `  + ${file}\n`;
        });
    }
    
    // Modified files
    report += "\nModified files:\n";
    if (diff.modified.length === 0) {
        report += "  (None)\n";
    } else {
        diff.modified.forEach(file => {
            report += `  ~ ${file}\n`;
        });
    }
    
    // Summary
    report += "\nSummary:\n";
    report += `  ${diff.onlyInA.length} files only in first tree\n`;
    report += `  ${diff.onlyInB.length} files only in second tree\n`;
    report += `  ${diff.modified.length} modified files\n`;
    
    return report;
}


