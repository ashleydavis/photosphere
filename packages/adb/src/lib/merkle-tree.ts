import * as crypto from 'crypto';
import { BSON } from 'bson';
import { IStorage } from 'storage';
import { parse as parseUuid, stringify as stringifyUuid } from 'uuid';
import { ITimestampProvider, IUuidGenerator } from 'utils';

//
// Current database version
//
export const CURRENT_DATABASE_VERSION = 3;

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
    
    // Creation timestamp (in milliseconds since epoch)
    createdAt: number;
    
    // Last modified timestamp (in milliseconds since epoch)
    modifiedAt: number;
}

//
// Represents the merkle tree itself.
//
export interface IMerkleTree<DatabaseMetadata> {
    // 
    // The flattend array of nodes in the tree.
    // The root node is always the first node in the array.
    // 
    nodes: MerkleNode[];

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
// Count the number of '1' bits in the binary representation of fileHashIndex.
//
// According to Claude this has an O notation of O(log numLeafNodes). So it grows slowly as the number of leaf nodes increases.
//
const countBits = (n: number): number => {
    let count = 0;
    while (n > 0) { 
        count += n & 1; 
        n >>= 1;
    }
    return count;
};

/**
 * Converts a file index to a node index in a balanced merkle tree
 * that has been flattened using depth-first traversal
 * 
 * @param fileIndex The index of the file (0-based)
 * @param totalLeafNodes The total number of leaf nodes in the tree
 * @return The index of the node in the flattened array
 */
function getLeafNodeIndex_balanced(fileIndex: number, totalLeafNodes: number): number {
    // Calculate the height of the tree
    const height = Math.ceil(Math.log2(totalLeafNodes));

    // Calculate the offset based on tree height and bit count
    const offset = height - countBits(fileIndex);

    // The formula: 2 * fileIndex + offset
    return 2 * fileIndex + offset;
}

//
// Get the left and right node indices for a given node index in a flattened tree.
//
export function getChildren(nodeIndex: number, nodes: MerkleNode[]) {
    const leftIndex = nodeIndex + 1;
    const leftNode = nodes[leftIndex];
    const leftCount = leftNode.nodeCount;
    const rightIndex = leftIndex + leftCount;
    const rightNode = nodes[rightIndex];
    const rightCount = rightNode.nodeCount;
    return { leftIndex, leftNode, rightIndex, rightNode, leftCount, rightCount, };
}

//
// Gets the node index of a leaf node from its file index in a flattened Merkle tree.
//
export function getLeafNodeIndex(fileHashIndex: number, nodeIndex: number, nodes: MerkleNode[]): number {
    const node = nodes[nodeIndex];
    // console.log(`have file index ${fileHashIndex}, visiting node ${nodeIndex} ${node.fileName || ''} with ${node.leafCount} leafs`);
    if (node.leafCount === 1) {
        // The tree only has one leaf node, so return its index.
        // console.log(`found leaf node ${nodeIndex} with file index ${fileHashIndex}`); //fio:
        return nodeIndex + fileHashIndex;
    }

    const { leftNode, leftCount, rightIndex, rightCount } = getChildren(nodeIndex, nodes);
    if (leftCount === rightCount) { // Check if this tree is balanced.
        // console.log(`node is balanced`); //fio:
        // console.log(`result = ${nodeIndex} + 1 + ${getLeafNodeIndex_balanced(fileHashIndex, node.leafCount)}`); //fio:
        //
        // It is balanced, so use the simple formula.
        //
        return nodeIndex + getLeafNodeIndex_balanced(fileHashIndex, node.leafCount); // No +1 in this case, including the parent node in this calculation.
    }

    if (fileHashIndex < leftNode.leafCount) {
        // console.log(`unbalanced, file is in left subtree using simple formula`); //fio:
        // console.log(`result = ${nodeIndex} + 1 + ${getLeafNodeIndex_balanced(fileHashIndex, leftNode.leafCount)}`); //fio;
        //
        // The file is in the left subtree, which by definition is always balanced so we can use the simple formula.
        //
        return nodeIndex + 1 // +1 to skip the parent node.
            + getLeafNodeIndex_balanced(fileHashIndex, leftNode.leafCount); 
    }

    // console.log(`unbalanced, file is in right subtree`); //fio:
    // console.log(`result = ${nodeIndex} + 1 + ${getLeafNodeIndex(fileHashIndex - leftNode.leafCount, rightIndex, nodes)}`); //fio:

    //
    // The file is in the right subtree, which is not balanced so recurse and search.
    //
    return getLeafNodeIndex(fileHashIndex - leftNode.leafCount, rightIndex, nodes); 
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
    };
}

/**
 * Add a file to the Merkle tree, efficiently creating a balanced structure
 * without rebuilding the entire tree
 */
function _addFile(nodeIndex: number, nodes: MerkleNode[], fileHash: FileHash): MerkleNode[] {
    // Create a new leaf node for the file
    const newLeaf = createLeafNode(fileHash);

    if (nodes.length === 0) {
        // If the tree is empty, return the new leaf as the root.
        return [ newLeaf ];
    }
    
    // If current root is a leaf node, create a simple pair
    if (nodes[nodeIndex].nodeCount === 1) {
        const newRoot = createParentNode(nodes[nodeIndex], newLeaf);
        return [newRoot, ...nodes, newLeaf];
    }

    const { leftIndex, leftNode, leftCount, rightIndex, rightCount } = getChildren(nodeIndex, nodes);
    if (leftCount > rightCount) {
        // Left subtree has more nodes, add to right subtree to balance.
        const rightSubtree = nodes.slice(rightIndex);
        const newRightSubtree = _addFile(0, rightSubtree, fileHash);
        
        const leftSubtree = nodes.slice(leftIndex, rightIndex);
        const newRoot = createParentNode(leftNode, newRightSubtree[0]);
        return [newRoot, ...leftSubtree, ...newRightSubtree];
    } 
    else {
        // Right subtree has equal or more nodes.
        // Create new root with current tree on left and new leaf on right.
        const newRoot = createParentNode(nodes[nodeIndex], newLeaf);
        return [newRoot, ...nodes, newLeaf];
   }
}

/**
 * Create default metadata for a new tree
 */
export function createDefaultMetadata(timestampProvider: ITimestampProvider, uuidGenerator: IUuidGenerator): TreeMetadata {
    const now = timestampProvider.now();
    const id = uuidGenerator.generate();
    return {
        id,
        totalNodes: 0,
        totalFiles: 0,
        totalSize: 0,
        createdAt: now,
        modifiedAt: now
    };
}

/**
 * Update metadata when tree is modified
 */
export function updateMetadata(
    metadata: TreeMetadata, 
    totalNodes: number, 
    totalFiles: number, 
    totalSize: number,
    timestampProvider: ITimestampProvider
): TreeMetadata {
    return {
        ...metadata,
        totalNodes,
        totalFiles,
        totalSize,
        modifiedAt: timestampProvider.now(),
    };
}

//
// Create a new empty Merkle tree.
//
export function createTree<DatabaseMetadata>(timestampProvider: ITimestampProvider,uuidGenerator: IUuidGenerator): IMerkleTree<DatabaseMetadata> {
    return {
        nodes: [],
        sortedNodeRefs: [],
        metadata: createDefaultMetadata(timestampProvider, uuidGenerator),
        version: CURRENT_DATABASE_VERSION,
    };
}

/**
 * Add a file to the Merkle tree, efficiently creating a balanced structure
 * without rebuilding the entire tree
 */
export function addFile<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    fileHash: FileHash,
    timestampProvider: ITimestampProvider,
    uuidGenerator: IUuidGenerator
): IMerkleTree<DatabaseMetadata> {

    let nodes: MerkleNode[];
    let metadata = merkleTree?.metadata || createDefaultMetadata(timestampProvider, uuidGenerator);
    
    //
    // Adds the new leaf node to the merkle tree.
    //
    if (!merkleTree) {
        // Create a new tree if it doesn't exist
        nodes = _addFile(0, [], fileHash);
    } else {
        // Add the file to the existing tree
        nodes = _addFile(0, merkleTree.nodes, fileHash);
    }

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
        nodes,
        sortedNodeRefs,
        metadata: updateMetadata(metadata, nodes.length, numFiles + 1, nodes[0].size, timestampProvider),
        version: merkleTree?.version || CURRENT_DATABASE_VERSION,
        databaseMetadata: merkleTree?.databaseMetadata,
    };
}

/**
 * Find the parent index of a node in the Merkle tree - optimized version
 * 
 * This function leverages the depth-first traversal structure of the flattened array
 * to find the parent efficiently.
 * 
 * Time Complexity:
 * - Best case: O(1) for left children (direct lookup)
 * - Average case: O(log n) for right children in a balanced tree 
 * - Worst case: O(log n) with early termination optimization
 * 
 * Space Complexity: O(1) - uses constant extra space
 * 
 * The improvement over the original implementation (which was O(n)) comes from:
 * 1. Instant identification of left child parents
 * 2. Optimized backwards traversal for right children
 * 3. Early termination when we can determine no parent exists in earlier positions
 * 
 * @param nodeIndex The index of the node
 * @param nodes The array of nodes
 * @returns The index of the parent node, or -1 if the node is the root or not found
 */
export function findParentIndex(nodeIndex: number, nodes: MerkleNode[]): number {
    // Root node has no parent
    if (nodeIndex === 0 || nodeIndex >= nodes.length) {
        return -1;
    }
    
    // Case 1: Left child
    // A left child is always at index parent+1, so we check if the previous node could be our parent
    const potentialParentIndex = nodeIndex - 1;
    if (potentialParentIndex >= 0) {
        // Double-check that it's an internal node (non-leaf)
        if (nodes[potentialParentIndex].nodeCount > 1) {
            return potentialParentIndex;
        }
    }
    
    // Case 2: Right child
    // If we're a right child, we need to work backwards to find the parent
    // The parent will be the closest node before us that has a right child pointing to our position
    
    // Start from the node just before us and work backwards
    for (let i = nodeIndex - 1; i >= 0; i--) {
        const node = nodes[i];
        
        // Skip leaf nodes as they can't be parents
        if (node.nodeCount === 1) {
            continue;
        }
        
        const { rightIndex } = getChildren(i, nodes);
        if (rightIndex === nodeIndex) {
            // If this node's right child is us, we found the parent
            return i;
        }
        
        // Optimization: If we encounter a node whose right child is beyond our position,
        // we can skip checking any nodes before it
        if (rightIndex > nodeIndex) {
            break;
        }
    }
    
    return -1; // Not found (should never happen in a valid tree)
}

/**
 * Calculate the path from a node to the root of the tree
 * 
 * This function builds a path from a given node to the root by repeatedly
 * finding the parent of each node until reaching the root.
 * 
 * Time Complexity:
 * - O(log² n) for a balanced tree, where n is the number of nodes
 *   - We make O(log n) calls to findParentIndex (tree height)
 *   - Each call to findParentIndex is O(log n) in the worst case
 *   - This is a significant improvement over the previous O(n × log n) implementation
 * 
 * Space Complexity:
 * - O(log n) for storing the path in a balanced tree
 *   - The path length equals the height of the tree, which is O(log n) for a balanced tree
 *   - We use an additional reversePath array, but this is also O(log n)
 * 
 * For large trees, this optimized implementation can be thousands of times faster
 * than the original approach.
 * 
 * @param nodeIndex The index of the node
 * @param nodes The array of nodes
 * @returns An array of indices representing the path from the root to the node (root first)
 */
function calculatePathToRoot(nodeIndex: number, nodes: MerkleNode[]): number[] {
    const path: number[] = [];
    if (nodeIndex >= nodes.length) {
        return path;
    }
    
    // Start with the current node
    let currentIndex = nodeIndex;
    
    // Build the path from node to root (in reverse order initially)
    const reversePath: number[] = [currentIndex];
    
    // Work backwards to the root, building the path
    while (currentIndex > 0) {
        const parentIndex = findParentIndex(currentIndex, nodes);
        if (parentIndex === -1) {
            break; // No parent found (should only happen for root)
        }
        
        reversePath.push(parentIndex); // Add parent to the path
        currentIndex = parentIndex;
    }
    
    // Reverse the path to get root-first order
    for (let i = reversePath.length - 1; i >= 0; i--) {
        path.push(reversePath[i]);
    }
    
    return path;
}

//
// Upsert a file in the Merkle tree, either adding it or updating it if it already exists.
// Updates the tree in place.
//
export function upsertFile<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    fileHash: FileHash,
    timestampProvider: ITimestampProvider,
    uuidGenerator: IUuidGenerator
): IMerkleTree<DatabaseMetadata> {
    if (merkleTree && merkleTree.sortedNodeRefs.length > 0) {
        if (updateFile(merkleTree, fileHash, timestampProvider)) {
            // File updated successfully in place.
            return merkleTree;
        }
    }

    return addFile(merkleTree, fileHash, timestampProvider, uuidGenerator);
}

/**
 * Update a file in the Merkle tree with new content, maintaining the same tree structure.
 */
export function updateFile<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata> | undefined, 
    fileHash: FileHash, 
    timestampProvider: ITimestampProvider
): boolean {
    if (!merkleTree || merkleTree.nodes.length === 0) {
        throw new Error(`Tree is empty, cannot update file '${fileHash.fileName}'`);
    }
    
    // Find the node to update using binary search
    const nodeRef = findNodeRef(merkleTree, fileHash.fileName);
    if (!nodeRef) {
        // File not found in the tree
        return false;
    }
    
    const nodeIndex = getLeafNodeIndex(nodeRef.fileIndex, 0, merkleTree.nodes);
    const node = merkleTree.nodes[nodeIndex];
    
    // Update the leaf node's hash
    node.hash = fileHash.hash;
    node.size = fileHash.length; // Update the size of the node.
    
    // Calculate the path from the root to the updated node (root first)
    const pathToRoot = calculatePathToRoot(nodeIndex, merkleTree.nodes);
    
    // Skip the leaf node (last in path) and update all parents from bottom to top
    // We process the path in reverse (bottom-up) order, skipping the leaf node
    for (let i = pathToRoot.length - 2; i >= 0; i--) {
        const parentIndex = pathToRoot[i];
        const parent = merkleTree.nodes[parentIndex];
        
        const { leftNode, rightNode } = getChildren(parentIndex, merkleTree.nodes);        
        parent.hash = combineHashes(leftNode.hash, rightNode.hash); // Recalculate the parent's hash.
        parent.size = leftNode.size + rightNode.size; // Update the size of the parent node.
    }
    
    // Update metadata if it exists
    merkleTree.metadata = updateMetadata(
        merkleTree.metadata, 
        merkleTree.nodes.length, 
        merkleTree.metadata.totalFiles,
        merkleTree.nodes[0].size,
        timestampProvider
    );
    
    return true;
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

    // Find the actual leaf node using the fileIndex
    const leafNode = merkleTree.nodes.find(node => 
        node.fileName === fileName && node.nodeCount === 1
    );

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
    if (!merkleTree || merkleTree.nodes.length === 0) {
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
        result += `  Created: ${new Date(merkleTree.metadata.createdAt).toISOString()}\n`;
        result += `  Last Modified: ${new Date(merkleTree.metadata.modifiedAt).toISOString()}\n`;
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
    
    // Helper function to recursively build the ASCII tree
    function buildTreeString(nodeIndex: number, prefix: string, isLast: boolean): string {
        const node = merkleTree.nodes[nodeIndex];
        
        // Determine the branch character
        const branchChar = isLast ? "└── " : "├── ";
        const nodeStr = prefix + branchChar;
        
        let treeStr = "";

        const hashStr = node.hash.toString('hex');
        const hashPreview = `${hashStr.slice(0, 4)}-${hashStr.slice(-4)}`;
        
        // Add the node information
        if (node.nodeCount === 1) {
            // Leaf node
            const deletedStatus = node.isDeleted ? " [DELETED]" : "";
            const detailPrefix = prefix + (isLast ? "    " : "│   ") + "    ";
            const leafHeader = `Leaf[${nodeIndex}]${deletedStatus}`;
            const paddedLeafHeader = leafHeader.padEnd(13);
            // Add spacing line that preserves tree structure - always use vertical line for continuity
            const spacingPrefix = prefix + "│   ";
            treeStr += `${spacingPrefix}\n${nodeStr}${paddedLeafHeader} ${hashPreview}\n`;
            
            // Add full hash and file details indented underneath
            treeStr += `${detailPrefix}Full:     ${hashStr}\n`;
            treeStr += `${detailPrefix}File:     ${node.fileName}\n`;
            if (node.size) {
                treeStr += `${detailPrefix}Size:     ${node.size} bytes\n`;
            }
            if (node.lastModified) {
                treeStr += `${detailPrefix}Modified: ${node.lastModified.toISOString()}\n`;
            }
        } else {
            // Internal node
            const detailPrefix = prefix + (isLast ? "    " : "│   ") + "│   ";
            const nodeHeader = `Node[${nodeIndex}]`;
            const paddedNodeHeader = nodeHeader.padEnd(11);
            // Add spacing line that preserves tree structure - always use vertical line for continuity
            const spacingPrefix = prefix + "│   ";
            treeStr += `${spacingPrefix}\n${nodeStr}${paddedNodeHeader} ${hashPreview}\n`;
            
            // Add full hash and node details indented underneath
            treeStr += `${detailPrefix}Full:   ${hashStr}\n`;
            treeStr += `${detailPrefix}Count:  ${node.nodeCount} nodes\n`;
            treeStr += `${detailPrefix}Leaves: ${node.leafCount} files\n`;
            treeStr += `${detailPrefix}Size:   ${node.size} bytes\n`;

            const { leftIndex, rightIndex } = getChildren(nodeIndex, merkleTree.nodes);
            
            // Prepare prefix for children
            const childPrefix = prefix + (isLast ? "    " : "│   ");
            
            // Add left child
            treeStr += buildTreeString(leftIndex, childPrefix, false);
            
            // Add right child
            treeStr += buildTreeString(rightIndex, childPrefix, true);
        }
        
        return treeStr;
    }
    
    // Start building the tree from the root (index 0)
    result += buildTreeString(0, "", true);
    
    // Add sorted node references
    result += "\nSorted Node References:\n";
    if (merkleTree.sortedNodeRefs.length === 0) {
        result += "  (None)\n";
    } else {
        const maxDisplay = 50;
        merkleTree.sortedNodeRefs.slice(0, maxDisplay).forEach((nodeRef, index) => {
            const nodeIndex = getLeafNodeIndex(nodeRef.fileIndex, 0, merkleTree.nodes);
            const node = merkleTree.nodes[nodeIndex];
            const hashStr = node.hash.toString('hex');
            const hashPreview = `${hashStr.slice(0, 4)}-${hashStr.slice(-4)}`;
            const deletedStatus = nodeRef.isDeleted ? " [DELETED]" : "";
            result += `  ${index + 1}. ${nodeRef.fileName}${deletedStatus} -> File[${nodeRef.fileIndex}] Node[${nodeIndex}] ${hashPreview}\n`;
        });
        if (merkleTree.sortedNodeRefs.length > maxDisplay) {
            result += `  ... and ${merkleTree.sortedNodeRefs.length - maxDisplay} more\n`;
        }
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
export async function saveTree<DatabaseMetadata>(filePath: string, tree: IMerkleTree<DatabaseMetadata>, storage: IStorage): Promise<void> {
    // Calculate total buffer size needed
    let totalSize = 4; // 4 bytes version

    // Add database metadata BSON size (always present in version 3+)
    const databaseMetadataBson = Buffer.from(BSON.serialize(tree.databaseMetadata as any));
    totalSize += 4; // 4 bytes for BSON length
    totalSize += databaseMetadataBson.length; // BSON data

    // Add tree metadata size.
    // 16 bytes UUID + 4 bytes totalNodes + 4 bytes totalFiles + 8 bytes totalSize + 8 bytes createdAt + 8 bytes modifiedAt
    totalSize += 16 + 4 + 4 + 8 + 8 + 8;
    
    // Calculate size needed for all nodes
    for (const node of tree.nodes) {
        // Base size: 32 bytes hash + 4 bytes nodeCount + 4 bytes leafCount + 8 bytes size + 4 bytes fileNameLength + 1 byte isDeleted
        totalSize += 32 + 4 + 4 + 8 + 4 + 1;
        
        // Version 3+ adds file metadata for leaf nodes: 8 bytes lastModified timestamp
        if (node.fileName) { // This is a leaf node
            totalSize += 8; // lastModified
        }
        
        // Add fileName size if present
        if (node.fileName) {
            totalSize += Buffer.byteLength(node.fileName, 'utf8');
        }
    }
    
    // Add space for nodeRefs count
    totalSize += 4;
    
    // Calculate size needed for all nodeRefs
    for (const nodeRef of tree.sortedNodeRefs) {
        const fileNameLength = Buffer.byteLength(nodeRef.fileName, 'utf8');
        // 4 bytes fileNameLength + X bytes fileName + 4 bytes fileIndex + 1 byte isDeleted
        totalSize += 4 + fileNameLength + 4 + 1;
    }
    
    // Create buffer for the entire tree
    const buffer = Buffer.alloc(totalSize);
    let offset = 0;
    
    // Write format version (always use current version when saving)
    buffer.writeUInt32LE(CURRENT_DATABASE_VERSION, offset);
    offset += 4;

    // Write database metadata BSON (always present in version 3+)
    buffer.writeUInt32LE(databaseMetadataBson.length, offset);
    offset += 4;
    databaseMetadataBson.copy(buffer, offset);
    offset += databaseMetadataBson.length;
        
    // Write tree metadata.
    // Write UUID
    const idBuffer = Buffer.from(parseUuid(tree.metadata.id));
    if (idBuffer.length !== 16) {
        throw new Error(`Invalid UUID length: ${idBuffer.length}`);
    }
    idBuffer.copy(buffer, offset);
    offset += 16;
    
    // Write totalNodes
    buffer.writeUInt32LE(tree.metadata.totalNodes, offset);
    offset += 4;
    
    // Write totalFiles
    buffer.writeUInt32LE(tree.metadata.totalFiles, offset);
    offset += 4;

    // Write totalSize
    const splitTotalSize = splitBigNum(BigInt(tree.metadata.totalSize));
    buffer.writeUInt32LE(splitTotalSize.low, offset);
    buffer.writeUInt32LE(splitTotalSize.high, offset + 4);
    offset += 8;
    
    // Write creation timestamp
    // Split into two 32-bit values since Node.js Buffer doesn't have writeUInt64LE
    const splitCreatedAt = splitBigNum(BigInt(tree.metadata.createdAt));
    buffer.writeUInt32LE(splitCreatedAt.low, offset);
    offset += 4;
    buffer.writeUInt32LE(splitCreatedAt.high, offset);
    offset += 4;
    
    // Write modification timestamp
    const splitModifiedAt = splitBigNum(BigInt(tree.metadata.modifiedAt));
    buffer.writeUInt32LE(splitModifiedAt.low, offset);
    offset += 4;
    buffer.writeUInt32LE(splitModifiedAt.high, offset);
    offset += 4;
    
    // Write all nodes
    for (const node of tree.nodes) {
        // Write hash
        node.hash.copy(buffer, offset);
        offset += 32;
        
        // Write nodeCount
        buffer.writeUInt32LE(node.nodeCount, offset);
        offset += 4;
        
        // Write leafCount
        buffer.writeUInt32LE(node.leafCount, offset);
        offset += 4;

        // Write tree size
        const splitSize = splitBigNum(BigInt(node.size));
        buffer.writeUInt32LE(splitSize.low, offset);
        buffer.writeUInt32LE(splitSize.high, offset + 4);
        offset += 8;
        
        // Write fileName if present
        if (node.fileName) {
            const fileNameLength = Buffer.byteLength(node.fileName, 'utf8');
            buffer.writeUInt32LE(fileNameLength, offset);
            offset += 4;
            buffer.write(node.fileName, offset, 'utf8');
            offset += fileNameLength;
            
            // Write file metadata for leaf nodes in version 3+
            // Write lastModified timestamp (8 bytes)
            const lastModified = node.lastModified ? node.lastModified.getTime() : 0;
            const splitLastModified = splitBigNum(BigInt(lastModified));
            buffer.writeUInt32LE(splitLastModified.low, offset);
            buffer.writeUInt32LE(splitLastModified.high, offset + 4);
            offset += 8;
        } else {
            // No fileName
            buffer.writeUInt32LE(0, offset);
            offset += 4;
        }
        
        // Write isDeleted flag
        buffer.writeUInt8(node.isDeleted ? 1 : 0, offset);
        offset += 1;
    }
    
    // Write nodeRefs count
    buffer.writeUInt32LE(tree.sortedNodeRefs.length, offset);
    offset += 4;
    
    // Write all nodeRefs
    for (const nodeRef of tree.sortedNodeRefs) {
        // Write fileName
        const fileNameLength = Buffer.byteLength(nodeRef.fileName, 'utf8');
        buffer.writeUInt32LE(fileNameLength, offset);
        offset += 4;
        buffer.write(nodeRef.fileName, offset, 'utf8');
        offset += fileNameLength;
        
        // Write fileIndex
        buffer.writeUInt32LE(nodeRef.fileIndex, offset);
        offset += 4;
        
        // Write isDeleted flag
        buffer.writeUInt8(nodeRef.isDeleted ? 1 : 0, offset);
        offset += 1;
    }
    
    // Write the buffer to file
    await storage.write(filePath, undefined, buffer);
}

/**
 * Load a Merkle tree from a file.
 */
export async function loadTree<DatabaseMetadata>(filePath: string, storage: IStorage): Promise<IMerkleTree<DatabaseMetadata> | undefined> {
    const treeData = await storage.read(filePath);
    if (!treeData) {
        return undefined;
    }
    
    const version = treeData.readUInt32LE(0); // Read the version number
    let offset = 4; // Start after version.
    
    // Read database metadata BSON for version 3+
    let databaseMetadata: DatabaseMetadata | undefined;
    if (version >= 3) {
        const bsonLength = treeData.readUInt32LE(offset);
        offset += 4;
        const bsonData = treeData.slice(offset, offset + bsonLength);
        databaseMetadata = BSON.deserialize(bsonData) as DatabaseMetadata;
        offset += bsonLength;
    }
    
    // Read tree metadata fields
    const uuid = stringifyUuid(treeData.slice(offset, offset + 16));
    offset += 16;
    
    const totalNodes = treeData.readUInt32LE(offset);
    offset += 4;
    
    const totalFiles = treeData.readUInt32LE(offset);
    offset += 4;
    
    const low = treeData.readUInt32LE(offset);
    const high = treeData.readUInt32LE(offset + 4);
    const totalSize = Number(combineBigNum({ low, high }));
    offset += 8;
    
    // Read created timestamp (64-bit value split into two 32-bit values)
    const createdLow = treeData.readUInt32LE(offset);
    const createdHigh = treeData.readUInt32LE(offset + 4);
    const createdAt = Number(combineBigNum({ low: createdLow, high: createdHigh }));
    offset += 8;
    
    // Read modified timestamp (64-bit value split into two 32-bit values)
    const modifiedLow = treeData.readUInt32LE(offset);
    const modifiedHigh = treeData.readUInt32LE(offset + 4);
    const modifiedAt = Number(combineBigNum({ low: modifiedLow, high: modifiedHigh }));
    offset += 8;
    
    // Create metadata object
    const metadata: TreeMetadata = {
        id: uuid,
        totalNodes,
        totalFiles,
        totalSize,
        createdAt,
        modifiedAt
    };
    
    // Read all nodes
    const nodes: MerkleNode[] = [];
    
    for (let i = 0; i < totalNodes; i++) {
        // Read hash
        const hash = Buffer.from(treeData.slice(offset, offset + 32));
        offset += 32;
        
        // Read nodeCount
        const nodeCount = treeData.readUInt32LE(offset);
        offset += 4;
        
        // Read leafCount
        const leafCount = treeData.readUInt32LE(offset);
        offset += 4;

        // Read tree size.
        const low = treeData.readUInt32LE(offset);
        const high = treeData.readUInt32LE(offset + 4);
        const size = Number(combineBigNum({ low, high }));
        offset += 8;

        // Read fileName if present
        const fileNameLength = treeData.readUInt32LE(offset);
        offset += 4;
        
        let fileName: string | undefined;
        let lastModified: Date | undefined;
        
        if (fileNameLength > 0) {
            fileName = treeData.slice(offset, offset + fileNameLength).toString('utf8');
            offset += fileNameLength;
            
            // Read file metadata for leaf nodes in version 3+
            if (version >= 3) {
                // Read lastModified timestamp (8 bytes)
                const lastModifiedLow = treeData.readUInt32LE(offset);
                const lastModifiedHigh = treeData.readUInt32LE(offset + 4);
                const lastModifiedTimestamp = Number(combineBigNum({ low: lastModifiedLow, high: lastModifiedHigh }));
                if (lastModifiedTimestamp > 0) {
                    lastModified = new Date(lastModifiedTimestamp);
                }
                offset += 8;
            }
        }
        
        // Read isDeleted flag (if exists in format)
        const isDeleted = treeData.readUInt8(offset) === 1;
        offset += 1;
        
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
    const nodeRefCount = treeData.readUInt32LE(offset);
    offset += 4;
    
    const sortedNodeRefs: MerkleNodeRef[] = [];
    
    for (let i = 0; i < nodeRefCount; i++) {
        // Read fileName
        const fileNameLength = treeData.readUInt32LE(offset);
        offset += 4;
        
        const fileName = treeData.slice(offset, offset + fileNameLength).toString('utf8');
        offset += fileNameLength;
        
        // Read fileIndex
        const fileIndex = treeData.readUInt32LE(offset);
        offset += 4;
        
        // Read isDeleted flag (if exists in format)
        const isDeleted = treeData.readUInt8(offset) === 1;
        offset += 1;
        
        // Create nodeRef
        sortedNodeRefs.push({
            fileName,
            fileIndex,
            isDeleted
        });
    }
    
    return {
        nodes,
        sortedNodeRefs,
        metadata,
        databaseMetadata,
        version,
    };
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
    fileName: string, 
    timestampProvider: ITimestampProvider
): boolean {
    if (!merkleTree || merkleTree.nodes.length === 0) {
        return false;
    }
    
    // Find the node reference to mark as deleted
    const nodeRef = findNodeRef(merkleTree, fileName);
    if (!nodeRef) {
        return false; // File not found
    }
    
    // Mark the node reference as deleted
    nodeRef.isDeleted = true;
    
    // Get the leaf node index
    const nodeIndex = getLeafNodeIndex(nodeRef.fileIndex, 0, merkleTree.nodes);
    const node = merkleTree.nodes[nodeIndex];
    
    // Mark node as deleted with a special tombstone hash
    node.isDeleted = true;
    node.hash = createTombstoneHash(fileName);
    node.size = 0;
    
    // Update parent hashes up to the root
    const pathToRoot = calculatePathToRoot(nodeIndex, merkleTree.nodes);
    
    // Skip the leaf node (last in path) and update all parents from bottom to top
    for (let i = pathToRoot.length - 2; i >= 0; i--) {
        const parentIndex = pathToRoot[i];
        const parent = merkleTree.nodes[parentIndex];

        const { leftNode, rightNode } = getChildren(parentIndex, merkleTree.nodes);       
        parent.hash = combineHashes(leftNode.hash, rightNode.hash); // Recalculate the parent's hash.
        parent.size = leftNode.size + rightNode.size; // Update size if needed.
    }
    
    // Update metadata if it exists
    if (merkleTree.metadata) {
        merkleTree.metadata = updateMetadata(
            merkleTree.metadata, 
            merkleTree.nodes.length, 
            merkleTree.metadata.totalFiles,
            merkleTree.nodes[0].size,
            timestampProvider
        );
    }
    
    return true;
}

/**
 * Checks if a file is marked as deleted in the Merkle tree
 * 
 * @param merkleTree The Merkle tree to check
 * @param fileName The name of the file to check
 * @returns true if the file exists and is marked as deleted, false otherwise
 */
export function isFileDeleted<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata>, fileName: string): boolean {
    if (!merkleTree || merkleTree.nodes.length === 0) {
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
    if (!merkleTree || merkleTree.nodes.length === 0) {
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
    if (!merkleTree || merkleTree.nodes.length === 0) {
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
        
        const nodeIndex = getLeafNodeIndex(nodeRef.fileIndex, 0, merkleTree.nodes);
        return merkleTree.nodes[nodeIndex];
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
        const nodeIndex = getLeafNodeIndex(nodeRef.fileIndex, 0, treeA.nodes);
        const node = treeA.nodes[nodeIndex];
        filesInA.set(nodeRef.fileName, { 
            hash: node.hash.toString('hex'),
            isDeleted: !!nodeRef.isDeleted
        });
    }
    
    // Process files in tree B
    for (const nodeRef of treeB.sortedNodeRefs) {
        processedFiles++;
        if (progressCallback && (processedFiles - treeA.sortedNodeRefs.length) % 1000 === 0) {
            progressCallback(`Indexing dest files | ${processedFiles - treeA.sortedNodeRefs.length} of ${treeB.sortedNodeRefs.length} files`);
        }
        const nodeIndex = getLeafNodeIndex(nodeRef.fileIndex, 0, treeB.nodes);
        const node = treeB.nodes[nodeIndex];
        filesInB.set(nodeRef.fileName, { 
            hash: node.hash.toString('hex'),
            isDeleted: !!nodeRef.isDeleted
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
export async function traverseNode(nodeIndex: number, nodes: MerkleNode[], callback: (node: MerkleNode) => Promise<boolean>): Promise<void>  {
    const node = nodes[nodeIndex];
    if (!await callback(node)) {
        return;
    }

    if (node.nodeCount > 1) {
        const { leftIndex, rightIndex } = getChildren(nodeIndex, nodes);
        await traverseNode(leftIndex, nodes, callback);
        await traverseNode(rightIndex, nodes, callback);
    }
}

//
// Traverse the tree and call the callback function for each node.
// If the callback returns false, the traversal stops.
//
export async function traverseTree<DatabaseMetadata>(tree: IMerkleTree<DatabaseMetadata>, callback: (node: MerkleNode) => Promise<boolean>): Promise<void>  {
    if (!tree || tree.nodes.length === 0) {
        return;
    }

    await traverseNode(0, tree.nodes, callback);
}
