import { addFile, combineHashes, createTree, FileHash, IMerkleTree, MerkleNode } from "../../../lib/merkle-tree";

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
export function leaf(fileName: string, size: number = 100): MerkleNode {
    return {
        hash: Buffer.from(fileName),
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
export function node(left: MerkleNode, right: MerkleNode): MerkleNode {
    return {
        hash: combineHashes(left.hash, right.hash),
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
function _expectNode(node: MerkleNode, expectedStructure: any): void {
    expect(node).toBeDefined();    
    expect(Buffer.isBuffer(node.hash)).toBe(true);

    if (typeof(expectedStructure) === 'string') {
        expect(node.nodeCount).toBe(1);
        expect(node?.fileName).toEqual(expectedStructure);
    }
    else {
        if (expectedStructure.fileName) {
            expect(node.nodeCount).toBe(1);
            expect(node.fileName).toEqual(expectedStructure.fileName);
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
                expect(node.left!.hash).toEqual(Buffer.from(expectedStructure.left));
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
                expect(node.right!.hash).toEqual(Buffer.from(expectedStructure.right));
            }
            else {
                _expectNode(node.right!, expectedStructure.right);
            }
        }
    
        if (expectedStructure.left && expectedStructure.right) {
            // Check that the hash is a combination of the left and right hashes.
            expect(node.hash).toEqual(combineHashes(node.left!.hash, node.right!.hash));
        }
    
        if (!expectedStructure.left && !expectedStructure.right) {
            // Leaf node
            expect(node.nodeCount).toBe(1);
        }
    }
}

//
// Checks that a node matches the expected structure.
//
export function expectNode(test: string, node: MerkleNode, expectedStructure: any): void {
    try {
        _expectNode(node, expectedStructure);
    }
    catch (error) {
        console.log(`========================================`);
        console.log(`Test: ${test}`);
        console.log('Actual:');
        console.log(visualizeTreeSimple(node));

        console.log('Expected:');
        console.log(expectedStructure);
        throw error;
    }
}

//
// Verify the entire tree structure matches the expected structure.
//
export function expectTree(test: string, tree: IMerkleTree<any>, expectedStructure: any): void {
    expectNode(test, tree.root!, expectedStructure);
}

// Helper function to visualize a Merkle tree as simple ASCII art
export function visualizeTreeSimple(node: MerkleNode | undefined, prefix: string = '', isLast: boolean = true): string {
    if (!node) return '';
    
    let result = '';
    const connector = isLast ? '└── ' : '├── ';
    
    const hashHex = node.hash.toString('hex');
    const shortHash = hashHex.substring(0,4) + hashHex.substring(hashHex.length - 4);

    result += prefix + connector;

    if (node.fileName) {
        result += ' ' + node.minFileName + ' -> ' + shortHash;
    }
    else {
        result += ' ' + shortHash; // + ' minFileName = ' + node.minFileName;
    }

    result += '\n';
    
    // Add children
    const newPrefix = prefix + (isLast ? '    ' : '│   ');
    
    if (node.left) {
        result += visualizeTreeSimple(node.left, newPrefix, !node.right);
    }
    if (node.right) {
        result += visualizeTreeSimple(node.right, newPrefix, true);
    }
    
    return result;
}
