import { addItem, combineHashes, createTree, HashedItem, IMerkleTree, MerkleNode, SortNode } from "../lib/merkle-tree";
import { visualizeSortTree, visualizeMerkleTree } from "../lib/visualize";

/**
 * Helper function to create a file hash with a given name and length
 */
export function createHashedItem(name: string): HashedItem {
    return {
        name,
        hash: Buffer.from(name),
        length: 1,
        lastModified: new Date(),
    };
}

/**
 * Helper function to build a tree with the given file names
 */
export function buildTree(fileNames: string[]): IMerkleTree<any> {
    let merkleTree = createTree<any>("12345678-1234-5678-9abc-123456789abc");
    
    for (const fileName of fileNames) {
        const fileHash = createHashedItem(fileName);
        merkleTree = addItem(merkleTree, fileHash);
    }

    if (!merkleTree) {
        throw new Error('Failed to build the tree');
    }
    
    return merkleTree;
}

/**
 * Helper function to create a leaf node
 */
export function leaf(name: string, size: number = 100): SortNode {
    return {
        contentHash: Buffer.from(name),
        name,
        nodeCount: 1,
        leafCount: 1,
        size,
        minName: name,
    };
}

/**
 * Helper function to create an internal node
 */
export function node(left: SortNode, right: SortNode): SortNode {
    return {
        nodeCount: 1 + left.nodeCount + right.nodeCount,
        leafCount: left.leafCount + right.leafCount,
        size: left.size + right.size,
        minName: left.minName,
        left,
        right,
    };
}

//
// Checks that a node matches the expected structure by recursively walking the binary tree.
//
function _expectNode(node: SortNode, expectedStructure: any): void {
    expect(node).toBeDefined();    

    if (typeof(expectedStructure) === 'string') {
        expect(node.nodeCount).toBe(1);
        expect(node?.name).toEqual(expectedStructure);
        expect(node.contentHash).toBeDefined();
        expect(Buffer.isBuffer(node.contentHash)).toBe(true);
    }
    else {
        if (expectedStructure.name) {
            expect(node.nodeCount).toBe(1);
            expect(node.name).toEqual(expectedStructure.name);
            expect(node.contentHash).toBeDefined();
            expect(Buffer.isBuffer(node.contentHash)).toBe(true);
        }
        else {
            expect(node.nodeCount).toBeGreaterThanOrEqual(3);
        }

        if (expectedStructure.minName) {
            expect(node.minName).toEqual(expectedStructure.minName);
        }
        else if (expectedStructure.name) {
            expect(node.minName).toEqual(expectedStructure.name);
        }
        else if (node.left) {
            expect(node.minName).toEqual(node.left.minName);
        }
    
        if (expectedStructure.left) {
            expect(node.nodeCount).toBeGreaterThanOrEqual(3);
            expect(node.left).toBeDefined();
    
            if (typeof(expectedStructure.left) === 'string') {
                expect(node.left!.name).toEqual(expectedStructure.left);
                expect(node.left!.contentHash).toBeDefined();
                expect(Buffer.isBuffer(node.left!.contentHash)).toBe(true);
                }
            else {
                _expectNode(node.left!, expectedStructure.left);
            }
        }
    
        if (expectedStructure.right) {
            expect(node.nodeCount).toBeGreaterThanOrEqual(3);
            expect(node.right).toBeDefined();
    
            if (typeof(expectedStructure.right) === 'string') {
                expect(node.right!.name).toEqual(expectedStructure.right);
                expect(node.right!.contentHash).toBeDefined();
                expect(Buffer.isBuffer(node.right!.contentHash)).toBe(true);
            }
            else {
                _expectNode(node.right!, expectedStructure.right);
            }
        }
        
        if (!expectedStructure.left && !expectedStructure.right) {
            // Leaf node
            expect(node.nodeCount).toBe(1);
            expect(node.contentHash).toBeDefined();
            expect(Buffer.isBuffer(node.contentHash)).toBe(true);
        }
    }
}

//
// Checks that a node matches the expected structure.
//
export function expectNode(test: string, node: SortNode, expectedStructure: any): void {
    try {
        _expectNode(node, expectedStructure);
    }
    catch (error) {
        console.log(`========================================`);
        console.log(`Test: ${test}`);
        console.log('Actual:');
        console.log(visualizeSortTree(node));

        console.log('Expected:');
        console.log(expectedStructure);
        throw error;
    }
}

//
// Verify the entire tree structure matches the expected structure.
//
export function expectTree(test: string, tree: IMerkleTree<any>, expectedStructure: any): void {
    expectNode(test, tree.sort!, expectedStructure);
}
