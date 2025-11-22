import * as crypto from 'crypto';
import { IStorage } from 'storage';
import { parse as parseUuid, stringify as stringifyUuid } from 'uuid';
import { save, load, ISerializer, IDeserializer } from 'serialization';
import { traverseTreeSync } from './traverse';

//
// Current database version
//
export const CURRENT_DATABASE_VERSION = 5;

//
// Generic node interface for traversal.
//
export interface INode<NodeT> {
    left?: INode<NodeT>;
    right?: INode<NodeT>;
}

//
// Represents a node in the Merkle tree.
//
export interface SortNode { //todo: Would be nice to have SortLeaf and SortParent. They have different properties!
    contentHash?: Buffer; // The hash of the content, for leaf nodes only.
    name?: string; // The name/identifier this hash represents, for leaf nodes only.
    nodeCount: number; // Number of nodes in the subtree rooted at this node (including this node). Set to 1 for leaf nodes.
    size: number; // The size of the node and children in bytes.
    lastModified?: Date; // The last modified date (for leaf nodes only, version 3+).
    minName: string; // The minimum name in this subtree (for efficient sorted insertion).
    left?: SortNode; // Left child node
    right?: SortNode; // Right child node
}

//
// Represents a merkle tree node.
//
export interface MerkleNode {
    hash: Buffer; // The hash of this node.
    nodeCount: number; // Number of nodes in the subtree rooted at this node (including this node). Set to 1 for leaf nodes.
    name?: string; // The name/identifier of the item (only set for leaf nodes).
    left?: MerkleNode; // Left child node
    right?: MerkleNode; // Right child node
}

//
// The hash and other information about an item.
//
export interface IHashedData {
    //
    // The sha256 hash of the item.
    //
    hash: Buffer;

    //
    // The length/size of the item in bytes.
    //
    length: number;

    //
    // The last modified date of the item.
    //
    lastModified: Date;
}

//
// Represents a hashed item to add to the Merkle tree.
//
export interface HashedItem extends IHashedData {
    name: string; // The name/identifier of the item.
}

//
// Represents the merkle tree itself.
//
export interface IMerkleTree<DatabaseMetadata> {
    //
    // A UUID that uniquely identifies the tree
    //
    id: string;

    // 
    // The root of the binary sort tree.
    //
    sort?: SortNode;

    //
    // Set to true if the tree is dirty and needs to be rebuilt.
    //
    dirty: boolean;

    //
    // The root of the Merkle tree.
    //
    merkle?: MerkleNode;

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
 * Find an item node in the binary tree by name.
 * This is the core tree traversal function that should be reused everywhere.
 */
export function findItemInTree(node: SortNode | undefined, targetName: string): SortNode | undefined {
    if (!node) return undefined;
    
    if (node.nodeCount === 1) {
        return node.name === targetName ? node : undefined;
    }
    
    const leftResult = findItemInTree(node.left, targetName);
    if (leftResult) return leftResult;
    
    return findItemInTree(node.right, targetName);
}

/**
 * Generic function to find and update a node in the binary tree.
 * The updater function should return true if the node was updated, false otherwise.
 * If a node is updated, parent nodes will have their properties recalculated.
 */
export function updateNodeInTree<T>(
    node: SortNode, 
    targetName: string, 
    updater: (node: SortNode, targetName: string) => T
): T | undefined {
    // If this is a leaf node, check if it's the target
    if (node.nodeCount === 1) {
        if (node.name === targetName) {
            return updater(node, targetName);
        }
        return undefined; // Not the target
    }
    
    // Internal node - recursively check children
    let result: T | undefined = undefined;
    
    // Check left subtree
    if (node.left) {
        result = updateNodeInTree(node.left, targetName, updater);
    }
    
    // Check right subtree (only if not found in left)
    if (!result && node.right) {
        result = updateNodeInTree(node.right, targetName, updater);
    }
    
    // If a child was updated, recalculate this node's properties
    if (result !== undefined) {
        const leftSize = node.left?.size || 0;
        const rightSize = node.right?.size || 0;        
        node.size = leftSize + rightSize;
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
// Compare two names for sorting in the merkle tree.
// Returns negative if a < b, zero if equal, positive if a > b.
// Uses natural/numeric-aware sorting for intuitive ordering.
//
export function compareNames(a: string, b: string): number {
    return a.localeCompare(b, undefined, { numeric: true });
}

/**
 * Create a new leaf node for an item
 */
export function createLeafNode(item: HashedItem): SortNode {
    return {
        contentHash: item.hash,
        name: item.name,
        nodeCount: 1, // Leaf nodes have a node count of 1.
        size: item.length, // Size is the length of the item.
        lastModified: item.lastModified, // Include last modified date if provided.
        minName: item.name, // For leaf nodes, minName is the name itself.
    };
}

/**
 * Create a parent node from two child nodes
 */
export function createParentNode(left: SortNode, right: SortNode): SortNode {
    return {
        name: undefined, // Internal nodes don't represent an item
        nodeCount: 1 + left.nodeCount + right.nodeCount, // Total node count is 1 (this node) + left + right
        size: left.size + right.size, // Total size is the sum of both subtrees.
        minName: left.minName, // Since we maintain sorted order, the min name is always the min of the left subtree
        left: left,
        right: right,
    };
}

/**
 * Convert binary tree to flat array (for serialization)
 */
export function binaryTreeToArray(root: SortNode | undefined): Omit<SortNode, 'minName'>[] {
    if (!root) {
        return [];
    }
    
    const result: Omit<SortNode, 'minName'>[] = [];

    traverseTreeSync<SortNode>(root, (node) => {
        const flatNode: Omit<SortNode, 'minName'> = {
            contentHash: node.contentHash,
            name: node.name,
            nodeCount: node.nodeCount,
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
export function arrayToBinaryTree(nodes: Omit<SortNode, 'minName'>[]): SortNode | undefined {
    if (nodes.length === 0) return undefined;
    
    // For now, use a simple approach - rebuild tree structure based on the array
    // This assumes the array was created by depth-first traversal
    let index = 0;
    
    function buildNode(): SortNode | undefined {
        if (index >= nodes.length) return undefined;
        
        const node = { ...nodes[index++] };
        
        if (node.nodeCount === 1) {
            // Leaf node - no children
            return { 
                ...node, 
                minName: node.name!,
            };
        }
        
        // Internal node - recursively build left and right
        node.left = buildNode();
        node.right = buildNode();
        
        return { 
            ...node, 
            minName: node.left!.minName!,
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
export function rebalanceTree(node: SortNode): SortNode {
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
        //console.log(`Tree is left-heavy, performing right rotation`);

        const leftLeftCount = left.left?.nodeCount || 0;
        const leftRightCount = left.right?.nodeCount || 0;
        
        // Left-Left case: rotate right
        if (leftLeftCount >= leftRightCount) {
            // console.log(`Left-Left case, performing right rotation`);
            return rotateRight(node);
        }
        // Left-Right case: rotate left then right
        else {
            // console.log(`Left-Right case, performing left rotation then right rotation`);
            const newLeft = rotateLeft(node.left!);
            return rotateRight({ ...node, left: newLeft });
        }
    }
    else if (balance < 0) {
        // Right-heavy tree (rightCount > leftCount + 1)
        // We don't tollerate right heavy trees in the interest of producing 
        // equivalent trees regardless of the order of insertion.
        // console.log(`Tree is right-heavy, performing left rotation`);
        const rightLeftCount = right.left?.nodeCount || 0;
        const rightRightCount = right.right?.nodeCount || 0;
        
        // Right-Right case: rotate left
        if (rightRightCount >= rightLeftCount) {
            // console.log(`Right-Right case, performing left rotation`);
            return rotateLeft(node);
        }
        // Right-Left case: rotate right then left
        else {
            // console.log(`Right-Left case, performing right rotation then left rotation`);
            const newRight = rotateRight(right);
            return rotateLeft({ ...node, right: newRight });
        }
    }
    else {
        // If tree is reasonably balanced (difference <= 2), no rotation needed.
        // console.log(`Tree is reasonably balanced, no rotation needed`);
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
export function rotateRight(node: SortNode): SortNode {
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
        size: newLeft.size + newCenter.size + right.size,
        minName: newLeft.minName,
        left: newLeft,
        right: {
            left: newCenter,
            right: right,
            nodeCount: 1 + newCenter.nodeCount + right.nodeCount,
            size: newCenter.size + right.size,
            minName: newCenter.minName,
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
export function rotateLeft(node: SortNode): SortNode {
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
        size: left.size + newCenter.size + newRight.size,
        minName: left.minName,
        left: {
            left: left,
            right: newCenter,
            nodeCount: 1 + left.nodeCount + newCenter.nodeCount,
            size: left.size + newCenter.size,
            minName: left.minName,
        },
        right: newRight,
    };
}

/**
 * Add an item to the Merkle tree using binary tree structure (avoids recursion)
 */
function _addItem(node: SortNode | undefined, item: HashedItem): SortNode {
    const newLeaf = createLeafNode(item);

    if (!node) {
        // If the tree is empty, return the new leaf as the root
        // console.log(`Adding item ${item.name} to empty tree`);
        return newLeaf;
    }
    
    // If current node is a leaf, determine correct order and create parent
    if (node.nodeCount === 1) {
        if (compareNames(item.name, node.name!) < 0) {
            // console.log(`Adding item ${item.name} to left of ${node.name}`);
            return createParentNode(newLeaf, node); // new item goes left
        } else {
            // console.log(`Adding item ${item.name} to right of ${node.name}`);
            return createParentNode(node, newLeaf); // new item goes right
        }
    }   

    const left = node.left;
    const right = node.right;
    if (!left || !right) {
        throw new Error('Invalid tree structure');
    }

    const rightMin = right.minName!; // If not a leaf node, there must always be a right child with a minName.
    let newLeft = left;
    let newRight = right;

    if (compareNames(item.name, rightMin) < 0) {
        // console.log(`Adding item ${item.name} to left of ${rightMin}`);
        // Item should go in left subtree based on sorting
        newLeft = _addItem(left, item);
    } else {
        // console.log(`Adding item ${item.name} to right of ${rightMin}`);
        // Item should go in right subtree based on sorting
        newRight = _addItem(right, item);
    }
    
    // Create new node with updated children and recalculated properties
    const newLeftCount = newLeft.nodeCount;
    const newRightCount = newRight.nodeCount;
    const newLeftSize = newLeft.size;
    const newRightSize = newRight.size;
    
    const newNode: SortNode = {
        left: newLeft,
        right: newRight,
        nodeCount: 1 + newLeftCount + newRightCount,
        size: newLeftSize + newRightSize,
        minName: newLeft.minName,
    };
   
    return rebalanceTree(newNode);
}

//
// Create a new empty Merkle tree.
//
export function createTree<DatabaseMetadata>(uuid: string): IMerkleTree<DatabaseMetadata> {
    return {
        id: uuid,
        sort: undefined,
        dirty: false,
        merkle: undefined,
        version: CURRENT_DATABASE_VERSION,
    };
}

/**
 * Add an item to the Merkle tree, efficiently creating a balanced structure
 * without rebuilding the entire tree
 */
export function addItem<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    item: HashedItem
): IMerkleTree<DatabaseMetadata> {

    //
    // Adds the new leaf node to the merkle tree.
    //
    const sort = _addItem(merkleTree?.sort, item);
   
    return {
        id: merkleTree.id,
        sort,
        dirty: true, // Mark the tree as dirty so it will be rebuilt later.
        merkle: merkleTree?.merkle,
        version: merkleTree?.version || CURRENT_DATABASE_VERSION,
        databaseMetadata: merkleTree?.databaseMetadata,
    };
}

// 
// Iterates all nodes in the tree.
//
export function* iterateNodes<NodeT>(node: INode<NodeT> | undefined): Generator<NodeT> {
    if (!node) {
        return;
    }

    yield node as NodeT;

    yield* iterateNodes(node.left);
    yield* iterateNodes(node.right);
}

// 
// Iterates all leaves in the tree.
//
export function* iterateLeaves<NodeT>(node: INode<NodeT> | undefined): Generator<NodeT> {
    if (!node) {
        return;
    }

    if (!node.left && !node.right) {
        yield node as NodeT;
    }

    yield* iterateLeaves(node.left);
    yield* iterateLeaves(node.right);
}

//
// Builds a merkle tree from a sort tree.
//
export function buildMerkleTree(sort: SortNode | undefined): MerkleNode | undefined {
    if (!sort) {
        return undefined;
    }

    // Stack to hold nodes at each level during construction
    // Similar to binary addition with carries
    const stack: (MerkleNode | undefined)[] = [];

    // Process each leaf node from the sort tree
    for (const leaf of iterateLeaves<SortNode>(sort)) {
        if (!leaf.contentHash) {
            throw new Error('Leaf node has no content hash');
        }

        if (!leaf.name) {
            throw new Error('Leaf node has no name');
        }

        let node: MerkleNode = {
            hash: leaf.contentHash,
            nodeCount: 1,
            name: leaf.name,
        };

        // Try to combine this node with nodes at each level going up
        let level = 0;
        while (level < stack.length && stack[level] !== undefined) {
            // Combine with the node at this level
            const left = stack[level]!;
            const right = node;
            
            node = {
                hash: combineHashes(left.hash, right.hash),
                nodeCount: left.nodeCount + right.nodeCount + 1,
                left: left,
                right: right,
            };
            
            // Clear this level and move up
            stack[level] = undefined;
            level++;
        }

        // Place the node at the current level
        if (level >= stack.length) {
            stack.push(node);
        } else {
            stack[level] = node;
        }
    }

    // Combine any remaining nodes in the stack to preserve order
    // The stack is organized by tree level: lower indices are deeper (processed later, rightmost),
    // higher indices are higher (processed earlier, leftmost)
    // To preserve leaf order, we need to combine from high index to low index
    // (earlier/leftmost on left, later/rightmost on right)
    const stackNodes: MerkleNode[] = [];
    for (const node of stack) {
        if (node !== undefined) {
            stackNodes.push(node);
        }
    }

    if (stackNodes.length === 0) {
        return undefined;
    }

    // Combine from last to first (high index to low): earlier nodes (high index) on left, later nodes (low index) on right
    let result = stackNodes[stackNodes.length - 1];
    for (let i = stackNodes.length - 2; i >= 0; i--) {
        // stackNodes[i] is later (lower index = deeper in tree), result is earlier (higher index = higher in tree)
        // To preserve order: earlier (result) on left, later (stackNodes[i]) on right
        result = {
            hash: combineHashes(result.hash, stackNodes[i].hash),
            nodeCount: result.nodeCount + stackNodes[i].nodeCount + 1,
            left: result,
            right: stackNodes[i],
        };
    }

    return result;
}

//
// Upsert an item in the Merkle tree, either adding it or updating it if it already exists.
// Updates the tree in place.
//
export function upsertItem<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    item: HashedItem
): IMerkleTree<DatabaseMetadata> {
    if (merkleTree && merkleTree.sort) {
        if (updateItem(merkleTree, item)) {
            // Item updated successfully in place.
            return merkleTree;
        }
    }

    return addItem(merkleTree, item);
}

/**
 * Update an item in the Merkle tree with new content, maintaining the same tree structure.
 */
export function updateItem<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata> | undefined, 
    item: HashedItem
): boolean {
    if (!merkleTree || !merkleTree.sort) {
        throw new Error(`Tree is empty, cannot update item '${item.name}'`);
    }
    
    // Use the centralized updateNodeInTree function to find and update the item
    const wasUpdated = updateNodeInTree(merkleTree.sort, item.name, (node, targetName) => {
        // Update the leaf node in place
        node.contentHash = item.hash;
        node.lastModified = item.lastModified;
        node.size = item.length; // Update the size with the new item length
        return true; // Found and updated
    }) ?? false;
    
    if (wasUpdated) {
        merkleTree.dirty = true; // Mark the tree as dirty so it will be rebuilt later.
    }
    
    return wasUpdated;
}


//
// Get item information from merkle tree (hash, size, lastModified)
// This replaces the need for database hash cache lookups
//
export function getItemInfo<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata>, name: string): { hash: Buffer, length: number, lastModified: Date } | undefined {
    // Use the centralized findItemInTree function
    const leafNode = findItemInTree(merkleTree.sort, name);
    
    if (!leafNode) {
        return undefined;
    }

    if (!leafNode.lastModified) {
        throw new Error(`Item ${name} is missing lastModified date. This could be a bug.`);
    }

    if (!leafNode.contentHash) {
        throw new Error(`Item ${name} is missing content hash. This could be a bug.`);
    }

    return {
        hash: leafNode.contentHash,
        length: leafNode.size,
        lastModified: leafNode.lastModified,
    };
}

/**
 * Find an item node in the tree by name
 * 
 * This function uses tree traversal to find a node by name.
 * Returns the node if found, or undefined if not found.
 */
export function findItemNode<DatabaseMetadata>(merkleTree: IMerkleTree<DatabaseMetadata> | undefined, name: string): SortNode | undefined {
    if (!merkleTree || !merkleTree.sort) {
        return undefined;
    }
    
    // Recursive binary search through the tree
    function searchNode(node: SortNode | undefined, targetName: string): SortNode | undefined {
        if (!node) {
            return undefined;
        }
        
        // If this is a leaf node, check if it matches
        if (node.nodeCount === 1) {
            return node.name === targetName ? node : undefined;
        }
        
        // Internal node - use binary search based on minName
        const left = node.left;
        const right = node.right;
        
        if (!left || !right) {
            throw new Error('Invalid tree structure: internal node missing children');
        }
        
        // If target is less than the minimum of right subtree, search left
        if (compareNames(targetName, right.minName) < 0) {
            return searchNode(left, targetName);
        } else {
            // Otherwise search right
            return searchNode(right, targetName);
        }
    }
    
    return searchNode(merkleTree.sort, name);
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

//
// Recursively serializes a single merkle tree node and its children (version 5 with string table).
//
function serializeMerkleNodeV5(node: MerkleNode, serializer: ISerializer, stringTable: Map<string, number>): void {
    // Write nodeCount
    serializer.writeUInt32(node.nodeCount);
    
    // Write the hash (32 bytes)
    if (node.hash.length !== 32) {
        throw new Error(`Invalid hash length: ${node.hash.length}, expected 32 bytes`);
    }
    serializer.writeBytes(node.hash);
    
    // For leaf nodes, write the name index
    if (node.nodeCount === 1) {
        if (!node.name) {
            throw new Error('Leaf node has no name');
        }
        const nameIndex = stringTable.get(node.name);
        if (nameIndex === undefined) {
            throw new Error(`name "${node.name}" not found in string table. This could be a bug.`);
        }
        serializer.writeUInt32(nameIndex);
    }
    
    // Recursively write children if this is not a leaf
    if (node.left) {
        serializeMerkleNodeV5(node.left, serializer, stringTable);
    }
    if (node.right) {
        serializeMerkleNodeV5(node.right, serializer, stringTable);
    }
}

//
// Recursively serializes a single merkle tree node and its children (version 4 and earlier).
//
function serializeMerkleNode(node: MerkleNode, serializer: ISerializer): void {
    // Write nodeCount
    serializer.writeUInt32(node.nodeCount);
    
    // Write the hash (32 bytes)
    if (node.hash.length !== 32) {
        throw new Error(`Invalid hash length: ${node.hash.length}, expected 32 bytes`);
    }
    serializer.writeBytes(node.hash);
    
    // For leaf nodes, write the name
    if (node.nodeCount === 1) {
        if (!node.name) {
            throw new Error('Leaf node has no name');
        }
        serializer.writeString(node.name);
    }
    
    // Recursively write children if this is not a leaf
    if (node.left) {
        serializeMerkleNode(node.left, serializer);
    }
    if (node.right) {
        serializeMerkleNode(node.right, serializer);
    }
}

//
// Serializes the merkle tree nodes (version 5 with string table).
//
function serializeMerkleV5<DatabaseMetadata>(tree: IMerkleTree<DatabaseMetadata>, serializer: ISerializer, stringTable: Map<string, number>): void {
    if (!tree.merkle) {
        // Write 0 to indicate no merkle tree
        serializer.writeUInt32(0);
        return;
    }

    // Recursively serialize the merkle tree (root nodeCount will indicate total nodes)
    serializeMerkleNodeV5(tree.merkle, serializer, stringTable);
}

//
// Serializes the merkle tree nodes (version 4 and earlier).
//
function serializeMerkle<DatabaseMetadata>(tree: IMerkleTree<DatabaseMetadata>, serializer: ISerializer): void {
    if (!tree.merkle) {
        // Write 0 to indicate no merkle tree
        serializer.writeUInt32(0);
        return;
    }

    // Recursively serialize the merkle tree (root nodeCount will indicate total nodes)
    serializeMerkleNode(tree.merkle, serializer);
}

//
// Serializes the sort tree metadata and nodes (version 5 with string table).
//
function serializeSortTreeV5<DatabaseMetadata>(tree: IMerkleTree<DatabaseMetadata>, serializer: ISerializer, stringTable: Map<string, number>): void {
    if (!tree.sort) {
        // Write 0 to indicate no tree
        serializer.writeUInt32(0);
        return;
    }

    // Recursively serialize the sort tree (root's nodeCount serves as the "tree exists" indicator)
    serializeSortNodeV5(tree.sort, serializer, stringTable);
}

//
// Recursively serializes a single sort tree node and its children (version 5 with string table).
//
function serializeSortNodeV5(node: SortNode, serializer: ISerializer, stringTable: Map<string, number>): void {
    // Write nodeCount
    serializer.writeUInt32(node.nodeCount);
    
    if (node.nodeCount === 1) {
        // Leaf node
        if (!node.name) {
            throw new Error(`Leaf node has no name. This could be a bug.`);
        }

        if (!node.contentHash) {
            throw new Error(`Leaf node has no content hash. This could be a bug.`);
        }

        // Write size (only for leaf nodes)
        const splitSize = splitBigNum(BigInt(node.size));
        serializer.writeUInt32(splitSize.low);
        serializer.writeUInt32(splitSize.high);

        // Write name index
        const nameIndex = stringTable.get(node.name);
        if (nameIndex === undefined) {
            throw new Error(`name "${node.name}" not found in string table. This could be a bug.`);
        }
        serializer.writeUInt32(nameIndex);

        // Write content hash
        serializer.writeBytes(node.contentHash);
        
        // Write item metadata for leaf nodes in version 3+
        // Write lastModified timestamp (8 bytes)
        const lastModified = node.lastModified ? node.lastModified.getTime() : 0;
        const splitLastModified = splitBigNum(BigInt(lastModified));
        serializer.writeUInt32(splitLastModified.low);
        serializer.writeUInt32(splitLastModified.high);
    } else {
        // Internal node - recursively serialize children
        if (node.left) {
            serializeSortNodeV5(node.left, serializer, stringTable);
        }
        if (node.right) {
            serializeSortNodeV5(node.right, serializer, stringTable);
        }
    }
}

//
// Collects all unique strings from the tree for the string table.
//
function collectStrings<DatabaseMetadata>(tree: IMerkleTree<DatabaseMetadata>): Set<string> {
    const strings = new Set<string>();
    
    // Collect from sort tree
    function collectFromSortNode(node: SortNode | undefined): void {
        if (!node) return;
        
        if (node.name) {
            strings.add(node.name);
        }
        
        collectFromSortNode(node.left);
        collectFromSortNode(node.right);
    }
    
    // Collect from merkle tree
    function collectFromMerkleNode(node: MerkleNode | undefined): void {
        if (!node) return;
        
        if (node.name) {
            strings.add(node.name);
        }
        
        collectFromMerkleNode(node.left);
        collectFromMerkleNode(node.right);
    }
    
    collectFromSortNode(tree.sort);
    collectFromMerkleNode(tree.merkle);
    
    return strings;
}

/**
 * Serializes a merkle tree to storage.
 * 
 * File format (version 5):
 * 
 * Database metadata:
 * - X bytes: Database metadata as BSON
 * 
 * Tree metadata:
 * - 16 bytes: UUID
 * 
 * String table:
 * - 4 bytes: string table size (number of strings, uint32)
 * - For each string:
 *   - 4 bytes: string length (uint32)
 *   - X bytes: string (UTF-8)
 * 
 * Sort tree (pre-order traversal):
 * - For each sort node (root's nodeCount of 0 means no tree):
 *   - 4 bytes: nodeCount (uint32, 1 for leaf nodes, 0 if no tree)
 *   - If leaf node (nodeCount == 1):
 *     - 8 bytes: size (uint64 split into low/high uint32s)
 *     - 4 bytes: name index (uint32) - index into string table
 *     - 32 bytes: content hash (SHA-256)
 *     - 8 bytes: lastModified timestamp (uint64 split into low/high uint32s)
 *   - If internal node (nodeCount > 1):
 *     - Recursively serialize children
 *   - Note: minName and size for internal nodes are recalculated during deserialization
 *     (minName = name for leaf nodes, minName = left.minName for internal nodes)
 * 
 * Merkle tree:
 * - For each merkle node (pre-order traversal, root nodeCount of 0 means no merkle tree):
 *   - 4 bytes: nodeCount (uint32, 1 for leaf nodes, 0 for no tree)
 *   - 32 bytes: hash (SHA-256) - only if nodeCount > 0
 *   - If leaf node (nodeCount == 1):
 *     - 4 bytes: name index (uint32) - index into string table
 */
function serializeMerkleTree<DatabaseMetadata>(tree: IMerkleTree<DatabaseMetadata>, serializer: ISerializer): void {
    // Write database metadata BSON
    serializer.writeBSON(tree.databaseMetadata);
        
    // Write tree UUID
    const idBuffer = Buffer.from(parseUuid(tree.id));
    if (idBuffer.length !== 16) {
        throw new Error(`Invalid UUID length: ${idBuffer.length}`);
    }
    serializer.writeBytes(idBuffer);
    
    // Collect all unique strings and build string table
    const uniqueStrings = collectStrings(tree);
    const stringArray = Array.from(uniqueStrings);
    const stringTable = new Map<string, number>();
    stringArray.forEach((str, index) => {
        stringTable.set(str, index);
    });
    
    // Write string table
    serializer.writeUInt32(stringArray.length);
    for (const str of stringArray) {
        serializer.writeString(str);
    }
    
    // Write sort tree metadata and nodes (using string indices)
    serializeSortTreeV5(tree, serializer, stringTable);
    
    // Write merkle tree nodes (using string indices)
    serializeMerkleV5(tree, serializer, stringTable);
}

//
// Rebuild a merkle tree in sorted order and removes a path.
//
export function rebuildTree<DatabaseMetadata>(tree: IMerkleTree<DatabaseMetadata>, pathsToRemove: string[]): IMerkleTree<DatabaseMetadata> {

    const items: HashedItem[] = [];

    traverseTreeSync<SortNode>(tree.sort, (node) => {
        if (node.nodeCount === 1) {
            if (!node.name) {
                throw new Error(`Leaf node has no name. This could be a bug.`);
            }

            if (!node.contentHash) {
                throw new Error(`Leaf node has no content hash. This could be a bug.`);
            }

            if (!node.lastModified) {
                throw new Error(`Leaf node has no last modified date. This could be a bug.`);
            }

            for (const pathToRemove of pathsToRemove) {            
                if (node.name.startsWith(pathToRemove)) {
                    // Don't add this item to the new tree.
                    return true;
                }
            }

            items.push({
                name: node.name,
                hash: node.contentHash!,
                length: node.size,
                lastModified: node.lastModified
            });
        }
        return true;
    });

    //
    // Sort by name.
    //
    // TODO: In theory this sorting step shouldn't be required because addItem should
    // put the item in sorted order in the tree. But something isn't quite right when
    // trying to replicate a rebuilt tree.
    //
    items.sort((a, b) => compareNames(a.name, b.name));

    //
    // Add all items in sorted order to a new tree.
    //
    let rebuiltTree = createTree<DatabaseMetadata>(tree.id);
    rebuiltTree.databaseMetadata = tree.databaseMetadata;
    for (const item of items) {
        // console.log(`Adding item: ${item.name}`);
        rebuiltTree = addItem(rebuiltTree, item);
    }

    rebuiltTree.dirty = false;
    rebuiltTree.merkle = buildMerkleTree(rebuiltTree.sort);

    return rebuiltTree;
}

//
// Recursively deserializes a single merkle tree node and its children (version 5 with string table).
//
function deserializeMerkleNodeV5(deserializer: IDeserializer, stringTable: string[]): MerkleNode {
    // Read nodeCount
    const nodeCount = deserializer.readUInt32();
    
    // Read this node's hash
    const hash = deserializer.readBytes(32);
    
    if (nodeCount === 1) {
        // Leaf node - read name index
        const nameIndex = deserializer.readUInt32();
        if (nameIndex >= stringTable.length) {
            throw new Error(`name index ${nameIndex} is out of bounds for string table of size ${stringTable.length}`);
        }
        const name = stringTable[nameIndex];
        return { hash, nodeCount, name };
    } else {
        // Internal node - recursively deserialize children
        const left = deserializeMerkleNodeV5(deserializer, stringTable);
        const right = deserializeMerkleNodeV5(deserializer, stringTable);
        
        return {
            hash,
            nodeCount,
            left,
            right,
        };
    }
}

//
// Recursively deserializes a single merkle tree node and its children (version 4 and earlier).
//
function deserializeMerkleNode(deserializer: IDeserializer): MerkleNode {
    // Read nodeCount
    const nodeCount = deserializer.readUInt32();
    
    // Read this node's hash
    const hash = deserializer.readBytes(32);
    
    if (nodeCount === 1) {
        // Leaf node - read name
        const name = deserializer.readString();
        return { hash, nodeCount, name };
    } else {
        // Internal node - recursively deserialize children
        const left = deserializeMerkleNode(deserializer);
        const right = deserializeMerkleNode(deserializer);
        
        return {
            hash,
            nodeCount,
            left,
            right,
        };
    }
}

//
// Deserializes the merkle tree nodes (version 5 with string table).
//
function deserializeMerkleV5(deserializer: IDeserializer, stringTable: string[]): MerkleNode | undefined {
    // Read the root node's nodeCount (0 means no merkle tree)
    const nodeCount = deserializer.readUInt32();    
    if (nodeCount === 0) {
        // No merkle tree was serialized
        return undefined;
    }
    
    // Read the root node's hash
    const hash = deserializer.readBytes(32);
    
    if (nodeCount === 1) {
        // Root is a leaf node - read name index
        const nameIndex = deserializer.readUInt32();
        if (nameIndex >= stringTable.length) {
            throw new Error(`name index ${nameIndex} is out of bounds for string table of size ${stringTable.length}`);
        }
        const name = stringTable[nameIndex];
        return { hash, nodeCount, name };
    } else {
        // Root is an internal node - recursively deserialize children
        const left = deserializeMerkleNodeV5(deserializer, stringTable);
        const right = deserializeMerkleNodeV5(deserializer, stringTable);
        
        return {
            hash,
            nodeCount,
            left,
            right,
        };
    }
}

//
// Deserializes the merkle tree nodes (version 4 and earlier).
//
function deserializeMerkle(deserializer: IDeserializer): MerkleNode | undefined {
    // Read the root node's nodeCount (0 means no merkle tree)
    const nodeCount = deserializer.readUInt32();    
    if (nodeCount === 0) {
        // No merkle tree was serialized
        return undefined;
    }
    
    // Read the root node's hash
    const hash = deserializer.readBytes(32);
    
    if (nodeCount === 1) {
        // Root is a leaf node - read name
        const name = deserializer.readString();
        return { hash, nodeCount, name };
    } else {
        // Root is an internal node - recursively deserialize children
        const left = deserializeMerkleNode(deserializer);
        const right = deserializeMerkleNode(deserializer);
        
        return {
            hash,
            nodeCount,
            left,
            right,
        };
    }
}

//
// Recursively deserializes a single sort tree node and its children (version 5 with string table).
//
function deserializeSortNodeV5(deserializer: IDeserializer, stringTable: string[]): SortNode | undefined {
    // Read node metadata
    const nodeCount = deserializer.readUInt32();    
    if (nodeCount === 0) {
        // Root node with nodeCount of 0 means empty tree
        return undefined;
    }
    
    if (nodeCount === 1) {
        // This is a leaf node
        // Read size (only serialized for leaf nodes)
        const sizeLow = deserializer.readUInt32();
        const sizeHigh = deserializer.readUInt32();
        const size = Number(combineBigNum({ low: sizeLow, high: sizeHigh }));
        
        // Read name index
        const nameIndex = deserializer.readUInt32();
        if (nameIndex >= stringTable.length) {
            throw new Error(`name index ${nameIndex} is out of bounds for string table of size ${stringTable.length}`);
        }
        const name = stringTable[nameIndex];
        
        const contentHash = deserializer.readBytes(32);
        
        const lastModifiedLow = deserializer.readUInt32();
        const lastModifiedHigh = deserializer.readUInt32();
        const lastModifiedTimestamp = Number(combineBigNum({ low: lastModifiedLow, high: lastModifiedHigh }));
        const lastModified = lastModifiedTimestamp > 0 ? new Date(lastModifiedTimestamp) : undefined;
        
        // For leaf nodes, minName equals name
        return {
            contentHash,
            name,
            nodeCount,
            size,
            lastModified,
            minName: name,
        };
    } else {
        // This is an internal node - recursively read children
        const left = deserializeSortNodeV5(deserializer, stringTable);
        const right = deserializeSortNodeV5(deserializer, stringTable);
        
        // Recalculate size from children (size is not serialized for internal nodes)
        const size = (left?.size || 0) + (right?.size || 0);
        
        return {
            nodeCount,
            size,
            minName: left!.minName,
            left,
            right,
        };
    }
}

//
// Recursively deserializes a single sort tree node and its children (version 4 and earlier).
//
function deserializeSortNode(deserializer: IDeserializer): SortNode | undefined {
    // Read node metadata
    const nodeCount = deserializer.readUInt32();    
    if (nodeCount === 0) {
        // Root node with nodeCount of 0 means empty tree
        return undefined;
    }
    
    deserializer.readUInt32(); // Drop the leaf count.
    const sizeLow = deserializer.readUInt32();
    const sizeHigh = deserializer.readUInt32();
    const size = Number(combineBigNum({ low: sizeLow, high: sizeHigh }));
    
    if (nodeCount === 1) {
        // This is a leaf node
        const nameLength = deserializer.readUInt32(); //todo: Use readString.
        const nameBytes = deserializer.readBytes(nameLength);
        const name = nameBytes.toString('utf8');
        
        const contentHash = deserializer.readBytes(32);
        
        const lastModifiedLow = deserializer.readUInt32();
        const lastModifiedHigh = deserializer.readUInt32();
        const lastModifiedTimestamp = Number(combineBigNum({ low: lastModifiedLow, high: lastModifiedHigh }));
        const lastModified = lastModifiedTimestamp > 0 ? new Date(lastModifiedTimestamp) : undefined;
        
        return {
            contentHash,
            name,
            nodeCount,
            size,
            lastModified,
            minName: name,
        };
    } else {
        // This is an internal node - recursively read children
        const left = deserializeSortNode(deserializer);
        const right = deserializeSortNode(deserializer);        
        return {
            nodeCount,
            size,
            minName: left!.minName,
            left,
            right,
        };
    }
}

//
// Deserializes the sort tree metadata and nodes (version 5 with string table).
//
function deserializeSortTreeV5(deserializer: IDeserializer, stringTable: string[]): SortNode | undefined {
    // Deserialize the root node (may return undefined if nodeCount is 0)
    return deserializeSortNodeV5(deserializer, stringTable);
}

//
// Deserializes the sort tree metadata and nodes (version 4 and earlier).
//
function deserializeSortTree(deserializer: IDeserializer): SortNode | undefined {
    // Deserialize the root node (may return undefined if nodeCount is 0)
    return deserializeSortNode(deserializer);
}

//
// Deserializer function for merkle tree (version 5)
//
function deserializeMerkleTreeV5<DatabaseMetadata>(deserializer: IDeserializer): IMerkleTree<DatabaseMetadata> {
    // Read database metadata BSON
    const databaseMetadata = deserializer.readBSON<DatabaseMetadata>();
    
    // Read tree UUID
    const uuidBytes = deserializer.readBytes(16);
    const id = stringifyUuid(uuidBytes);
    
    // Read string table
    const stringTableSize = deserializer.readUInt32();
    const stringTable: string[] = [];
    for (let i = 0; i < stringTableSize; i++) {
        const str = deserializer.readString();
        stringTable.push(str);
    }
    
    // Read sort tree metadata and nodes (using string table)
    const sort = deserializeSortTreeV5(deserializer, stringTable);
    
    // Read merkle tree nodes (using string table)
    const merkle = deserializeMerkleV5(deserializer, stringTable);
    
    return {
        id,
        sort,
        dirty: false,
        merkle,
        databaseMetadata,
        version: 5,
    };
}

//
// Deserializer function for merkle tree (version 4)
//
function deserializeMerkleTreeV4<DatabaseMetadata>(deserializer: IDeserializer): IMerkleTree<DatabaseMetadata> {
    // Read database metadata BSON
    const databaseMetadata = deserializer.readBSON<DatabaseMetadata>();
    
    // Read tree UUID
    const uuidBytes = deserializer.readBytes(16);
    const id = stringifyUuid(uuidBytes);
    
    // Read sort tree metadata and nodes
    const sort = deserializeSortTree(deserializer);
    
    // Read merkle tree nodes
    const merkle = deserializeMerkle(deserializer);
    
    return {
        id,
        sort,
        dirty: false,
        merkle,
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
    
    deserializer.readUInt32();
    deserializer.readUInt32();
    deserializer.readUInt32();
    
    // Read all nodes
    const nodes: Omit<SortNode, 'minName'>[] = [];
    
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

        // Read name if present
        const nameLength = deserializer.readUInt32();
        
        let name: string | undefined;
        let lastModified: Date | undefined;
        
        if (nameLength > 0) {
            const nameBytes = deserializer.readBytes(nameLength);
            name = nameBytes.toString('utf8');
            
            // Read item metadata for leaf nodes in version 3+
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
            contentHash: nodeCount === 1 ? hash : undefined,
            name,
            nodeCount,
            size,
            lastModified,
            left: undefined,
            right: undefined
        });
    }
    
    const sort = arrayToBinaryTree(nodes);    
    return {
        id: uuid,
        sort,
        dirty: false,
        merkle: buildMerkleTree(sort), //TODO: Load the merkle tree from disk.
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
    
    deserializer.readUInt32();
    deserializer.readUInt32();
    deserializer.readUInt32();    
    deserializer.readUInt32(); // Created at low removed in v3.
    deserializer.readUInt32(); // Created at high removed in v3.
    deserializer.readUInt32(); // Modified at low removed in v3.
    deserializer.readUInt32(); // Modified at high removed in v3.

    // Read all nodes
    const nodes: Omit<SortNode, 'minName'>[] = [];
    
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

        // Read name if present
        const nameLength = deserializer.readUInt32();
        
        let name: string | undefined;
        let lastModified: Date | undefined;
        
        if (nameLength > 0) {
            const nameBytes = deserializer.readBytes(nameLength);
            name = nameBytes.toString('utf8');            
        }
        
        deserializer.readUInt8(); // Discard isDeleted flag.
        
        // Create node
        nodes.push({
            contentHash: nodeCount === 1 ? hash : undefined,
            name,
            nodeCount,
            size,
            lastModified,
            left: undefined,
            right: undefined
        });
    }
    
    const sort = arrayToBinaryTree(nodes);
    return {
        id: uuid,
        sort,
        dirty: false,
        merkle: buildMerkleTree(sort), //TODO: Load the merkle tree from disk.
        databaseMetadata: undefined,
        version: 2,
    };
}

//
// Saves a merkle tree to storage.
//
export async function saveTree<DatabaseMetadata>(filePath: string, tree: IMerkleTree<DatabaseMetadata>, storage: IStorage): Promise<void> {

    if (tree.dirty) {
        throw new Error('Tree is dirty. Cannot save. Make sure to rebuild the tree before saving.');
    }

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
        5: deserializeMerkleTreeV5<DatabaseMetadata>,
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
 * Delete an item node from the Merkle tree, actually removing it from the tree structure
 * This function properly removes the node and rebalances the tree
 * 
 * @param merkleTree The Merkle tree containing the item
 * @param name The name of the item to delete
 * @returns true if the item was found and deleted, false otherwise
 */
export function deleteItem<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    name: string
): void {
    merkleTree.sort = _deleteNode(merkleTree.sort, name);
    merkleTree.dirty = true; // Mark the tree as dirty so it will be rebuilt later.
}

/**
 * Internal function to delete a node from the tree and return the new root
 * This handles the complex logic of removing a node while maintaining tree structure
 */
function _deleteNode(node: SortNode | undefined, name: string): SortNode | undefined {
    if (!node) {
        return undefined;
    }

    // If this is a leaf node, check if it's the target
    if (node.nodeCount === 1) {
        if (node.name === name) {
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
    if (compareNames(name, right.minName) < 0) {
        const result = _deleteNode(left, name);
        if (result === undefined) {
            // The left child was deleted, promote the right child
            return right;
        }
        newLeft = result;
        nodeDeleted = true;
    } else {
        // Check if the target is in the right subtree
        const result = _deleteNode(right, name);
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
        size: newLeft.size + newRight.size,
        minName: newLeft.minName,
    };
    
    // Rebalance the tree after deletion
    return rebalanceTree(newNode);
}

/**
 * Prunes nodes from a merkle tree by removing all files represented by the given MerkleNode roots.
 * This iterates leaves on each MerkleNode to find file names, then removes those files from the sort tree.
 * 
 * @param merkleTree The merkle tree to prune
 * @param nodesToPrune Array of MerkleNode roots representing subtrees to remove
 * @returns Array of file names that were pruned
 */
export function pruneTree<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>,
    nodesToPrune: MerkleNode[]
): string[] {
    const prunedFiles: string[] = [];
    
    // Iterate leaves on each MerkleNode and remove files from the sort tree
    for (const node of nodesToPrune) {
        for (const leaf of iterateLeaves<MerkleNode>(node)) {
            if (leaf.name) {
                merkleTree.sort = _deleteNode(merkleTree.sort, leaf.name);
                prunedFiles.push(leaf.name);
            }
        }
    }
    
    // Mark the merkle tree as dirty so it will be rebuilt later
    if (prunedFiles.length > 0) {
        merkleTree.dirty = true;
    }
    
    return prunedFiles;
}

/**
 * Completely removes multiple items from the merkle tree by rebuilding the tree without those items.
 * 
 * WARNING: This function is inefficient as it rebuilds the entire tree. Use sparingly.
 * This function is intended for cleanup operations like database upgrades where a complete rebuild is acceptable.
 * 
 * @param merkleTree The merkle tree to remove the items from
 * @param names Array of item names to completely remove
 * @returns number of items that were found and removed
 */
export function deleteItems<DatabaseMetadata>(
    merkleTree: IMerkleTree<DatabaseMetadata>, 
    names: string[]
): number {
    if (!merkleTree || !merkleTree.sort) {
        throw new Error("Cannot delete items from empty or invalid merkle tree");
    }
    
    if (names.length === 0) {
        throw new Error("Cannot delete items: no names provided");
    }
    
    // Create a set for efficient lookup
    const itemsToDelete = new Set(names);
    
    // Get all items from the tree using traversal
    const allItems: HashedItem[] = [];
    const existingItems = new Set<string>();
    
    traverseTreeSync<SortNode>(merkleTree.sort, (node) => {
        if (node.nodeCount === 1 && node.name) {
            existingItems.add(node.name);
            if (node.lastModified) {
                allItems.push({
                    name: node.name,
                    hash: node.contentHash!,
                    length: node.size,
                    lastModified: node.lastModified
                });
            }
        }
        return true;
    });
    
    // Check if any items don't exist
    const nonExistentItems = names.filter(name => !existingItems.has(name));
    if (nonExistentItems.length > 0) {
        throw new Error(`Cannot delete items: the following items do not exist: ${nonExistentItems.join(', ')}`);
    }
    
    let itemsRemoved = 0;
    
    // Get all remaining items (excluding the ones to delete)
    const remainingItems: HashedItem[] = [];
    
    for (const item of allItems) {
        if (itemsToDelete.has(item.name)) {
            itemsRemoved++;
        } else {
            remainingItems.push(item);
        }
    }
    
    // If no items remain, create an empty tree
    if (remainingItems.length === 0) {
        merkleTree.sort = undefined;
        merkleTree.merkle = undefined;
        return itemsRemoved;
    }
    
    // Rebuild the tree with the remaining items
    let newTree = createTree<DatabaseMetadata>(merkleTree.id);
    for (const item of remainingItems) {
        newTree = addItem(newTree, item);
    }
    
    // Replace the tree contents
    merkleTree.sort = newTree.sort;
    merkleTree.merkle = newTree.merkle;
    
    return itemsRemoved;
}