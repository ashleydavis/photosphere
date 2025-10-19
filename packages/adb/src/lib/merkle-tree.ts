import * as crypto from 'crypto';
import { IStorage } from 'storage';
import { parse as parseUuid, stringify as stringifyUuid } from 'uuid';
import { save, load, ISerializer, IDeserializer } from 'serialization';
import { visualizeTreeSimple } from '../test/lib/merkle-tree/merkle-verify';

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
    size: number; // The size of the node and children in bytes.
    lastModified?: Date; // The last modified date of the original file (for leaf nodes only, version 3+).
    minFileName: string; // The minimum file name in this subtree (for efficient sorted insertion).
    left?: MerkleNode; // Left child node
    right?: MerkleNode; // Right child node
}

//
// The hash and other information about a file.
//
export interface IHashedFile {
    //
    // The sha256 hash of the file.
    //
    hash: Buffer;

    //
    // The length of the file in bytes.
    //
    length: number;

    //
    // The last modified date of the file.
    //
    lastModified: Date;
}

//
// Represents a hashed file to add to the Merkle tree.
//
export interface FileHash extends IHashedFile {
    fileName: string; // The file this hash represents. This is relative to the asset database directory.
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

//
// Compare two file names for sorting in the merkle tree.
// Returns negative if a < b, zero if equal, positive if a > b.
// Uses natural/numeric-aware sorting for intuitive ordering of numbered files.
//
export function compareFileNames(a: string, b: string): number {
    return a.localeCompare(b, undefined, { numeric: true });
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
            minFileName: node.left!.minFileName!,
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

    if (balance > 2) { 
        // Left-heavy tree (leftCount > rightCount + 1)
        // Allows the tree to be slightly left-heavy.
        // console.log(`! Tree is left-heavy, performing right rotation`);
        // console.log(visualizeTreeSimple(node));

        //
        //TODO: Can I just choose the simple case here?
        //

        //
        // Simple: Rotate the tree right.
        //
        // const rotated = rotateRight(node);
        // console.log(`== Right rotation performed`);
        // console.log(`After right rotation:`);
        // console.log(visualizeTreeSimple(rotated));
        // return rotated;

        //
        // More complex: Rotation cases.
        //
        const leftLeftCount = left.left?.nodeCount || 0;
        const leftRightCount = left.right?.nodeCount || 0;
        
        // Left-Left case: rotate right
        if (leftLeftCount >= leftRightCount) {
            const rotated = rotateRight(node);
            // console.log(`== Left-Left case, performed right rotation`);
            // console.log(`Before:`);
            // console.log(visualizeTreeSimple(node));
            // console.log(`After right rotation:`);
            // console.log(visualizeTreeSimple(rotated));
            return rotated;
        }
        // Left-Right case: rotate left then right
        else {
            const newLeft = rotateLeft(node.left!);
            // console.log(`== Left-Right case, performed left rotation then right rotation`);
            // console.log(`Before:`)
            // console.log(visualizeTreeSimple(node));
            // console.log(`Left side after left rotation:`);
            // console.log(visualizeTreeSimple(newLeft));
            const rotated = rotateRight({ ...node, left: newLeft });
            // console.log(`After right rotation:`);
            // console.log(visualizeTreeSimple(rotated));
            return rotated;
        }
    }
    else if (balance < 0) {
        // Right-heavy tree (rightCount > leftCount + 1)
        // We don't tollerate right heavy trees in the interest of producing 
        // equivalent trees regardless of the order of insertion.
        // console.log(`! Tree is right-heavy, performing left rotation`);
        // console.log(visualizeTreeSimple(node));

        //
        //TODO: Can I just choose the simple case here?
        //

        //
        // Simple: Rotate the tree left.
        //
        // const rotated = rotateLeft(node);
        // console.log(`== Left rotation performed`);
        // console.log(`After left rotation:`);
        // console.log(visualizeTreeSimple(rotated));
        // return rotated;

        //
        // More complex: Rotation cases.
        //
        const rightLeftCount = right.left?.nodeCount || 0;
        const rightRightCount = right.right?.nodeCount || 0;
        
        // Right-Right case: rotate left
        if (rightRightCount >= rightLeftCount) {
            const rotated = rotateLeft(node);
            // console.log(`== Right-Right case, performed left rotation`);
            // console.log(`Before:`);
            // console.log(visualizeTreeSimple(node));
            // console.log(`After left rotation:`);
            // console.log(visualizeTreeSimple(rotated));
            return rotated;
        }
        // Right-Left case: rotate right then left
        else {
            const newRight = rotateRight(right);
            // console.log(`== Right-Left case, performed right rotation then left rotation`);
            // console.log(`Before:`);
            // console.log(visualizeTreeSimple(node));
            // console.log(`Right side after right rotation:`);
            // console.log(visualizeTreeSimple(newRight));
            const rotated = rotateLeft({ ...node, right: newRight });
            // console.log(`After left rotation:`);
            // console.log(visualizeTreeSimple(rotated));
            return rotated;
        }
    }
    else {
        // If tree is reasonably balanced (difference <= 2), no rotation needed.
        // console.log(`Tree is reasonably balanced, no rotation needed`);
        // console.log(visualizeTreeSimple(node));
        return node;
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

//
// Migrates an odd node in the left subtree to the right subtree using a right rotation.
//
function migrateOddNode(node: MerkleNode): MerkleNode {
    if (node.nodeCount === 1) {
        return node;
    }

    if (!node.left || !node.right) {
        throw new Error('Invalid tree structure');
    }

    const left = node.left;
   
    const right = node.right;

    const leftMigrated = migrateOddNode(left);
    const rightMigrated = migrateOddNode(right);
    let thisNodeMigrated = node;
    if (leftMigrated !== left || rightMigrated !== right) {
        thisNodeMigrated = {
            ...node,
            left: leftMigrated,
            right: rightMigrated,
        };
        // console.log(`>> Migrated node`);
        // console.log(`Before:`);
        // console.log(visualizeTreeSimple(node));
        // console.log(`After:`);
        // console.log(visualizeTreeSimple(thisNodeMigrated));
    }   
    else {
        // console.log(`>> No migration needed for node`);
    }

    // If the left side has an odd leaf count, rotate right.
    if (thisNodeMigrated.left!.leafCount > 1 && thisNodeMigrated.left!.leafCount % 2 === 1) {
        thisNodeMigrated = rotateRight(thisNodeMigrated);

        // console.log(`>> Rotated node for migration`);
        // console.log(`Before:`);
        // console.log(visualizeTreeSimple(thisNodeMigrated));
        // console.log(`After:`);
        // console.log(visualizeTreeSimple(thisNodeMigrated));

        // Re-migrate the right side.
        thisNodeMigrated.right = migrateOddNode(rebalanceTree(thisNodeMigrated.right!));
    }
    else {
        // console.log(`>> No rotation needed for migration of node`);
    }

    thisNodeMigrated = rebalanceTree(thisNodeMigrated);

    return thisNodeMigrated;
}

/**
 * Add a file to the Merkle tree using binary tree structure (avoids recursion)
 */
function _addFile(node: MerkleNode | undefined, fileHash: FileHash): MerkleNode {
    const newLeaf = createLeafNode(fileHash);

    if (!node) {
        // If the tree is empty, return the new leaf as the root
        // console.log(`Adding file ${fileHash.fileName} to empty tree`);
        // console.log(visualizeTreeSimple(newLeaf));
        return newLeaf;
    }
    
    // If current node is a leaf, determine correct order and create parent
    if (node.nodeCount === 1) {
        if (compareFileNames(fileHash.fileName, node.fileName!) < 0) {
            const newNode = createParentNode(newLeaf, node); // new file goes left
            // console.log(`Added file ${fileHash.fileName} to left of ${node.fileName}`);
            // console.log(visualizeTreeSimple(newNode));
            return newNode;
        } else {
            const newNode = createParentNode(node, newLeaf); // new file goes right
            // console.log(`Added file ${fileHash.fileName} to right of ${node.fileName}`);
            // console.log(visualizeTreeSimple(newNode));
            return newNode;
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

    if (compareFileNames(fileHash.fileName, rightMin) < 0) {
        // File should go in left subtree based on sorting
        // console.log(`Added file ${fileHash.fileName} to left of ${rightMin}`);
        newLeft = _addFile(left, fileHash);
   } else {
        // File should go in right subtree based on sorting
        // console.log(`Added file ${fileHash.fileName} to right of ${rightMin}`);
        newRight = _addFile(right, fileHash);
    }
    
    // Create new node with updated children and recalculated properties
    const newLeftCount = newLeft.nodeCount;
    const newRightCount = newRight.nodeCount;
    const newLeftLeafCount = newLeft.leafCount;
    const newRightLeafCount = newRight.leafCount;
    const newLeftSize = newLeft.size;
    const newRightSize = newRight.size;
    
    const newNode: MerkleNode = {
        left: newLeft,
        right: newRight,
        nodeCount: 1 + newLeftCount + newRightCount,
        leafCount: newLeftLeafCount + newRightLeafCount,
        size: newLeftSize + newRightSize,
        minFileName: newLeft.minFileName,
        hash: combineHashes(newLeft.hash, newRight.hash),
    };
   
    return migrateOddNode(rebalanceTree(newNode));
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

    // console.log(`============ Adding file ${fileHash.fileName} to tree`);
    // console.log(visualizeTreeSimple(merkleTree?.root));
    
    //
    // Adds the new leaf node to the merkle tree.
    //
    root = _addFile(merkleTree?.root, fileHash);

    const numFiles = merkleTree ? merkleTree.metadata.totalFiles : 0;
   
    return {
        root,
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
    if (merkleTree && merkleTree.root) {
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
    
    // Use the centralized updateNodeInTree function to find and update the file
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
// Get file information from merkle tree (hash, size, lastModified)
// This replaces the need for database hash cache lookups
//
export function getFileInfo<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata>, fileName: string): { hash: Buffer, length: number, lastModified: Date } | undefined {
    // Use the centralized findFileInTree function
    const leafNode = findFileInTree(merkleTree.root, fileName);
    
    if (!leafNode) {
        return undefined;
    }

    if (!leafNode.lastModified) {
        throw new Error(`File ${fileName} is missing lastModified date. This could be a bug.`);
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
 * This function uses tree traversal to find a node by file name.
 * Returns the node if found, or undefined if not found.
 */
export function findFileNode<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata> | undefined, fileName: string): MerkleNode | undefined {
    if (!merkleTree || !merkleTree.root) {
        return undefined;
    }
    
    // Recursive binary search through the tree
    function searchNode(node: MerkleNode | undefined, targetFileName: string): MerkleNode | undefined {
        if (!node) {
            return undefined;
        }
        
        // If this is a leaf node, check if it matches
        if (node.nodeCount === 1) {
            return node.fileName === targetFileName ? node : undefined;
        }
        
        // Internal node - use binary search based on minFileName
        const left = node.left;
        const right = node.right;
        
        if (!left || !right) {
            throw new Error('Invalid tree structure: internal node missing children');
        }
        
        // If target is less than the minimum of right subtree, search left
        if (compareFileNames(targetFileName, right.minFileName) < 0) {
            return searchNode(left, targetFileName);
        } else {
            // Otherwise search right
            return searchNode(right, targetFileName);
        }
    }
    
    return searchNode(merkleTree.root, fileName);
}

/**
 * Visualize a Merkle tree in ASCII format
 * 
 * @param merkleTree The Merkle tree to visualize
 * @returns A string representation of the tree
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
            const detailPrefix = prefix + (isLast ? "    " : "│   ") + "    ";
            const leafHeader = `Leaf`;
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
 * - 4 bytes: Number of nodeRefs (uint32)
 * - For each nodeRef:
 *   - 4 bytes: fileNameLength (uint32)
 *   - X bytes: fileName
 *   - 4 bytes: fileIndex (uint32)
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
        
    }
    
}

//
// Rebuild a merkle tree in sorted order and removes a path.
//
export function rebuildTree<DatabaseMetadata>(tree: IMerkleTree<DatabaseMetadata>, pathRemove?: string): IMerkleTree<DatabaseMetadata> {

    const files: FileHash[] = [];

    traverseTreeSync(tree.root, (node) => {
        if (node.nodeCount === 1 && node.fileName && node.lastModified) {
            if (pathRemove) {
                if (node.fileName.startsWith(pathRemove)) {
                    // Don't add this file to the new tree.
                    return true;
                }
            }

            files.push({
                fileName: node.fileName,
                hash: node.hash,
                length: node.size,
                lastModified: node.lastModified
            });
        }
        return true;
    });

    //
    // Sort by file name.
    //
    // TODO: In theory this sorting step shouldn't be required because addFile should
    // put the file in sorted order in the tree. But something isn't quite write when
    // trying to replicate a rebuilt tree.
    //
    files.sort((a, b) => compareFileNames(a.fileName, b.fileName));

    //
    // Add all files in sorted order to a new tree.
    //
    let rebuiltTree = createTree<DatabaseMetadata>(tree.metadata.id);
    rebuiltTree.databaseMetadata = tree.databaseMetadata;
    for (const file of files) {
        // console.log(`Adding file: ${file.fileName}`);
        rebuiltTree = addFile(rebuiltTree, file);
    }


    return rebuiltTree;
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
        
        // Create node
        nodes.push({
            hash,
            fileName,
            nodeCount,
            leafCount,
            size,
            lastModified
        });
    }
    
    return {
        root: arrayToBinaryTree(nodes),
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
        
        deserializer.readUInt8(); // Discard isDeleted flag.
        
        // Create node
        nodes.push({
            hash,
            fileName,
            nodeCount,
            leafCount,
            size,
            lastModified
        });
    }
    
    return {
        root: arrayToBinaryTree(nodes),
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
        
        deserializer.readUInt8(); // Discard isDeleted flag.
        
        // Create node
        nodes.push({
            hash,
            fileName,
            nodeCount,
            leafCount,
            size,
            lastModified
        });
    }
    
    return {
        root: arrayToBinaryTree(nodes),
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
 * Delete a file node from the Merkle tree, actually removing it from the tree structure
 * This function properly removes the node and rebalances the tree
 * 
 * @param merkleTree The Merkle tree containing the file
 * @param fileName The name of the file to delete
 * @returns true if the file was found and deleted, false otherwise
 */
export function deleteFile<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    fileName: string
): boolean {
    if (!merkleTree || !merkleTree.root) {
        return false;
    }
    
    // Check if the file exists
    const existingNode = findFileInTree(merkleTree.root, fileName);
    if (!existingNode) {
        return false;
    }
    
    // If this is the only node in the tree, clear the tree
    if (merkleTree.root.nodeCount === 1) {
        merkleTree.root = undefined;
        merkleTree.metadata = {
            ...merkleTree.metadata,
            totalFiles: 0,
            totalNodes: 0,
            totalSize: 0
        };
        return true;
    }
    
    // Remove the node from the tree
    const newRoot = _deleteNode(merkleTree.root, fileName);
    if (!newRoot) {
        return false; // Node not found
    }
    
    // Update the tree
    merkleTree.root = newRoot;
    
    // Update metadata
    merkleTree.metadata = updateMetadata(
        merkleTree.metadata,
        merkleTree.root.nodeCount,
        merkleTree.metadata.totalFiles - 1, // Decrease file count
        merkleTree.root.size
    );
    
    return true;
}

/**
 * Internal function to delete a node from the tree and return the new root
 * This handles the complex logic of removing a node while maintaining tree structure
 */
function _deleteNode(node: MerkleNode, fileName: string): MerkleNode | undefined {
    // If this is a leaf node, check if it's the target
    if (node.nodeCount === 1) {
        if (node.fileName === fileName) {
            return undefined; // Signal to parent that this node should be removed
        }
        return node; // Not the target, return unchanged
    }
    
    const left = node.left;
    const right = node.right;
    if (!left || !right) {
        throw new Error('Invalid tree structure');
    }
    
    let newLeft = left;
    let newRight = right;
    let nodeDeleted = false;
    
    // Check if the target is in the left subtree
    if (compareFileNames(fileName, right.minFileName) < 0) {
        const result = _deleteNode(left, fileName);
        if (result === undefined) {
            // The left child was deleted, promote the right child
            return right;
        }
        newLeft = result;
        nodeDeleted = true;
    } else {
        // Check if the target is in the right subtree
        const result = _deleteNode(right, fileName);
        if (result === undefined) {
            // The right child was deleted, promote the left child
            return left;
        }
        newRight = result;
        nodeDeleted = true;
    }
    
    if (!nodeDeleted) {
        return node; // Node not found
    }
    
    // Create new node with updated children and recalculated properties
    const newNode = {
        ...node,
        left: newLeft,
        right: newRight,
        nodeCount: 1 + newLeft.nodeCount + newRight.nodeCount,
        leafCount: newLeft.leafCount + newRight.leafCount,
        size: newLeft.size + newRight.size,
        minFileName: newLeft.minFileName,
        hash: combineHashes(newLeft.hash, newRight.hash),
    };
    
    // Rebalance the tree after deletion
    return rebalanceTree(newNode);
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
    if (!merkleTree || !merkleTree.root) {
        throw new Error("Cannot delete files from empty or invalid merkle tree");
    }
    
    if (fileNames.length === 0) {
        throw new Error("Cannot delete files: no file names provided");
    }
    
    // Create a set for efficient lookup
    const filesToDelete = new Set(fileNames);
    
    // Get all files from the tree using traversal
    const allFiles: FileHash[] = [];
    const existingFiles = new Set<string>();
    
    traverseTreeSync(merkleTree.root, (node) => {
        if (node.nodeCount === 1 && node.fileName) {
            existingFiles.add(node.fileName);
            if (node.lastModified) {
                allFiles.push({
                    fileName: node.fileName,
                    hash: node.hash,
                    length: node.size,
                    lastModified: node.lastModified
                });
            }
        }
        return true;
    });
    
    // Check if any files don't exist
    const nonExistentFiles = fileNames.filter(fileName => !existingFiles.has(fileName));
    if (nonExistentFiles.length > 0) {
        throw new Error(`Cannot delete files: the following files do not exist: ${nonExistentFiles.join(', ')}`);
    }
    
    let filesRemoved = 0;
    
    // Get all remaining files (excluding the ones to delete)
    const remainingFiles: FileHash[] = [];
    
    for (const file of allFiles) {
        if (filesToDelete.has(file.fileName)) {
            filesRemoved++;
        } else {
            remainingFiles.push(file);
        }
    }
    
    // If no files remain, create an empty tree
    if (remainingFiles.length === 0) {
        merkleTree.root = undefined;
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
    merkleTree.metadata = newTree.metadata;
    
    return filesRemoved;
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
    // Get all files from both trees
    const filesInA = new Map<string, { hash: string }>();
    const filesInB = new Map<string, { hash: string }>();
    
    let processedFiles = 0;
    
    // Process files in tree A using traversal
    if (treeA.root) {
        traverseTreeSync(treeA.root, (node) => {
            if (node.nodeCount === 1 && node.fileName) {
                processedFiles++;
                if (progressCallback && processedFiles % 1000 === 0) {
                    progressCallback(`Indexing sources files | ${processedFiles} files`);
                }
                
                filesInA.set(node.fileName, { 
                    hash: node.hash.toString('hex')
                });
            }
            return true;
        });
    }
    
    // Process files in tree B using traversal
    if (treeB.root) {
        traverseTreeSync(treeB.root, (node) => {
            if (node.nodeCount === 1 && node.fileName) {
                processedFiles++;
                if (progressCallback && processedFiles % 1000 === 0) {
                    progressCallback(`Indexing dest files | ${processedFiles} files`);
                }
                
                filesInB.set(node.fileName, { 
                    hash: node.hash.toString('hex')
                });
            }
            return true;
        });
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
        
        const fileInfoB = filesInB.get(fileName);
        if (!fileInfoB) {
            // File exists in A but not in B
            onlyInA.push(fileName);
        } else if (fileInfoA.hash !== fileInfoB.hash) {
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
        
        const fileInfoA = filesInA.get(fileName);
        if (!fileInfoA) {
            // File exists in B but not in A
            onlyInB.push(fileName);
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
