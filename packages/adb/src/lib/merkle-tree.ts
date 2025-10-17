import * as crypto from 'crypto';
import { IStorage } from 'storage';
import { parse as parseUuid, stringify as stringifyUuid } from 'uuid';
import { save, load, ISerializer, IDeserializer } from 'serialization';

//
// Current database version
//
export const CURRENT_DATABASE_VERSION = 4;

//
// Represents a node in the Merkle tree.
//
export interface MerkleNode {
    hash: Buffer; // The hash of this node.
    fileName?: string; // The file this hash represents, for leaf nodes only.
    nodeCount: number; // Number of nodes in the subtree rooted at this node (including this node). Set to 1 for leaf nodes.
    leafCount: number; // Number of leaf nodes in the subtree rooted at this node. Set to 1 for leaf nodes.
    isDeleted?: boolean; // Indicates if this file has been deleted (for leaf nodes only).
    size: number; // The size of the node and children in bytes.
    lastModified?: Date; // The last modified date of the original file (for leaf nodes only, version 3+).
    minFileName: string; // The minimum file name in this subtree (for efficient sorted insertion).
    left?: MerkleNode; // Left child node
    right?: MerkleNode; // Right child node
}

//
// Represents a hashed file to add to the Merkle tree.
//
export interface FileHash {
    fileName: string; // The file this hash represents. This is relative to the asset database directory.
    hash: Buffer; // The hash of the file.
    length: number; // The size of the file in bytes.
    lastModified: Date; // The last modified date of the file.
}

// 
// Represents an indirect reference to a merkle tree node.
//
export interface MerkleNodeRef {
    fileName: string; // The file this hash represents. This is relative to the asset database directory.
    fileIndex: number; // The index of the file hash in the tree (0-based for the first file).
    isDeleted?: boolean; // Indicates if this file has been deleted.
}

//
// Represents metadata for the merkle tree.
//
export interface TreeMetadata {
    // A UUID that uniquely identifies the tree
    id: string;
    
    // Total number of nodes in the tree
    totalNodes: number;
    
    // Total number of files in the tree
    totalFiles: number;

    //  Total size of all files in the tree (in bytes)
    totalSize: number;
}

//
// Represents the merkle tree itself.
//
export interface IMerkleTree<DatabaseMetadata> {
    // 
    // The root of the binary tree (in-memory structure)
    //
    root?: MerkleNode;

    //
    // The sorted array of node references in the tree.
    // This can be binary searched to quickly find a node by file name.
    //
    sortedNodeRefs: MerkleNodeRef[]; 
    
    //
    // Metadata for the tree
    //
    metadata: TreeMetadata;

    //
    // Database metadata (only in version 3+)
    // This replaces the separate metadata.json file
    //
    databaseMetadata?: DatabaseMetadata;

    //
    // Version of the merkle tree file format
    //
    version: number;
}

//
// Core tree traversal utilities - these should be reused everywhere instead of duplicating logic
//

/**
 * Find a file node in the binary tree by file name.
 * This is the core tree traversal function that should be reused everywhere.
 */
export function findFileInTree(node: MerkleNode | undefined, targetFileName: string): MerkleNode | undefined {
    if (!node) return undefined;
    
    if (node.nodeCount === 1) {
        return node.fileName === targetFileName ? node : undefined;
    }
    
    const leftResult = findFileInTree(node.left, targetFileName);
    if (leftResult) return leftResult;
    
    return findFileInTree(node.right, targetFileName);
}

/**
 * Generic tree traversal function that calls a callback for each node.
 * The callback can return false to stop traversal early.
 */
export function traverseTreeSync(node: MerkleNode | undefined, callback: (node: MerkleNode) => boolean): void {
    if (!node) {
        return;
    }
    
    if (!callback(node)) {
        return; // Stop if callback returns false
    }
    
    traverseTreeSync(node.left, callback);
    traverseTreeSync(node.right, callback);
}

/**
 * Generic async tree traversal function that calls an async callback for each node.
 * The callback can return false to stop traversal early.
 */
export async function traverseTreeAsync(node: MerkleNode | undefined, callback: (node: MerkleNode) => Promise<boolean>): Promise<void> {
    if (!node) return;
    
    const shouldContinue = await callback(node);
    if (!shouldContinue) return; // Stop if callback returns false
    
    await traverseTreeAsync(node.left, callback);
    await traverseTreeAsync(node.right, callback);
}

/**
 * Generic function to find and update a node in the binary tree.
 * The updater function should return true if the node was updated, false otherwise.
 * If a node is updated, parent nodes will have their properties recalculated.
 */
export function updateNodeInTree<T>(
    node: MerkleNode, 
    targetFileName: string, 
    updater: (node: MerkleNode, targetFileName: string) => T
): T | undefined {
    // If this is a leaf node, check if it's the target
    if (node.nodeCount === 1) {
        if (node.fileName === targetFileName) {
            return updater(node, targetFileName);
        }
        return undefined; // Not the target
    }
    
    // Internal node - recursively check children
    let result: T | undefined = undefined;
    
    // Check left subtree
    if (node.left) {
        result = updateNodeInTree(node.left, targetFileName, updater);
    }
    
    // Check right subtree (only if not found in left)
    if (!result && node.right) {
        result = updateNodeInTree(node.right, targetFileName, updater);
    }
    
    // If a child was updated, recalculate this node's properties
    if (result !== undefined) {
        const leftSize = node.left?.size || 0;
        const rightSize = node.right?.size || 0;
        
        node.size = leftSize + rightSize;
        node.hash = combineHashes(
            node.left?.hash || Buffer.alloc(0),
            node.right?.hash || Buffer.alloc(0)
        );
    }
    
    return result;
}

//
// Combine two hashes to create a parent hash.
//
export function combineHashes(leftHash: Buffer, rightHash: Buffer): Buffer {
    return crypto.createHash('sha256')
        .update(leftHash)
        .update(rightHash)
        .digest();
}

/**
 * Create a new leaf node for a file
 */
export function createLeafNode(fileHash: FileHash): MerkleNode {
    return {
        hash: fileHash.hash,
        fileName: fileHash.fileName,
        nodeCount: 1, // Leaf nodes have a node count of 1.
        leafCount: 1, // Leaf nodes have a leaf count of 1.
        size: fileHash.length, // Size is the length of the file.
        lastModified: fileHash.lastModified, // Include last modified date if provided.
        minFileName: fileHash.fileName, // For leaf nodes, minFileName is the file name itself.
    };
}

/**
 * Create a parent node from two child nodes
 */
export function createParentNode(left: MerkleNode, right: MerkleNode): MerkleNode {
    return {
        hash: combineHashes(left.hash, right.hash),
        fileName: undefined, // Internal nodes don't represent a file
        nodeCount: 1 + left.nodeCount + right.nodeCount, // Total node count is 1 (this node) + left + right
        leafCount: left.leafCount + right.leafCount, // Total leaf count is the sum of both subtrees.
        size: left.size + right.size, // Total size is the sum of both subtrees.
        minFileName: left.minFileName, // Since we maintain sorted order, the min file name is always the min of the left subtree
        left: left,
        right: right,
    };
}

/**
 * Convert binary tree to flat array (for serialization)
 */
export function binaryTreeToArray(root: MerkleNode | undefined): Omit<MerkleNode, 'minFileName'>[] {
    if (!root) return [];
    
    const result: Omit<MerkleNode, 'minFileName'>[] = [];

    traverseTreeSync(root, (node) => {
        const flatNode: Omit<MerkleNode, 'minFileName'> = {
            hash: node.hash,
            fileName: node.fileName,
            nodeCount: node.nodeCount,
            leafCount: node.leafCount,
            isDeleted: node.isDeleted,
            size: node.size,
            lastModified: node.lastModified,
        };
        result.push(flatNode);
        return true;
    });
    
    return result;
}

/**
 * Convert flat array to binary tree (for loading)
 */
export function arrayToBinaryTree(nodes: Omit<MerkleNode, 'minFileName'>[]): MerkleNode | undefined {
    if (nodes.length === 0) return undefined;
    
    // For now, use a simple approach - rebuild tree structure based on the array
    // This assumes the array was created by depth-first traversal
    let index = 0;
    
    function buildNode(): MerkleNode | undefined {
        if (index >= nodes.length) return undefined;
        
        const node = { ...nodes[index++] };
        
        if (node.nodeCount === 1) {
            // Leaf node - no children
            return { 
                ...node, 
                minFileName: node.fileName!,
            };
        }
        
        // Internal node - recursively build left and right
        node.left = buildNode();
        node.right = buildNode();
        
        return { 
            ...node, 
            minFileName: node.right!.minFileName!,
        };
    }
    
    return buildNode();
}

/**
 * Rebalance a tree using AVL-like rotations to maintain both sorting and balance
 * 
 * This function checks if a tree is balanced and performs rotations if needed.
 * A tree is considered balanced if the difference between left and right subtree
 * node counts is 2 or less.
 * 
 * @param node - The node to potentially rebalance
 * @returns The rebalanced node
 */
export function rebalanceTree(node: MerkleNode): MerkleNode {
    const left = node.left;
    const right = node.right;
    if (!left || !right) {
        throw new Error('Invalid tree structure');
    }

    const leftCount = left.nodeCount;
    const rightCount = right.nodeCount;
    const balance = leftCount - rightCount;    
    if (Math.abs(balance) <= 2) {
        // If tree is reasonably balanced (difference <= 2), no rotation needed.
        return node;
    }    

    // Left-heavy tree (leftCount > rightCount + 1)
    if (balance > 0) {
        const leftLeftCount = left.left?.nodeCount || 0;
        const leftRightCount = left.right?.nodeCount || 0;
        
        // Left-Left case: rotate right
        if (leftLeftCount >= leftRightCount) {
            return rotateRight(node);
        }
        // Left-Right case: rotate left then right
        else {
            const newLeft = rotateLeft(node.left!);
            return rotateRight({ ...node, left: newLeft });
        }
    }
    // Right-heavy tree (rightCount > leftCount + 1)
    else {
        const rightLeftCount = right.left?.nodeCount || 0;
        const rightRightCount = right.right?.nodeCount || 0;
        
        // Right-Right case: rotate left
        if (rightRightCount >= rightLeftCount) {
            return rotateLeft(node);
        }
        // Right-Left case: rotate right then left
        else {
            const newRight = rotateRight(right);
            return rotateLeft({ ...node, right: newRight });
        }
    }
}

/**
 * Rotate right to balance the tree
 * 
 * This function performs a right rotation to rebalance the tree structure.
 * The left child of the input node becomes the new root, and the original
 * node becomes the right child of the new root.
 * 
 * @param node - The node to rotate
 * @returns The rotated node
 */
export function rotateRight(node: MerkleNode): MerkleNode {
    const left = node.left;
    const right = node.right;
    if (!left || !right) {
        throw new Error('Invalid tree structure');
    }

    const newLeft = left.left;
    const newCenter = left.right;
    if (!newLeft || !newCenter) {
        throw new Error('Invalid tree structure');
    }
    
    return {
        nodeCount: 1 + newLeft.nodeCount + 1 + newCenter.nodeCount + right.nodeCount,
        leafCount: newLeft.leafCount + newCenter.leafCount + right.leafCount,
        size: newLeft.size + newCenter.size + right.size,
        minFileName: newLeft.minFileName,
        hash: combineHashes(newLeft.hash, combineHashes(newCenter.hash, right.hash)),
        left: newLeft,
        right: {
            ...node, //todo: Get rid of the spreads like this.
            left: newCenter,
            right: right,
            nodeCount: 1 + newCenter.nodeCount + right.nodeCount,
            leafCount: newCenter.leafCount + right.leafCount,
            size: newCenter.size + right.size,
            minFileName: newCenter.minFileName,
            hash: combineHashes(newCenter.hash, right.hash),
        },
    };
}

/**
 * Rotate left to balance the tree
 * 
 * This function performs a left rotation to rebalance the tree structure.
 * The right child of the input node becomes the new root, and the original
 * node becomes the left child of the new root.
 * 
 * @param node - The node to rotate
 * @returns The rotated node
 */
export function rotateLeft(node: MerkleNode): MerkleNode {
    const left = node.left;
    const right = node.right;
    if (!left || !right) {
        throw new Error('Invalid tree structure');
    }

    const newRight = right.right;
    const newCenter = right.left;    
    if (!newRight || !newCenter) {
        throw new Error('Invalid tree structure');
    }
    
    return {
        nodeCount: 1 + 1 + left.nodeCount + newCenter.nodeCount + newRight.nodeCount,
        leafCount: left.leafCount + newCenter.leafCount + newRight.leafCount,
        size: left.size + newCenter.size + newRight.size,
        minFileName: left.minFileName,
        hash: combineHashes(combineHashes(left.hash, newCenter.hash), newRight.hash),
        left: {
            ...node, //todo: Get rid of the spreads like this.
            left: left,
            right: newCenter,
            nodeCount: 1 + left.nodeCount + newCenter.nodeCount,
            leafCount: left.leafCount + newCenter.leafCount,
            size: left.size + newCenter.size,
            minFileName: left.minFileName,
            hash: combineHashes(left.hash, newCenter.hash),
        },
        right: newRight,
    };
}

/**
 * Add a file to the Merkle tree using binary tree structure (avoids recursion)
 */
function _addFile(node: MerkleNode | undefined, fileHash: FileHash): MerkleNode {
    const newLeaf = createLeafNode(fileHash);

    if (!node) {
        // If the tree is empty, return the new leaf as the root
        return newLeaf;
    }
    
    // If current node is a leaf, determine correct order and create parent
    if (node.nodeCount === 1) {
        if (fileHash.fileName < node.fileName!) {
            return createParentNode(newLeaf, node); // new file goes left
        } else {
            return createParentNode(node, newLeaf); // new file goes right
        }
    }   

    const left = node.left;
    const right = node.right;
    if (!left || !right) {
        throw new Error('Invalid tree structure');
    }

    const rightMin = right.minFileName!; // If not a leaf node, there must always be a right child with a minFileName.
    let newLeft = left;
    let newRight = right;

    if (fileHash.fileName < rightMin) {
        // File should go in left subtree based on sorting
        newLeft = _addFile(left, fileHash);
    } else {
        // File should go in right subtree based on sorting
        newRight = _addFile(right, fileHash);
    }
    
    // Create new node with updated children and recalculated properties
    const newLeftCount = newLeft.nodeCount;
    const newRightCount = newRight.nodeCount;
    const newLeftLeafCount = newLeft.leafCount;
    const newRightLeafCount = newRight.leafCount;
    const newLeftSize = newLeft.size;
    const newRightSize = newRight.size;
    
    const newNode = {
        ...node,  // Copy all existing properties
        left: newLeft,
        right: newRight,
        nodeCount: 1 + newLeftCount + newRightCount,
        leafCount: newLeftLeafCount + newRightLeafCount,
        size: newLeftSize + newRightSize,
        minFileName: newLeft.minFileName,
        hash: combineHashes(newLeft.hash, newRight.hash),
    };
   
    return rebalanceTree(newNode);
}

/**
 * Create default metadata for a new tree
 */
export function createDefaultMetadata(uuid: string): TreeMetadata {
    return {
        id: uuid,
        totalNodes: 0,
        totalFiles: 0,
        totalSize: 0,
    };
}

/**
 * Update metadata when tree is modified
 */
export function updateMetadata(
    metadata: TreeMetadata, 
    totalNodes: number, 
    totalFiles: number, 
    totalSize: number
): TreeMetadata {
    return {
        ...metadata,
        totalNodes,
        totalFiles,
        totalSize,        
    };
}

//
// Create a new empty Merkle tree.
//
export function createTree<DatabaseMetadata>(uuid: string): IMerkleTree<DatabaseMetadata> {
    return {
        root: undefined,
        sortedNodeRefs: [],
        metadata: createDefaultMetadata(uuid),
        version: CURRENT_DATABASE_VERSION,
    };
}

/**
 * Add a file to the Merkle tree, efficiently creating a balanced structure
 * without rebuilding the entire tree
 */
export function addFile<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    fileHash: FileHash
): IMerkleTree<DatabaseMetadata> {

    let root: MerkleNode | undefined;
    let metadata = merkleTree.metadata;
    
    //
    // Adds the new leaf node to the merkle tree.
    //
    root = _addFile(merkleTree?.root, fileHash);

    const numFiles = merkleTree ? merkleTree.metadata.totalFiles : 0;
    let sortedNodeRefs = merkleTree ? merkleTree.sortedNodeRefs : [];
  
    //
    // Inserts the new file reference in the sorted table.
    //
    const insertionPoint = findInsertionPoint(sortedNodeRefs, fileHash.fileName);
    sortedNodeRefs = [
        ...sortedNodeRefs.slice(0, insertionPoint),
        { 
            fileName: fileHash.fileName, 
            fileIndex: numFiles, // Adding the next file.
        },
        ...sortedNodeRefs.slice(insertionPoint)
    ];

    //
    // Debug check to ensure that there are no duplicate file names in the sortedNodeRefs.
    //
    if (process.env.NODE_ENV === 'testing') {
        const fileNames = new Set<string>();
        for (const nodeRef of sortedNodeRefs) {
            if (fileNames.has(nodeRef.fileName)) {
                console.error(`Duplicate file name found in sortedNodeRefs: ${nodeRef.fileName}`);
                console.log(`Sorted node refs:`);
                for (const node of sortedNodeRefs) {
                    console.log(`  ${node.fileName} (index: ${node.fileIndex})`);
                }
                process.exit(1);
            }
            fileNames.add(nodeRef.fileName);
        }
    }
   
    return {
        root,
        sortedNodeRefs,
        metadata: updateMetadata(metadata, root?.nodeCount || 0, numFiles + 1, root?.size || 0),
        version: merkleTree?.version || CURRENT_DATABASE_VERSION,
        databaseMetadata: merkleTree?.databaseMetadata,
    };
}



//
// Upsert a file in the Merkle tree, either adding it or updating it if it already exists.
// Updates the tree in place.
//
export function upsertFile<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    fileHash: FileHash
): IMerkleTree<DatabaseMetadata> {
    if (merkleTree && merkleTree.sortedNodeRefs.length > 0) {
        if (updateFile(merkleTree, fileHash)) {
            // File updated successfully in place.
            return merkleTree;
        }
    }

    return addFile(merkleTree, fileHash);
}

/**
 * Update a file in the Merkle tree with new content, maintaining the same tree structure.
 */
export function updateFile<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata> | undefined, 
    fileHash: FileHash
): boolean {
    if (!merkleTree || !merkleTree.root) {
        throw new Error(`Tree is empty, cannot update file '${fileHash.fileName}'`);
    }
    
    // Find the node to update using binary search
    const nodeRef = findNodeRef(merkleTree, fileHash.fileName);
    if (!nodeRef) {
        // File not found in the tree
        return false;
    }
    
    // Use the centralized updateNodeInTree function
    const wasUpdated = updateNodeInTree(merkleTree.root, fileHash.fileName, (node, targetFileName) => {
        // Update the leaf node in place
        node.hash = fileHash.hash;
        node.lastModified = fileHash.lastModified;
        node.size = fileHash.length; // Update the size with the new file length
        return true; // Found and updated
    }) ?? false;
    
    if (wasUpdated) {
        // Update metadata with new root size  
        merkleTree.metadata = updateMetadata(
            merkleTree.metadata,
            merkleTree.root.nodeCount,
            merkleTree.metadata.totalFiles,
            merkleTree.root.size
        );
    }
    
    return wasUpdated;
}

//
// Binary search to find the location or insertion point for a file hash.
//
export function findInsertionPoint(sortedNodeRefs: MerkleNodeRef[], fileName: string): number {
    if (sortedNodeRefs.length === 0) {
        return 0; // No existing nodes, insert at the beginning.
    }

    let low = 0;
    let high = sortedNodeRefs.length - 1;

    // Quick checks for first and last position
    if (fileName.localeCompare(sortedNodeRefs[0].fileName) < 0) {
        return 0;
    }
    
    if (fileName.localeCompare(sortedNodeRefs[high].fileName) > 0) {
        return sortedNodeRefs.length;
    }

    while (low <= high) {
        const mid = Math.floor((low + high) / 2);
        const comparison = fileName.localeCompare(sortedNodeRefs[mid].fileName);
        
        if (comparison === 0) {
            // Exact match found, return this position
            return mid;
        } else if (comparison < 0) {
            high = mid - 1;
        } else {
            low = mid + 1;
        }
    }

    return low; // This is the insertion point
}

//
// Binary search to find a file node reference by file name
//
export function findNodeRef<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata>, fileName: string): MerkleNodeRef | undefined {
    if (!merkleTree || !merkleTree.sortedNodeRefs || merkleTree.sortedNodeRefs.length === 0) {
        return undefined;
    }

    let low = 0;
    let high = merkleTree.sortedNodeRefs.length - 1;

    while (low <= high) {
        const mid = Math.floor((low + high) / 2);
        const comparison = fileName.localeCompare(merkleTree.sortedNodeRefs[mid].fileName);
        
        if (comparison === 0) {
            // Exact match found
            return merkleTree.sortedNodeRefs[mid];
        } else if (comparison < 0) {
            high = mid - 1;
        } else {
            low = mid + 1;
        }
    }

    return undefined; // The node is not in the tree
}

//
// Get file information from merkle tree (hash, size, lastModified)
// This replaces the need for database hash cache lookups
//
export function getFileInfo<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata>, fileName: string): { hash: Buffer, length: number, lastModified: Date } | undefined {
    const nodeRef = findNodeRef(merkleTree, fileName);
    if (!nodeRef || nodeRef.isDeleted) {
        return undefined;
    }

    // Use the centralized findFileInTree function
    const leafNode = findFileInTree(merkleTree.root, fileName);

    if (!leafNode?.lastModified) {
        throw new Error(`File ${fileName} is missing lastModified date. This could be a bug.`);
    }
    
    if (!leafNode) {
        return undefined;
    }

    return {
        hash: leafNode.hash,
        length: leafNode.size,
        lastModified: leafNode.lastModified,
    };
}

/**
 * Find a file node in the tree by file name
 * 
 * This function uses binary search on the sorted node refs to quickly find a node by file name.
 * Returns the node if found, or undefined if not found.
 */
export function findFileNode<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata> | undefined, fileName: string): MerkleNode | undefined {
    // Use the enhanced version that respects deletion status
    // This ensures backward compatibility while making sure deleted files are not returned
    return findFileNodeWithDeletionStatus(merkleTree, fileName, false);
}

/**
 * Visualize a Merkle tree in ASCII format and display sorted node references
 * 
 * @param merkleTree The Merkle tree to visualize
 * @returns A string representation of the tree and sorted node references
 */
export function visualizeTree<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata>): string {
    if (!merkleTree || !merkleTree.root) {
        return "Empty tree";
    }

    let result = "Merkle Tree Structure:\n";
    
    // Add metadata if available
    if (merkleTree.metadata) {
        result += "\nTree Metadata:\n";
        result += `  UUID: ${merkleTree.metadata.id}\n`;
        result += `  Total Nodes: ${merkleTree.metadata.totalNodes}\n`;
        result += `  Total Files: ${merkleTree.metadata.totalFiles}\n`;
        result += `  Total Size: ${merkleTree.metadata.totalSize} bytes\n`;
    }
    
    // Add database metadata if available (version 3+)
    if (merkleTree.databaseMetadata) {
        result += "\nDatabase Metadata:\n";
        
        // Show all database metadata fields
        for (const [key, value] of Object.entries(merkleTree.databaseMetadata)) {
            result += `  ${key}: ${value}\n`;
        }
    }
    
    result += `\nVersion: ${merkleTree.version}\n\n`;
    
    // Recursive function to build the ASCII tree from binary tree structure
    function buildTreeString(node: MerkleNode, prefix: string, isLast: boolean): string {
        const hashStr = node.hash.toString('hex');
        const hashPreview = `${hashStr.slice(0, 4)}-${hashStr.slice(-4)}`;
        
        // Determine the branch character
        const branchChar = isLast ? "└── " : "├── ";
        const nodeStr = prefix + branchChar;
        
        let treeStr = "";
        
        if (node.nodeCount === 1) {
            // Leaf node
            const deletedStatus = node.isDeleted ? " [DELETED]" : "";
            const detailPrefix = prefix + (isLast ? "    " : "│   ") + "    ";
            const leafHeader = `Leaf${deletedStatus}`;
            const paddedLeafHeader = leafHeader.padEnd(13);
            
            // Add spacing line that preserves tree structure
            const spacingPrefix = prefix + "│   ";
            treeStr += `${spacingPrefix}\n${nodeStr}${paddedLeafHeader} ${hashPreview}\n`;
            
            // Add file details
            treeStr += `${detailPrefix}Full:     ${hashStr}\n`;
            if (node.fileName) {
                treeStr += `${detailPrefix}File:     ${node.fileName}\n`;
            }
            if (node.size) {
                treeStr += `${detailPrefix}Size:     ${node.size} bytes\n`;
            }
            if (node.lastModified) {
                treeStr += `${detailPrefix}Modified: ${node.lastModified.toISOString()}\n`;
            }
        } else {
            // Internal node
            const detailPrefix = prefix + (isLast ? "    " : "│   ") + "│   ";
            const nodeHeader = `Node`;
            const paddedNodeHeader = nodeHeader.padEnd(11);
            
            // Add spacing line
            const spacingPrefix = prefix + "│   ";
            treeStr += `${spacingPrefix}\n${nodeStr}${paddedNodeHeader} ${hashPreview}\n`;
            
            // Add node details
            treeStr += `${detailPrefix}Full:   ${hashStr}\n`;
            treeStr += `${detailPrefix}Count:  ${node.nodeCount} nodes\n`;
            treeStr += `${detailPrefix}Leaves: ${node.leafCount} files\n`;
            treeStr += `${detailPrefix}Size:   ${node.size} bytes\n`;
            
            // Recursively add children
            const childPrefix = prefix + (isLast ? "    " : "│   ");
            
            // Add left child
            if (node.left) {
                treeStr += buildTreeString(node.left, childPrefix, !node.right);
            }
            
            // Add right child
            if (node.right) {
                treeStr += buildTreeString(node.right, childPrefix, true);
            }
        }
        
        return treeStr;
    }
    
    // Start building the tree from the root
    result += buildTreeString(merkleTree.root, "", true);
    
    // Add sorted node references
    result += "\nSorted Node References:\n";
    if (merkleTree.sortedNodeRefs.length === 0) {
        result += "  (None)\n";
    } else {
        merkleTree.sortedNodeRefs.forEach((nodeRef, index) => {
            const deletedStatus = nodeRef.isDeleted ? " [DELETED]" : "";
            result += `  ${index + 1}. ${nodeRef.fileName}${deletedStatus} -> File[${nodeRef.fileIndex}]\n`;
        });
    }
    
    return result;
}

//
// Splits a large number into high and low 32-bit parts.
//
function splitBigNum(input: bigint): { high: number, low: number } {
    // Get low 32 bits using bitwise AND
    const low = Number(input & 0xFFFFFFFFn);
    
    // Get high bits by right shifting 32 positions
    const high = Number(input >> 32n);
    
    return { high, low };
}

//
// Combines two 32-bit numbers into a single 64-bit bigint.
//
function combineBigNum(input: { low: number, high: number }): bigint {
    return BigInt(input.high) * (1n << 32n) + BigInt(input.low);
}

/**
 * Merkle tree file format.
 * 
 * Version 2 format:
 * - 4 bytes: Format version (uint32, value = 2)
 * - Tree metadata and nodes (as in version 1)
 * 
 * Version 3 format (new):
 * - 4 bytes: Format version (uint32, value = 3)
 * - 4 bytes: Database metadata BSON length (uint32)
 * - X bytes: Database metadata as BSON (replaces metadata.json)
 * - Tree metadata:
 *   - 16 bytes: UUID bytes
 *   - 4 bytes: Total nodes (uint32)
 *   - 4 bytes: Total files (uint32)
 *   - 8 bytes: Total size (uint64)
 *   - 8 bytes: Creation timestamp (uint64)
 *   - 8 bytes: Last modified timestamp (uint64)
 * - For each node:
 *   - 32 bytes: Hash
 *   - 4 bytes: nodeCount (uint32)
 *   - 4 bytes: leafCount (uint32)
 *   - 8 bytes: size (uint64)
 *   - 4 bytes: fileNameLength (uint32)
 *   - X bytes: fileName (if fileNameLength > 0)
 *   - 1 byte: isDeleted flag (0 = not deleted, 1 = deleted)
 * - 4 bytes: Number of nodeRefs (uint32)
 * - For each nodeRef:
 *   - 4 bytes: fileNameLength (uint32)
 *   - X bytes: fileName
 *   - 4 bytes: fileIndex (uint32)
 *   - 1 byte: isDeleted flag (0 = not deleted, 1 = deleted)
 */
function serializeMerkleTree<DatabaseMetadata>(tree: IMerkleTree<DatabaseMetadata>, serializer: ISerializer): void {
    // Write database metadata BSON (always present in version 3+)
    serializer.writeBSON(tree.databaseMetadata);
        
    // Write tree metadata.
    // Write UUID
    const idBuffer = Buffer.from(parseUuid(tree.metadata.id));
    if (idBuffer.length !== 16) {
        throw new Error(`Invalid UUID length: ${idBuffer.length}`);
    }
    serializer.writeBytes(idBuffer);
    
    // Write totalNodes
    serializer.writeUInt32(tree.metadata.totalNodes);
    
    // Write totalFiles
    serializer.writeUInt32(tree.metadata.totalFiles);

    // Write totalSize
    const splitTotalSize = splitBigNum(BigInt(tree.metadata.totalSize));
    serializer.writeUInt32(splitTotalSize.low);
    serializer.writeUInt32(splitTotalSize.high);
    
    // Convert binary tree to flat array for serialization
    const nodes = binaryTreeToArray(tree.root);
    
    // Write all nodes
    for (const node of nodes) {
        // Write hash
        serializer.writeBytes(node.hash);
        
        // Write nodeCount
        serializer.writeUInt32(node.nodeCount);
        
        // Write leafCount
        serializer.writeUInt32(node.leafCount);

        // Write tree size
        const splitSize = splitBigNum(BigInt(node.size));
        serializer.writeUInt32(splitSize.low);
        serializer.writeUInt32(splitSize.high);
        
        // Write fileName if present
        if (node.fileName) {
            const fileNameLength = Buffer.byteLength(node.fileName, 'utf8');
            serializer.writeUInt32(fileNameLength);
            // Create a buffer with exact length and write string into it
            const fileNameBuffer = Buffer.alloc(fileNameLength);
            fileNameBuffer.write(node.fileName, 0, 'utf8');
            serializer.writeBytes(fileNameBuffer);
            
            // Write file metadata for leaf nodes in version 3+
            // Write lastModified timestamp (8 bytes)
            const lastModified = node.lastModified ? node.lastModified.getTime() : 0;
            const splitLastModified = splitBigNum(BigInt(lastModified));
            serializer.writeUInt32(splitLastModified.low);
            serializer.writeUInt32(splitLastModified.high);
        } else {
            // No fileName
            serializer.writeUInt32(0);
        }
        
        // Write isDeleted flag
        serializer.writeUInt8(node.isDeleted ? 1 : 0);
    }
    
    // Write nodeRefs count
    serializer.writeUInt32(tree.sortedNodeRefs.length);
    
    // Write all nodeRefs
    for (const nodeRef of tree.sortedNodeRefs) {
        // Write fileName
        const fileNameLength = Buffer.byteLength(nodeRef.fileName, 'utf8');
        serializer.writeUInt32(fileNameLength);
        // Create a buffer with exact length and write string into it
        const fileNameBuffer = Buffer.alloc(fileNameLength);
        fileNameBuffer.write(nodeRef.fileName, 0, 'utf8');
        serializer.writeBytes(fileNameBuffer);
        
        // Write fileIndex
        serializer.writeUInt32(nodeRef.fileIndex);
        
        // Write isDeleted flag
        serializer.writeUInt8(nodeRef.isDeleted ? 1 : 0);
    }
}

//
// Deserializer function for merkle tree (version 4+)
//
function deserializeMerkleTreeV4<DatabaseMetadata>(deserializer: IDeserializer): IMerkleTree<DatabaseMetadata> {
    // Read database metadata BSON for version 3+
    const databaseMetadata = deserializer.readBSON<DatabaseMetadata>();
    
    // Read tree metadata fields
    const uuidBytes = deserializer.readBytes(16);
    const uuid = stringifyUuid(uuidBytes);
    
    const totalNodes = deserializer.readUInt32();
    
    const totalFiles = deserializer.readUInt32();

    const totalSizeLow = deserializer.readUInt32();
    const totalSizeHigh = deserializer.readUInt32();
    const totalSize = Number(combineBigNum({ low: totalSizeLow, high: totalSizeHigh }));
    
    // Create metadata object
    const metadata: TreeMetadata = {
        id: uuid,
        totalNodes,
        totalFiles,
        totalSize,
    };
    
    // Read all nodes
    const nodes: Omit<MerkleNode, 'minFileName'>[] = [];
    
    for (let i = 0; i < totalNodes; i++) {
        // Read hash
        const hash = deserializer.readBytes(32);
        
        // Read nodeCount
        const nodeCount = deserializer.readUInt32();
        
        // Read leafCount
        const leafCount = deserializer.readUInt32();

        // Read tree size.
        const sizeLow = deserializer.readUInt32();
        const sizeHigh = deserializer.readUInt32();
        const size = Number(combineBigNum({ low: sizeLow, high: sizeHigh }));

        // Read fileName if present
        const fileNameLength = deserializer.readUInt32();
        
        let fileName: string | undefined;
        let lastModified: Date | undefined;
        
        if (fileNameLength > 0) {
            const fileNameBytes = deserializer.readBytes(fileNameLength);
            fileName = fileNameBytes.toString('utf8');
            
            // Read file metadata for leaf nodes in version 3+
            // Read lastModified timestamp (8 bytes)
            const lastModifiedLow = deserializer.readUInt32();
            const lastModifiedHigh = deserializer.readUInt32();
            const lastModifiedTimestamp = Number(combineBigNum({ low: lastModifiedLow, high: lastModifiedHigh }));
            if (lastModifiedTimestamp > 0) {
                lastModified = new Date(lastModifiedTimestamp);
            }
        }
        
        // Read isDeleted flag (if exists in format)
        const isDeleted = deserializer.readUInt8() === 1;
        
        // Create node
        nodes.push({
            hash,
            fileName,
            nodeCount,
            leafCount,
            size,
            isDeleted,
            lastModified
        });
    }
    
    // Read all nodeRefs
    const nodeRefCount = deserializer.readUInt32();
    
    const sortedNodeRefs: MerkleNodeRef[] = [];
    
    for (let i = 0; i < nodeRefCount; i++) {
        // Read fileName
        const fileNameLength = deserializer.readUInt32();
        const fileName = deserializer.readBytes(fileNameLength).toString('utf8');
        
        // Read fileIndex
        const fileIndex = deserializer.readUInt32();
        
        // Read isDeleted flag (if exists in format)
        const isDeleted = deserializer.readUInt8() === 1;
        
        // Create nodeRef
        sortedNodeRefs.push({
            fileName,
            fileIndex,
            isDeleted
        });
    }
    
    return {
        root: arrayToBinaryTree(nodes),
        sortedNodeRefs,
        metadata,
        databaseMetadata,
        version: 4,
    };
}

//
// Deserializer function for merkle tree (version 3)
//
function deserializeMerkleTreeV3<DatabaseMetadata>(deserializer: IDeserializer): IMerkleTree<DatabaseMetadata> {
    // Read database metadata BSON for version 3+
    const databaseMetadata = deserializer.readBSON<DatabaseMetadata>();
    
    // Read tree metadata fields
    const uuidBytes = deserializer.readBytes(16);
    const uuid = stringifyUuid(uuidBytes);
    
    const totalNodes = deserializer.readUInt32();
    
    const totalFiles = deserializer.readUInt32();

    const totalSizeLow = deserializer.readUInt32();
    const totalSizeHigh = deserializer.readUInt32();
    const totalSize = Number(combineBigNum({ low: totalSizeLow, high: totalSizeHigh }));
    
    // Create metadata object
    const metadata: TreeMetadata = {
        id: uuid,
        totalNodes,
        totalFiles,
        totalSize,
    };
    
    // Read all nodes
    const nodes: Omit<MerkleNode, 'minFileName'>[] = [];
    
    for (let i = 0; i < totalNodes; i++) {
        // Read hash
        const hash = deserializer.readBytes(32);
        
        // Read nodeCount
        const nodeCount = deserializer.readUInt32();
        
        // Read leafCount
        const leafCount = deserializer.readUInt32();

        // Read tree size.
        const sizeLow = deserializer.readUInt32();
        const sizeHigh = deserializer.readUInt32();
        const size = Number(combineBigNum({ low: sizeLow, high: sizeHigh }));

        // Read fileName if present
        const fileNameLength = deserializer.readUInt32();
        
        let fileName: string | undefined;
        let lastModified: Date | undefined;
        
        if (fileNameLength > 0) {
            const fileNameBytes = deserializer.readBytes(fileNameLength);
            fileName = fileNameBytes.toString('utf8');
            
            // Read file metadata for leaf nodes in version 3+
            // Read lastModified timestamp (8 bytes)
            const lastModifiedLow = deserializer.readUInt32();
            const lastModifiedHigh = deserializer.readUInt32();
            const lastModifiedTimestamp = Number(combineBigNum({ low: lastModifiedLow, high: lastModifiedHigh }));
            if (lastModifiedTimestamp > 0) {
                lastModified = new Date(lastModifiedTimestamp);
            }
        }
        
        // Read isDeleted flag (if exists in format)
        const isDeleted = deserializer.readUInt8() === 1;
        
        // Create node
        nodes.push({
            hash,
            fileName,
            nodeCount,
            leafCount,
            size,
            isDeleted,
            lastModified
        });
    }
    
    // Read all nodeRefs
    const nodeRefCount = deserializer.readUInt32();
    
    const sortedNodeRefs: MerkleNodeRef[] = [];
    
    for (let i = 0; i < nodeRefCount; i++) {
        // Read fileName
        const fileNameLength = deserializer.readUInt32();
        const fileName = deserializer.readBytes(fileNameLength).toString('utf8');
        
        // Read fileIndex
        const fileIndex = deserializer.readUInt32();
        
        // Read isDeleted flag (if exists in format)
        const isDeleted = deserializer.readUInt8() === 1;
        
        // Create nodeRef
        sortedNodeRefs.push({
            fileName,
            fileIndex,
            isDeleted
        });
    }
    
    return {
        root: arrayToBinaryTree(nodes),
        sortedNodeRefs,
        metadata,
        databaseMetadata,
        version: 3,
    };
}

//
// Deserializer function for merkle tree (version 2)
//
function deserializeMerkleTreeV2<DatabaseMetadata>(deserializer: IDeserializer): IMerkleTree<DatabaseMetadata> {
    
    // Read tree metadata fields
    const uuidBytes = deserializer.readBytes(16);
    const uuid = stringifyUuid(uuidBytes);
    
    const totalNodes = deserializer.readUInt32();
    
    const totalFiles = deserializer.readUInt32();

    const totalSizeLow = deserializer.readUInt32();
    const totalSizeHigh = deserializer.readUInt32();
    const totalSize = Number(combineBigNum({ low: totalSizeLow, high: totalSizeHigh }));
    
    deserializer.readUInt32(); // Created at low removed in v3.
    deserializer.readUInt32(); // Created at high removed in v3.
    deserializer.readUInt32(); // Modified at low removed in v3.
    deserializer.readUInt32(); // Modified at high removed in v3.

    // Create metadata object
    const metadata: TreeMetadata = {
        id: uuid,
        totalNodes,
        totalFiles,
        totalSize,
    };
    
    // Read all nodes
    const nodes: Omit<MerkleNode, 'minFileName'>[] = [];
    
    for (let i = 0; i < totalNodes; i++) {
        // Read hash
        const hash = deserializer.readBytes(32);
        
        // Read nodeCount
        const nodeCount = deserializer.readUInt32();
        
        // Read leafCount
        const leafCount = deserializer.readUInt32();

        // Read tree size.
        const sizeLow = deserializer.readUInt32();
        const sizeHigh = deserializer.readUInt32();
        const size = Number(combineBigNum({ low: sizeLow, high: sizeHigh }));

        // Read fileName if present
        const fileNameLength = deserializer.readUInt32();
        
        let fileName: string | undefined;
        let lastModified: Date | undefined;
        
        if (fileNameLength > 0) {
            const fileNameBytes = deserializer.readBytes(fileNameLength);
            fileName = fileNameBytes.toString('utf8');            
        }
        
        // Read isDeleted flag (if exists in format)
        const isDeleted = deserializer.readUInt8() === 1;
        
        // Create node
        nodes.push({
            hash,
            fileName,
            nodeCount,
            leafCount,
            size,
            isDeleted,
            lastModified
        });
    }
    
    // Read all nodeRefs
    const nodeRefCount = deserializer.readUInt32();
    
    const sortedNodeRefs: MerkleNodeRef[] = [];
    
    for (let i = 0; i < nodeRefCount; i++) {
        // Read fileName
        const fileNameLength = deserializer.readUInt32();
        const fileName = deserializer.readBytes(fileNameLength).toString('utf8');
        
        // Read fileIndex
        const fileIndex = deserializer.readUInt32();
        
        // Read isDeleted flag (if exists in format)
        const isDeleted = deserializer.readUInt8() === 1;
        
        // Create nodeRef
        sortedNodeRefs.push({
            fileName,
            fileIndex,
            isDeleted
        });
    }
    
    return {
        root: arrayToBinaryTree(nodes),
        sortedNodeRefs,
        metadata,
        databaseMetadata: undefined,
        version: 2,
    };
}

//
// Saves a merkle tree to storage.
//
export async function saveTree<DatabaseMetadata>(filePath: string, tree: IMerkleTree<DatabaseMetadata>, storage: IStorage): Promise<void> {
    await save(
        storage,
        filePath,
        tree,
        CURRENT_DATABASE_VERSION,
        serializeMerkleTree,
        {
            checksum: false,
        }
    );
}

//
// Loads only the version number from a merkle tree file without loading the entire tree.
// This is useful for version compatibility checks before full database loading.
// Uses streaming to read only the first 4 bytes for efficiency.
//
export async function loadTreeVersion(filePath: string, storage: IStorage): Promise<number | undefined> {
    return new Promise((resolve, reject) => {
        const stream = storage.readStream(filePath);
        let versionBuffer = Buffer.alloc(4);
        let bytesRead = 0;

        stream.on('data', (chunk: Buffer) => {
            if (bytesRead < 4) {
                const bytesToCopy = Math.min(chunk.length, 4 - bytesRead);
                chunk.copy(versionBuffer, bytesRead, 0, bytesToCopy);
                bytesRead += bytesToCopy;
                
                if (bytesRead >= 4) {
                    // We have enough bytes, close the stream and resolve
                    if ('destroy' in stream && typeof stream.destroy === 'function') {
                        stream.destroy();
                    }
                    resolve(versionBuffer.readUInt32LE(0));
                }
            }
        });

        stream.on('end', () => {
            if (bytesRead < 4) {
                resolve(undefined); // File too small or empty
            } else {
                resolve(versionBuffer.readUInt32LE(0));
            }
        });

        stream.on('error', (error) => {
            reject(error);
        });
    });
}

export async function loadTree<DatabaseMetadata>(filePath: string, storage: IStorage): Promise<IMerkleTree<DatabaseMetadata> | undefined> {
    const deserializers = {
        4: deserializeMerkleTreeV4<DatabaseMetadata>,
        3: deserializeMerkleTreeV3<DatabaseMetadata>,
        2: deserializeMerkleTreeV2<DatabaseMetadata>,
    };
    
    return await load<IMerkleTree<DatabaseMetadata>>(
        storage,
        filePath,
        deserializers,
        undefined,
        CURRENT_DATABASE_VERSION,
        {
            checksum: false,
        }
    );
}

/**
 * Creates a tombstone hash to represent a deleted file
 */
function createTombstoneHash(fileName: string): Buffer {
    return crypto.createHash('sha256')
        .update('DELETED:' + fileName)
        .digest();
}

/**
 * Mark a file as deleted in the Merkle tree without removing the node
 * This preserves the tree structure while indicating the file is deleted
 * 
 * @param merkleTree The Merkle tree containing the file
 * @param fileName The name of the file to mark as deleted
 * @returns true if the file was found and marked as deleted, false otherwise
 */
export function markFileAsDeleted<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    fileName: string
): boolean {
    if (!merkleTree || !merkleTree.root) {
        return false;
    }
    
    // Find the node reference to mark as deleted
    const nodeRef = findNodeRef(merkleTree, fileName);
    if (!nodeRef) {
        return false; // File not found
    }
    
    // Mark the node reference as deleted
    nodeRef.isDeleted = true;
    
    // Use the centralized updateNodeInTree function to mark the node as deleted
    const wasMarked = updateNodeInTree(merkleTree.root, fileName, (node, targetFileName) => {
        // Mark the leaf node as deleted
        node.isDeleted = true;
        node.hash = createTombstoneHash(targetFileName);
        node.size = 0;
        return true; // Found and marked
    });
    
    // Update metadata if it exists
    if (merkleTree.metadata && wasMarked) {
        merkleTree.metadata = updateMetadata(
            merkleTree.metadata, 
            merkleTree.root.nodeCount,
            merkleTree.metadata.totalFiles,
            merkleTree.root.size
        );
    }
    
    return true;
}

/**
 * Completely removes multiple files from the merkle tree by rebuilding the tree without those files.
 * This is different from markFileAsDeleted which only marks files as deleted but keeps the nodes.
 * 
 * WARNING: This function is inefficient as it rebuilds the entire tree. Use sparingly and prefer
 * markFileAsDeleted for most use cases. This function is intended for cleanup operations like
 * database upgrades where a complete rebuild is acceptable.
 * 
 * @param merkleTree The merkle tree to remove the files from
 * @param fileNames Array of file names to completely remove
 * @returns number of files that were found and removed
 */
export function deleteFiles<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    fileNames: string[]
): number {
    if (!merkleTree || merkleTree.sortedNodeRefs.length === 0) {
        throw new Error("Cannot delete files from empty or invalid merkle tree");
    }
    
    if (fileNames.length === 0) {
        throw new Error("Cannot delete files: no file names provided");
    }
    
    // Create a set for efficient lookup and check all files exist
    const filesToDelete = new Set(fileNames);
    const existingFiles = new Set(merkleTree.sortedNodeRefs.filter(ref => !ref.isDeleted).map(ref => ref.fileName));
    
    // Check if any files don't exist
    const nonExistentFiles = fileNames.filter(fileName => !existingFiles.has(fileName));
    if (nonExistentFiles.length > 0) {
        throw new Error(`Cannot delete files: the following files do not exist: ${nonExistentFiles.join(', ')}`);
    }
    
    let filesRemoved = 0;
    
    // Get all remaining files (excluding the ones to delete)
    const remainingFiles: FileHash[] = [];
    
    for (const nodeRef of merkleTree.sortedNodeRefs) {
        if (!nodeRef.isDeleted) {
            if (filesToDelete.has(nodeRef.fileName)) {
                filesRemoved++;
            } else {
                // Use the centralized findFileInTree function
                const node = findFileInTree(merkleTree.root, nodeRef.fileName);
                
                if (node && node.fileName && node.lastModified) {
                    remainingFiles.push({
                        fileName: node.fileName,
                        hash: node.hash,
                        length: node.size,
                        lastModified: node.lastModified
                    });
                }
            }
        }
    }
    
    // If no files remain, create an empty tree
    if (remainingFiles.length === 0) {
        merkleTree.root = undefined;
        merkleTree.sortedNodeRefs = [];
        if (merkleTree.metadata) {
            merkleTree.metadata.totalFiles = 0;
            merkleTree.metadata.totalNodes = 0;
            merkleTree.metadata.totalSize = 0;
        }
        return filesRemoved;
    }
    
    // Rebuild the tree with the remaining files
    let newTree = createTree<DatabaseMetadata>(merkleTree.metadata.id);
    for (const fileHash of remainingFiles) {
        newTree = addFile(newTree, fileHash);
    }
    
    // Preserve the original metadata but update file counts
    if (merkleTree.metadata) {
        newTree.metadata = {
            ...merkleTree.metadata,
            totalFiles: remainingFiles.length,
            totalNodes: newTree.root?.nodeCount || 0,
            totalSize: newTree.root?.size || 0
        };
    }
    
    // Replace the tree contents
    merkleTree.root = newTree.root;
    merkleTree.sortedNodeRefs = newTree.sortedNodeRefs;
    merkleTree.metadata = newTree.metadata;
    
    return filesRemoved;
}

/**
 * Checks if a file is marked as deleted in the Merkle tree
 * 
 * @param merkleTree The Merkle tree to check
 * @param fileName The name of the file to check
 * @returns true if the file exists and is marked as deleted, false otherwise
 */
export function isFileDeleted<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata>, fileName: string): boolean {
    if (!merkleTree || !merkleTree.root) {
        return false;
    }
    
    const nodeRef = findNodeRef(merkleTree, fileName);
    return nodeRef ? !!nodeRef.isDeleted : false;
}

/**
 * Get all active (non-deleted) files in the Merkle tree
 * 
 * @param merkleTree The Merkle tree to get active files from
 * @returns An array of file names that are not marked as deleted
 */
export function getActiveFiles<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata>): string[] {
    if (!merkleTree || !merkleTree.root) {
        return [];
    }
    
    return merkleTree.sortedNodeRefs
        .filter(nodeRef => !nodeRef.isDeleted)
        .map(nodeRef => nodeRef.fileName);
}

/**
 * Modified version of findFileNode that optionally includes or excludes deleted files
 * 
 * @param merkleTree The Merkle tree to search
 * @param fileName The name of the file to find
 * @param includeDeleted Whether to include deleted files in the search (defaults to false)
 * @returns The node if found and matching the deletion criteria, undefined otherwise
 */
export function findFileNodeWithDeletionStatus<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata> | undefined, 
    fileName: string,
    includeDeleted: boolean = false
): MerkleNode | undefined {
    if (!merkleTree || !merkleTree.root) {
        return undefined;
    }

    if (merkleTree.sortedNodeRefs.length === 0) {
        throw new Error(`Node refs are empty, cannot find file '${fileName}'`);
    }

    const nodeRef = findNodeRef(merkleTree, fileName);
    if (nodeRef) {
        // Check if the file is deleted and we're not including deleted files
        if (nodeRef.isDeleted && !includeDeleted) {
            return undefined;
        }
        
        // Search in the binary tree for the actual node
        function searchTree(node: MerkleNode | undefined, targetFileName: string): MerkleNode | undefined {
            if (!node) return undefined;

            if (node.nodeCount === 1) { // Leaf node
                if (node.fileName === targetFileName) {
                    return (includeDeleted || !node.isDeleted) ? node : undefined;
                }
                return undefined;
            }

            // Internal node, search children
            const leftResult = searchTree(node.left, targetFileName);
            if (leftResult) return leftResult;

            return searchTree(node.right, targetFileName);
        }

        return searchTree(merkleTree.root, fileName);
    }
    return undefined;
}

//
// The result of a comparison between two Merkle trees.
// 
export interface ICompareResult {
    onlyInA: string[];
    onlyInB: string[];
    modified: string[];
    deleted: string[];
}

/**
 * Compare two Merkle trees and show the differences between them
 * 
 * @param treeA The first Merkle tree
 * @param treeB The second Merkle tree
 * @returns An object containing the differences between the trees
 */
export function compareTrees<DatabaseMetadata>(treeA: IMerkleTree<DatabaseMetadata>, treeB: IMerkleTree<DatabaseMetadata>, progressCallback?: (progress: string) => void): ICompareResult {
    // Get all files from both trees (including deleted ones for tree A)
    const filesInA = new Map<string, { hash: string, isDeleted: boolean }>();
    const filesInB = new Map<string, { hash: string, isDeleted: boolean }>();
    
    const totalFiles = treeA.sortedNodeRefs.length + treeB.sortedNodeRefs.length;
    let processedFiles = 0;
    
    // Process files in tree A
    for (const nodeRef of treeA.sortedNodeRefs) {
        processedFiles++;
        if (progressCallback && processedFiles % 1000 === 0) {
            progressCallback(`Indexing sources files | ${processedFiles} of ${treeA.sortedNodeRefs.length} files`);
        }
        
        const node = findFileInTree(treeA.root, nodeRef.fileName);
        if (node) {
            filesInA.set(nodeRef.fileName, { 
                hash: node.hash.toString('hex'),
                isDeleted: !!nodeRef.isDeleted
            });
        }
    }
    
    // Process files in tree B
    for (const nodeRef of treeB.sortedNodeRefs) {
        processedFiles++;
        if (progressCallback && (processedFiles - treeA.sortedNodeRefs.length) % 1000 === 0) {
            progressCallback(`Indexing dest files | ${processedFiles - treeA.sortedNodeRefs.length} of ${treeB.sortedNodeRefs.length} files`);
        }
        
        const node = findFileInTree(treeB.root, nodeRef.fileName);
        if (node) {
            filesInB.set(nodeRef.fileName, { 
                hash: node.hash.toString('hex'),
                isDeleted: !!nodeRef.isDeleted
            });
        }
    }
    
    // Find differences
    const onlyInA: string[] = [];
    const onlyInB: string[] = [];
    const modified: string[] = [];
    const deleted: string[] = [];
    
    let comparedFiles = 0;
    
    // Files only in A or modified
    for (const [fileName, fileInfoA] of filesInA) {
        comparedFiles++;
        if (progressCallback && comparedFiles % 1000 === 0) {
            progressCallback(`Comparing source files | ${comparedFiles} of ${filesInA.size} files`);
        }
        if (fileInfoA.isDeleted) {
            // Skip files marked as deleted in A for the onlyInA list
            continue;
        }
        
        const fileInfoB = filesInB.get(fileName);
        if (!fileInfoB) {
            // File exists in A but not in B
            onlyInA.push(fileName);
        } else if (!fileInfoB.isDeleted && fileInfoA.hash !== fileInfoB.hash) {
            // File exists in both but has different hash (modified)
            modified.push(fileName);
        }
    }
    
    comparedFiles = 0;
    
    // Files only in B
    for (const [fileName, fileInfoB] of filesInB) {
        comparedFiles++;
        if (progressCallback && comparedFiles % 1000 === 0) {
            progressCallback(`Comparing destination files | ${comparedFiles} of ${filesInB.size} files`);
        }
        if (fileInfoB.isDeleted) {
            // Skip files marked as deleted in B
            continue;
        }
        
        const fileInfoA = filesInA.get(fileName);
        if (!fileInfoA) {
            // File exists in B but not in A
            onlyInB.push(fileName);
        } else if (fileInfoA.isDeleted) {
            // File is deleted in A but exists in B
            deleted.push(fileName);
        }
    }
    
    return {
        onlyInA,
        onlyInB,
        modified,
        deleted
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
    
    // Deleted files (deleted in A, present in B)
    report += "\nDeleted files (marked as deleted in first tree, present in second):\n";
    if (diff.deleted.length === 0) {
        report += "  (None)\n";
    } else {
        diff.deleted.forEach(file => {
            report += `  - ${file}\n`;
        });
    }
    
    // Summary
    report += "\nSummary:\n";
    report += `  ${diff.onlyInA.length} files only in first tree\n`;
    report += `  ${diff.onlyInB.length} files only in second tree\n`;
    report += `  ${diff.modified.length} modified files\n`;
    report += `  ${diff.deleted.length} deleted files\n`;
    
    return report;
}

//
// Traverse the tree and call the callback function for each node.
// If the callback returns false, the traversal stops.
//
export async function traverseTree<DatabaseMetadata>(tree: IMerkleTree<DatabaseMetadata>, callback: (node: MerkleNode) => Promise<boolean>): Promise<void>  {
    if (!tree || !tree.root) {
        return;
    }

    async function traverseBinaryTree(node: MerkleNode | undefined): Promise<boolean> {
        if (!node) return true;
        
        const shouldContinue = await callback(node);
        if (!shouldContinue) return false;
        
        if (node.left) {
            const leftContinue = await traverseBinaryTree(node.left);
            if (!leftContinue) return false;
        }
        
        if (node.right) {
            const rightContinue = await traverseBinaryTree(node.right);
            if (!rightContinue) return false;
        }
        
        return true;
    }

    await traverseBinaryTree(tree.root);
}
