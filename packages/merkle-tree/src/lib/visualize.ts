import { IMerkleTree, SortNode, MerkleNode, iterateLeaves } from "./merkle-tree";

/**
 * Visualize a sort tree in simple ASCII format showing item names
 */
export function visualizeSortTree(node: SortNode | undefined, prefix: string = '', isLast: boolean = true): string {
    if (!node) return '';
    
    let result = '';
    const connector = isLast ? '└── ' : '├── ';
    
    result += prefix + connector;

    if (node.nodeCount === 1) {
        if (!node.name) {
            throw new Error(`Leaf node has no name. This could be a bug.`);
        }

        if (!node.contentHash) {
            throw new Error(`Leaf node has no content hash. This could be a bug.`);
        }

    
        const hashHex = node.contentHash.toString('hex');
        const shortHash = hashHex.substring(0,2) + hashHex.substring(hashHex.length - 2);

        result += `${node.name} (${shortHash})`;
    }
    else {
        result += `${node.minName} (${node.nodeCount})`;
    }

    result += '\n';
    
    // Add children
    const newPrefix = prefix + (isLast ? '    ' : '│   ');
    
    if (node.left) {
        result += visualizeSortTree(node.left, newPrefix, !node.right);
    }
    if (node.right) {
        result += visualizeSortTree(node.right, newPrefix, true);
    }
    
    return result;
}

/**
 * Visualize a Merkle tree in simple ASCII format showing hashes
 */
export function visualizeMerkleTree(node: MerkleNode | undefined, prefix: string = '', isLast: boolean = true): string {
    if (!node) return '';
    
    let result = '';
    const connector = isLast ? '└── ' : '├── ';
    
    const hashHex = node.hash.toString('hex');
    const shortHash = hashHex.substring(0,2) + hashHex.substring(hashHex.length - 2);

    result += prefix + connector;

    if (!node.left && !node.right) {
        result += ' ' + shortHash + ' ' + node.name;
    }
    else {
        result += ' ' + shortHash;
    }

    result += '\n';
    
    // Add children
    const newPrefix = prefix + (isLast ? '    ' : '│   ');
    
    if (node.left) {
        result += visualizeMerkleTree(node.left, newPrefix, !node.right);
    }
    if (node.right) {
        result += visualizeMerkleTree(node.right, newPrefix, true);
    }
    
    return result;
}

/**
 * Visualize both the sort tree and merkle tree for a complete view
 * 
 * @param merkleTree The Merkle tree to visualize
 * @returns A string representation of both trees
 */
export function visualizeTree<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata>): string {
    if (!merkleTree || !merkleTree.sort) {
        return "Empty tree";
    }

    let result = "";
    
    // Add metadata
    result += "Tree Metadata:\n";
    result += `  UUID: ${merkleTree.id}\n`;
    result += `  Total Nodes: ${merkleTree.sort?.nodeCount || 0}\n`;
    result += `  Total Items: ${merkleTree.sort?.leafCount || 0}\n`;
    result += `  Total Size: ${merkleTree.sort?.size || 0} bytes\n`;
    
    // Add database metadata if available (version 3+)
    if (merkleTree.databaseMetadata) {
        result += "\nDatabase Metadata:\n";
        
        // Show all database metadata fields
        for (const [key, value] of Object.entries(merkleTree.databaseMetadata)) {
            result += `  ${key}: ${value}\n`;
        }
    }
    
    result += `\nVersion: ${merkleTree.version}\n`;
    
    // Visualize the sort tree
    result += "\n" + "=".repeat(50) + "\n";
    result += "Sort Tree:\n";
    result += "=".repeat(50) + "\n\n";
    result += visualizeSortTree(merkleTree.sort);
    
    // Visualize the merkle tree
    if (merkleTree.merkle) {
        result += "\n" + "=".repeat(50) + "\n";
        result += "Merkle Tree:\n";
        result += "=".repeat(50) + "\n\n";
        result += visualizeMerkleTree(merkleTree.merkle);
        
        result += "\n" + "=".repeat(50) + "\n";
        result += `Root Hash: ${merkleTree.merkle.hash.toString('hex')}\n`;
        result += "=".repeat(50) + "\n";
        
        // List all leaf nodes
        result += "\n" + "=".repeat(50) + "\n";
        result += "Leaf Nodes:\n";
        result += "=".repeat(50) + "\n";
        for (const leaf of iterateLeaves<MerkleNode>(merkleTree.merkle)) {
            if (leaf.name) {
                const hashHex = leaf.hash.toString('hex');
                result += `${leaf.name} (${hashHex})\n`;
            }
        }
        result += "=".repeat(50) + "\n";
    }
    
    return result;
}

