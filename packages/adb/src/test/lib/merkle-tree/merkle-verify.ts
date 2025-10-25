import { addFile, combineHashes, createTree, FileHash, IMerkleTree, MerkleNode, SortNode } from "../../../lib/merkle-tree";

/**
 * Helper function to create a file hash with a given name and length
 */
export function createFileHash(fileName: string): FileHash {
    return {
        fileName,
        hash: Buffer.from(fileName),
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
        const fileHash = createFileHash(fileName);
        merkleTree = addFile(merkleTree, fileHash);
    }

    if (!merkleTree) {
        throw new Error('Failed to build the tree');
    }
    
    return merkleTree;
}

/**
 * Helper function to create a leaf node
 */
export function leaf(fileName: string, size: number = 100): SortNode {
    return {
        contentHash: Buffer.from(fileName),
        fileName,
        nodeCount: 1,
        leafCount: 1,
        size,
        minFileName: fileName,
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
        minFileName: left.minFileName,
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
        expect(node?.fileName).toEqual(expectedStructure);
        expect(node.contentHash).toBeDefined();
        expect(Buffer.isBuffer(node.contentHash)).toBe(true);
    }
    else {
        if (expectedStructure.fileName) {
            expect(node.nodeCount).toBe(1);
            expect(node.fileName).toEqual(expectedStructure.fileName);
            expect(node.contentHash).toBeDefined();
            expect(Buffer.isBuffer(node.contentHash)).toBe(true);
        }
        else {
            expect(node.nodeCount).toBeGreaterThanOrEqual(3);
        }

        if (expectedStructure.minFileName) {
            expect(node.minFileName).toEqual(expectedStructure.minFileName);
        }
        else if (expectedStructure.fileName) {
            expect(node.minFileName).toEqual(expectedStructure.fileName);
        }
        else if (node.left) {
            expect(node.minFileName).toEqual(node.left.minFileName);
        }
    
        if (expectedStructure.left) {
            expect(node.nodeCount).toBeGreaterThanOrEqual(3);
            expect(node.left).toBeDefined();
    
            if (typeof(expectedStructure.left) === 'string') {
                expect(node.left!.fileName).toEqual(expectedStructure.left);
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
                expect(node.right!.fileName).toEqual(expectedStructure.right);
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
        console.log(visualizeSortTreeSimple(node));

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

// Helper function to visualize a Merkle tree as simple ASCII art
export function visualizeSortTreeSimple(node: SortNode | undefined, prefix: string = '', isLast: boolean = true): string {
    if (!node) return '';
    
    let result = '';
    const connector = isLast ? '└── ' : '├── ';
    
    result += prefix + connector;

    if (node.nodeCount === 1) {
        if (!node.fileName) {
            throw new Error(`Leaf node has no file name. This could be a bug.`);
        }

        if (!node.contentHash) {
            throw new Error(`Leaf node has no content hash. This could be a bug.`);
        }

        const hashHex = node.contentHash.toString('hex');
        const shortHash = hashHex.substring(0,2) + hashHex.substring(hashHex.length - 2);
    
        // With short hash:
        // result += ' ' + node.minFileName + ' -> ' + shortHash;

        // Just the file name
        // result += ' ' + node.minFileName;

        if (node.fileName.includes("/")) {
            const parts = node.fileName.split("/");
            const lastPart = parts[parts.length - 1];
            result += ' ' + lastPart.substring(0, 2) + lastPart.substring(lastPart.length - 2);
        }
        else {
            result += ' ' + node.minFileName;
        }
    }
    else {
        // With minFileName:
        // result += ' ' + shortHash + ' minFileName = ' + node.minFileName;

        // With the node count:
        result += ' (' + node.nodeCount + ')';

        // Just the hash:
        // result += ' ' + shortHash
    }

    result += '\n';
    
    // Add children
    const newPrefix = prefix + (isLast ? '    ' : '│   ');
    
    if (node.left) {
        result += visualizeSortTreeSimple(node.left, newPrefix, !node.right);
    }
    if (node.right) {
        result += visualizeSortTreeSimple(node.right, newPrefix, true);
    }
    
    return result;
}

// Helper function to visualize a Merkle tree as simple ASCII art
export function visualizeMerkleTreeSimple(node: MerkleNode | undefined, prefix: string = '', isLast: boolean = true): string {
    if (!node) return '';
    
    let result = '';
    const connector = isLast ? '└── ' : '├── ';
    
    const hashHex = node.hash.toString('hex');
    const shortHash = hashHex.substring(0,2) + hashHex.substring(hashHex.length - 2);

    result += prefix + connector;

    if (!node.left && !node.right) {
        // With short hash:
        // result += ' ' + node.minFileName + ' -> ' + shortHash;

        // Just the file name
        // result += ' ' + node.minFileName;

        result += ' ' + shortHash;
    }
    else {
        // With minFileName:
        // result += ' ' + shortHash + ' minFileName = ' + node.minFileName;

        // With the node count:
        result += ' ' + shortHash;

        // Just the hash:
        // result += ' ' + shortHash
    }

    result += '\n';
    
    // Add children
    const newPrefix = prefix + (isLast ? '    ' : '│   ');
    
    if (node.left) {
        result += visualizeMerkleTreeSimple(node.left, newPrefix, !node.right);
    }
    if (node.right) {
        result += visualizeMerkleTreeSimple(node.right, newPrefix, true);
    }
    
    return result;
}