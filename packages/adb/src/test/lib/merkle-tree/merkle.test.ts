import { MerkleNode, FileHash, addFile, updateFile, findFileNode, combineHashes, IMerkleTree, createTree } from '../../../lib/merkle-tree';

describe('Merkle Tree', () => {

    /**
     * Helper function to create a file hash with a given name and length
     */
    function createFileHash(fileName: string): FileHash {
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
    function buildTree(fileNames: string[]): IMerkleTree<any> {
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
     * Helper function to verify a leaf node
     */
    function verifyLeafNode(nodeIndex: number, nodes: MerkleNode[], fileName: string) {
        expect(nodes[nodeIndex].fileName).toEqual(fileName);
        expect(nodes[nodeIndex].hash).toEqual(Buffer.from(fileName));
        expect(nodes[nodeIndex].nodeCount).toBe(1);
    }

    //
    // Verify that a node matches the expected structure by recursively walking the binary tree.
    //
    function verifyNode(node: MerkleNode | undefined, expectedStructure: any) {
        expect(node).toBeDefined();
        if (!node) return;
        
        expect(Buffer.isBuffer(node.hash)).toBe(true);

        if (expectedStructure.fileName) {
            expect(node.nodeCount).toBe(1);
            expect(node.fileName).toEqual(expectedStructure.fileName);
        }

        if (expectedStructure.hash) {
            expect(node.nodeCount).toBe(1);
        }        

        if (expectedStructure.left) {
            expect(node.nodeCount).toBeGreaterThanOrEqual(3);
            expect(node.left).toBeDefined();

            if (typeof(expectedStructure.left) === 'string') {
                expect(node.left!.fileName).toEqual(expectedStructure.left);
                expect(node.left!.hash).toEqual(Buffer.from(expectedStructure.left));
            }
            else {
                verifyNode(node.left, expectedStructure.left);
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
                verifyNode(node.right, expectedStructure.right);
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

    //
    // Verify the entire tree structure matches the expected structure.
    //
    function verifyTree(tree: IMerkleTree<any>, expectedStructure: any) {
        verifyNode(tree.root, expectedStructure);
    }
    
    describe('File Addition', () => {

        // Test 1: Create a tree with a single file
        // Tree before: undefined
        // Tree after: A (single node)
        test('creates a new tree with a single file', () => {
            const fileHash = createFileHash('A');
            const tree = addFile(createTree("12345678-1234-5678-9abc-123456789abc"), fileHash);

            verifyTree(tree, 'A');

            expect(tree.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
            ]);
        });

        // Test 2: Add a second file to an existing tree
        // Tree before: A (single node)
        // Tree after:  
        //    AB (root)
        //    /  \
        //   A    B
        test('adds a second file to an existing tree', () => {
            const fileHashA = createFileHash('A');            
            const treeA = addFile(createTree("12345678-1234-5678-9abc-123456789abc"), fileHashA);

            const fileHashB = createFileHash('B');
            const treeAB = addFile(treeA, fileHashB);

            verifyTree(treeAB, {
                tag: 'AB',
                left: 'A',
                right: 'B',
            });

            expect(treeAB.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
                {
                    fileName: 'B',
                    fileIndex: 1,
                },
            ]);
        });

        // Test 3: Add a third file to an existing tree
        // Tree before:
        //    AB (root)
        //    /  \
        //   A    B
        //
        // Tree after:
        //       ABC (root)
        //      /    \
        //    AB      C
        //   /  \
        //  A    B
        test('adds a third file to an existing tree', () => {
            
            // Build tree with files A and B, then add C.
            const tree = buildTree(['A', 'B']);
            
            // Add C to the tree.
            const fileHashC = createFileHash('C');
            const treeABC = addFile(tree, fileHashC);

            verifyTree(treeABC, {
                tag: 'ABC',
                left: {
                    tag: 'AB',
                    left: 'A',
                    right: 'B',
                },
                right: 'C',
            });

            expect(treeABC.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
                {
                    fileName: 'B',
                    fileIndex: 1,
                },
                {
                    fileName: 'C',
                    fileIndex: 2,
                },
            ]);
        });

        // Test 4: Add a fourth file to an existing tree
        // Tree before:
        //       ABC (root)
        //      /    \
        //    AB      C
        //   /  \
        //  A    B
        //
        // Tree after:
        //        ABCD (root)
        //       /    \
        //     AB      CD
        //    /  \    /  \
        //   A    B  C    D
        test('adds a fourth file to an existing tree (balanced approach)', () => {
            
            // Build tree with A, B, C, then add D.
            const tree = buildTree(['A', 'B', 'C']);
            
            // Add D to the tree.
            const fileHashD = createFileHash('D');
            const treeABCD = addFile(tree, fileHashD);

            verifyTree(treeABCD, {
                tag: 'ABCD',
                left: {
                    tag: 'AB',
                    left: 'A',
                    right: 'B',
                },
                right: {
                    tag: 'CD',
                    left: 'C',
                    right: 'D',
                },
            });

            expect(treeABCD.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
                {
                    fileName: 'B',
                    fileIndex: 1,
                },
                {
                    fileName: 'C',
                    fileIndex: 2,
                },
                {
                    fileName: 'D',
                    fileIndex: 3,
                },
            ]);
        });
        
        // Test 5: Add a fifth file to an existing tree
        // Tree before:
        //        ABCD (root)
        //       /    \
        //     AB      CD
        //    /  \    /  \
        //   A    B  C    D
        //
        // Tree after:
        //          ABCDE (root)
        //         /      \
        //     ABCD        E
        //    /    \
        //   AB    CD
        //  / \    / \
        // A   B  C   D
        test('adds a fifth file to an existing tree (balanced approach)', () => {
            
            // Build tree with A, B, C, and D.
            const tree = buildTree(['A', 'B', 'C', 'D']);
            
            // Add E to the tree.
            const fileHashE = createFileHash('E');
            const treeABCDE = addFile(tree, fileHashE);

            verifyTree(treeABCDE, {
                tag: 'ABCDE',
                left: {
                    tag: 'ABCD',
                    left: {
                        tag: 'AB',
                        left: 'A',
                        right: 'B',
                    },
                    right: {
                        tag: 'CD',
                        left: 'C',
                        right: 'D',
                    },
                },
            });

            expect(treeABCDE.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
                {
                    fileName: 'B',
                    fileIndex: 1,
                },
                {
                    fileName: 'C',
                    fileIndex: 2,
                },
                {
                    fileName: 'D',
                    fileIndex: 3,
                },
                {
                    fileName: 'E',
                    fileIndex: 4,
                },
            ]);
        });
        
        // Test 6: Add a sixth file to an existing tree
        // Tree before:
        //          ABCDE (root)
        //         /      \
        //     ABCD        E
        //    /    \
        //   AB    CD
        //  / \    / \
        // A   B  C   D
        //
        // Tree after:
        //          ABCDEF (root)
        //         /       \
        //     ABCD        EF
        //    /    \      /  \
        //   AB    CD    E    F
        //  / \    / \
        // A   B  C   D
        test('adds a sixth file to an existing tree (balanced approach)', () => {
            
            // Build tree with A through E.
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);

            // Add F to the tree.
            const fileHashF = createFileHash('F');
            const treeABCDEF = addFile(tree, fileHashF);

            verifyTree(treeABCDEF, {
                tag: 'ABCDEF',
                left: {
                    tag: 'ABCD',
                    left: {
                        tag: 'AB',
                        left: 'A',
                        right: 'B',
                    },
                    right: {
                        tag: 'CD',
                        left: 'C',
                        right: 'D',
                    },
                },
                right: {
                    tag: 'EF',
                    left: 'E',
                    right: 'F',
                },
            });

            expect(treeABCDEF.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
                {
                    fileName: 'B',
                    fileIndex: 1,
                },
                {
                    fileName: 'C',
                    fileIndex: 2,
                },
                {
                    fileName: 'D',
                    fileIndex: 3,
                },
                {
                    fileName: 'E',
                    fileIndex: 4,
                },
                {
                    fileName: 'F',
                    fileIndex: 5,
                },
            ]);
        });
        
        // Test 7: Add a seventh file to an existing tree
        // Tree before:
        //          ABCDEF (root)
        //         /       \
        //     ABCD        EF
        //    /    \      /  \
        //   AB    CD    E    F
        //  / \    / \
        // A   B  C   D
        //
        // Tree after:
        //          ABCDEFG (root)
        //         /        \
        //     ABCD         EFG
        //    /    \       /   \
        //   AB    CD     EF    G
        //  / \    / \   / \
        // A   B  C   D E   F
        test('adds a seventh file to an existing tree (balanced approach)', () => {
            
            // Build tree with A through F.
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F']);
            
            // Add G to the tree.
            const fileHashG = createFileHash('G');
            const treeABCDEFG = addFile(tree, fileHashG);

            verifyTree(treeABCDEFG, {
                tag: 'ABCDEFG',
                left: {
                    tag: 'ABCD',
                    left: {
                        tag: 'AB',
                        left: 'A',
                        right: 'B',
                    },
                    right: {
                        tag: 'CD',
                        left: 'C',
                        right: 'D',
                    },
                },
                right: {
                    tag: 'EFG',
                    left: {
                        tag: 'EF',
                        left: 'E',
                        right: 'F',
                    },
                    right: 'G',
                },
            });

            expect(treeABCDEFG.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
                {
                    fileName: 'B',
                    fileIndex: 1,
                },
                {
                    fileName: 'C',
                    fileIndex: 2,
                },
                {
                    fileName: 'D',
                    fileIndex: 3,
                },
                {
                    fileName: 'E',
                    fileIndex: 4,
                },
                {
                    fileName: 'F',
                    fileIndex: 5,
                },
                {
                    fileName: 'G',
                    fileIndex: 6,
                },
            ]);
        });
        
        // Test 8: Add an eighth file to an existing tree
        // Tree before:
        //          ABCDEFG (root)
        //         /        \
        //     ABCD         EFG
        //    /    \       /   \
        //   AB    CD     EF    G
        //  / \    / \   / \
        // A   B  C   D E   F
        //
        // Expected tree after (perfectly balanced):
        //          ABCDEFGH (root)
        //         /        \
        //     ABCD         EFGH
        //    /    \       /    \
        //   AB    CD     EF     GH
        //  / \    / \   / \    / \
        // A   B  C   D E   F  G   H
        //
        // This test will intentionally fail because the actual implementation
        // does not create a perfectly balanced tree for 8 nodes.
        test('adds an eighth file to an existing tree (perfectly balanced)', () => {
            
            // Build tree with A through G
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G']);

            // Add H to the tree.
            const fileHashH = createFileHash('H');
            const treeABCDEFGH = addFile(tree, fileHashH);

            verifyTree(treeABCDEFGH, {
                tag: 'ABCDEFGH',
                left: {
                    tag: 'ABCD',
                    left: {
                        tag: 'AB',
                        left: 'A',
                        right: 'B',
                    },
                    right: {
                        tag: 'CD',
                        left: 'C',
                        right: 'D',
                    },
                },
                right: {
                    tag: 'EFGH',
                    left: {
                        tag: 'EF',
                        left: 'E',
                        right: 'F',
                    },
                    right: {
                        tag: 'GH',
                        left: 'G',
                        right: 'H',
                    },
                },
            });

            expect(treeABCDEFGH.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
                {
                    fileName: 'B',
                    fileIndex: 1,
                },
                {
                    fileName: 'C',
                    fileIndex: 2,
                },
                {
                    fileName: 'D',
                    fileIndex: 3,
                },
                {
                    fileName: 'E',
                    fileIndex: 4,
                },
                {
                    fileName: 'F',
                    fileIndex: 5,
                },
                {
                    fileName: 'G',
                    fileIndex: 6,
                },
                {
                    fileName: 'H',
                    fileIndex: 7,
                },
            ]);
        });
        
        // Test 9: Add a ninth file to an existing tree with a balanced approach
        // Tree before (assuming a balanced 8-node tree):
        //          ABCDEFGH (root)
        //         /        \
        //     ABCD         EFGH
        //    /    \       /    \
        //   AB    CD     EF     GH
        //  / \    / \   / \    / \
        // A   B  C   D E   F  G   H
        //
        // Expected tree after (balanced for 9 nodes):
        //              ABCDEFGHI (root)
        //             /        \
        //          ABCDEFGH     I
        //         /        \
        //     ABCD         EFGH
        //    /    \       /    \
        //   AB    CD     EF     GH
        //  / \    / \   / \    / \
        // A   B  C   D E   F  G   H
        test('adds a ninth file to create a balanced binary merkle tree', () => {
            
            // Build tree with A through H, assuming the implementation gives a balanced tree
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']);

            // Add I to the tree.
            const fileHashI = createFileHash('I');
            const rootABCDEFGHI = addFile(tree, fileHashI);

            verifyTree(rootABCDEFGHI, {
                tag: 'ABCDEFGHI',
                left: {
                    tag: 'ABCDEFGH',
                    left: {
                        tag: 'ABCD',
                        left: {
                            tag: 'AB',
                            left: 'A',
                            right: 'B',
                        },
                        right: {
                            tag: 'CD',
                            left: 'C',
                            right: 'D',
                        },
                    },
                    right: {
                        tag: 'EFGH',
                        left: {
                            tag: 'EF',
                            left: 'E',
                            right: 'F',
                        },
                        right: {
                            tag: 'GH',
                            left: 'G',
                            right: 'H',
                        },
                    },
                },
                right: 'I',
            });

            expect(rootABCDEFGHI.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
                {
                    fileName: 'B',
                    fileIndex: 1,
                },
                {
                    fileName: 'C',
                    fileIndex: 2,
                },
                {
                    fileName: 'D',
                    fileIndex: 3,
                },
                {
                    fileName: 'E',
                    fileIndex: 4,
                },
                {
                    fileName: 'F',
                    fileIndex: 5,
                },
                {
                    fileName: 'G',
                    fileIndex: 6,
                },
                {
                    fileName: 'H',
                    fileIndex: 7,
                },
                {
                    fileName: 'I',
                    fileIndex: 8,
                },
            ]);
        });
        
        // Test 10: Add a tenth file to an existing tree with a balanced approach
        // Tree before:
        //              ABCDEFGHI (root)
        //             /        \
        //          ABCDEFGH     I
        //         /        \
        //     ABCD         EFGH
        //    /    \       /    \
        //   AB    CD     EF     GH
        //  / \    / \   / \    / \
        // A   B  C   D E   F  G   H
        //
        // Expected tree after:
        //              ABCDEFGHIJ (root)
        //             /          \
        //          ABCDEFGH        IJ
        //         /        \      |  \
        //     ABCD         EFGH   I   J
        //    /    \       /    \
        //   AB    CD     EF     GH
        //  / \    / \   / \    / \
        // A   B  C   D E   F  G   H
        test('adds a tenth file to create a balanced binary merkle tree', () => {
            
            // Build tree with A through I
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I']);

            // Add J to the tree.
            const fileHashJ = createFileHash('J');
            const treeABCDEFGHIJ = addFile(tree, fileHashJ);

            verifyTree(treeABCDEFGHIJ, {
                tag: 'ABCDEFGHIJ',
                left: {
                    tag: 'ABCDEFGH',
                    left: {
                        tag: 'ABCD',
                        left: {
                            tag: 'AB',
                            left: 'A',
                            right: 'B',
                        },
                        right: {
                            tag: 'CD',
                            left: 'C',
                            right: 'D',
                        },
                    },
                    right: {
                        tag: 'EFGH',
                        left: {
                            tag: 'EF',
                            left: 'E',
                            right: 'F',
                        },
                        right: {
                            tag: 'GH',
                            left: 'G',
                            right: 'H',
                        },
                    },
                },
                right: {
                    tag: 'IJ',
                    left: 'I',
                    right: 'J',
                },
            });

            expect(treeABCDEFGHIJ.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
                {
                    fileName: 'B',
                    fileIndex: 1,
                },
                {
                    fileName: 'C',
                    fileIndex: 2,
                },
                {
                    fileName: 'D',
                    fileIndex: 3,
                },
                {
                    fileName: 'E',
                    fileIndex: 4,
                },
                {
                    fileName: 'F',
                    fileIndex: 5,
                },
                {
                    fileName: 'G',
                    fileIndex: 6,
                },
                {
                    fileName: 'H',
                    fileIndex: 7,
                },
                {
                    fileName: 'I',
                    fileIndex: 8,
                },
                {
                    fileName: 'J',
                    fileIndex: 9,
                },
            ]);
        });
        
        // Test 11: Add an eleventh file to an existing tree with a balanced approach
        // Tree before:
        //              ABCDEFGHIJ (root)
        //             /          \
        //          ABCDEFGH        IJ
        //         /        \      |  \
        //     ABCD         EFGH   I   J
        //    /    \       /    \
        //   AB    CD     EF     GH
        //  / \    / \   / \    / \
        // A   B  C   D E   F  G   H
        //
        // Expected tree after (balanced for 11 nodes):
        //               ABCDEFGHIJ (root)
        //             /           \
        //          ABCDEFGH         IJK
        //         /        \        |  \
        //     ABCD         EFGH     IJ  K
        //    /    \       /    \    | \
        //   AB    CD     EF     GH  I  J
        //  / \    / \   / \    / \
        // A   B  C   D E   F  G   H
        test('adds an eleventh file to create a balanced binary merkle tree', () => {
            
            // Build tree with A through J
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J']);

            // Add K to the tree.
            const fileHashK = createFileHash('K');
            const treeABCDEFGHIJK = addFile(tree, fileHashK);

            verifyTree(treeABCDEFGHIJK, {
                tag: 'ABCDEFGHIJK',
                left: {
                    tag: 'ABCDEFGH',
                    left: {
                        tag: 'ABCD',
                        left: {
                            tag: 'AB',
                            left: 'A',
                            right: 'B',
                        },
                        right: {
                            tag: 'CD',
                            left: 'C',
                            right: 'D',
                        },
                    },
                    right: {
                        tag: 'EFGH',
                        left: {
                            tag: 'EF',
                            left: 'E',
                            right: 'F',
                        },
                        right: {
                            tag: 'GH',
                            left: 'G',
                            right: 'H',
                        },
                    },
                },
                right: {
                    tag: 'IJK',
                    left: {
                        tag: 'IJ',
                        left: 'I',
                        right: 'J',
                    },
                    right: 'K',
                },
            });

            expect(treeABCDEFGHIJK.sortedNodeRefs).toEqual([
                {
                    fileName: 'A',
                    fileIndex: 0,
                },
                {
                    fileName: 'B',
                    fileIndex: 1,
                },
                {
                    fileName: 'C',
                    fileIndex: 2,
                },
                {
                    fileName: 'D',
                    fileIndex: 3,
                },
                {
                    fileName: 'E',
                    fileIndex: 4,
                },
                {
                    fileName: 'F',
                    fileIndex: 5,
                },
                {
                    fileName: 'G',
                    fileIndex: 6,
                },
                {
                    fileName: 'H',
                    fileIndex: 7,
                },
                {
                    fileName: 'I',
                    fileIndex: 8,
                },
                {
                    fileName: 'J',
                    fileIndex: 9,
                },
                {
                    fileName: 'K',
                    fileIndex: 10,
                },
            ]);
        });
    });
    
    //
    // Adding files out of order.
    //
    // Final tree:  
    //       CADB (root)
    //      /    \
    //    CA      DB
    //   /  \     / \
    //  C    A   D   B
    //
    test('adding files out of order still yields a sorted list', () => {
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");
        tree = addFile(tree, createFileHash('C'));
        tree = addFile(tree, createFileHash('A'));
        tree = addFile(tree, createFileHash('D'));
        tree = addFile(tree, createFileHash('B'));

        expect(tree.sortedNodeRefs).toEqual([
            {
                fileName: 'A',
                fileIndex: 1,
            },
            {
                fileName: 'B',
                fileIndex: 3,
            },
            {
                fileName: 'C',
                fileIndex: 0,
            },
            {
                fileName: 'D',
                fileIndex: 2,
            }
        ]);
    });

    // Update File Tests
    describe('File Update', () => {
        /**
         * Helper function to create a modified file hash with different content
         */
        function createModifiedFileHash(fileName: string, content: string): FileHash {
            return {
                fileName,
                hash: Buffer.from(content),
                length: 200 * fileName.charCodeAt(0), // Different size than original
                lastModified: new Date(),
            };
        }
        
        // Test 1: Find a file node in a tree
        // Tree structure:
        //          ABCDE (root)
        //         /      \
        //     ABCD        E
        //    /    \
        //   AB    CD
        //  / \    / \
        // A   B  C*   D
        //
        // We find node C in this tree to verify its properties
        test('finds a file node by name in the tree', () => {
            // Build a tree with files A through E
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            
            // Find node with file C
            const nodeC = findFileNode(tree, 'C');

            // Verify it's the correct node
            expect(nodeC).toBeDefined();
            expect(nodeC!.hash).toEqual(Buffer.from('C'));
            expect(nodeC!.nodeCount).toBe(1);
        });
        
        // Test 2: Return undefined when file is not found
        // Tree structure:
        //          ABCDE (root)
        //         /      \
        //     ABCD        E
        //    /    \
        //   AB    CD
        //  / \    / \
        // A   B  C   D
        //
        // We search for file "Z" which doesn't exist and expect undefined
        test('returns undefined when file is not found in the tree', () => {
            // Build a tree with files A through E
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            
            // Try to find a non-existent file
            const nodeZ = findFileNode(tree, 'Z');
            
            // Verify it returns undefined
            expect(nodeZ).toBeUndefined();
        });
        
        //
        // Test 3: Update a file in a small tree (Tree with A, B, C)
        //
        // Tree before:
        //       ABC (root)
        //      /    \
        //    AB      C
        //   /  \
        //  A    B    <- B will be updated
        //
        // Tree after:
        //       ABC' (root)      <- hash changed due to B's update
        //      /    \
        //    AB'     C           <- AB's hash changed due to B's update
        //   /  \
        //  A    B'               <- B's hash changed to B' (B_modified)
        //
        test('updates a file in a small tree', () => {
            // Build a tree with files A, B, C
            const tree = buildTree(['A', 'B', 'C']);
            
            // Create modified version of file B
            const modifiedB = createModifiedFileHash('B', 'B_modified');
            
            // Update file B in the tree
            const updated = updateFile(tree, modifiedB);
            expect(updated).toBe(true); // Ensure the update was successful.

            const nodeB = findFileNode(tree, 'B'); // Verify B is still in the tree.
            expect(nodeB).toBeDefined();
            expect(nodeB?.hash).toEqual(modifiedB.hash); // Hash should have been updated.

            // Verify the tree structure on the new hash.
            verifyTree(tree, {
                tag: 'ABC',
                left: {
                    tag: 'AB',
                    left: 'A',
                    right: {
                        fileName: 'B',
                        hash: 'B_modified',
                    },
                },
                right: 'C',
            });         
        });
        
        // Test 4: Update a file in a larger balanced tree
        // Tree before:
        //          ABCDEFG (root)
        //         /        \
        //     ABCD         EFG
        //    /    \       /   \
        //   AB    CD     EF    G
        //  / \    / \   / \
        // A   B  C   D E   F            <- E will be updated
        //
        // Tree after:
        //          ABCDEFG' (root)      <- hash changed due to E's update
        //         /         \
        //     ABCD          EFG'        <- EFG's hash changed due to E's update
        //    /    \        /   \
        //   AB    CD     EF'    G       <- EF's hash changed due to E's update
        //  / \    / \   /  \
        // A   B  C   D E'   F           <- E's hash changed to E' (E_modified)
        //
        test('updates a file in a larger balanced tree', () => {
            // Build a tree with files A through G
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G']);
            
            // Create modified version of file E
            const modifiedE = createModifiedFileHash('E', 'E_modified');
            
            // Update file E in the tree
            const updated = updateFile(tree, modifiedE);
            expect(updated).toBe(true); // Ensure the update was successful.

            const nodeE = findFileNode(tree, 'E'); // Verify E is still in the tree.
            expect(nodeE).toBeDefined();
            expect(nodeE!.hash).toEqual(modifiedE.hash); // Hash should have been updated.

            // Verify the tree structure on the new hash.
            verifyTree(tree, {
                tag: 'ABCDEFG',
                left: {
                    tag: 'ABCD',
                    left: {
                        tag: 'AB',
                        left: 'A',
                        right: 'B',
                    },
                    right: {
                        tag: 'CD',
                        left: 'C',
                        right: 'D',
                    },
                },
                right: {
                    tag: 'EFG',
                    left: {
                        tag: 'EF',
                        left: {
                            fileName: 'E',
                            hash: 'E_modified',
                        },
                        right: 'F',
                    },
                    right: 'G',
                },
            });
        });
        
        // Test 5: Update a file that doesn't exist in the tree (should throw an error)
        // Tree structure:
        //          ABCDE (root)
        //         /      \
        //     ABCD        E
        //    /    \
        //   AB    CD
        //  / \    / \
        // A   B  C   D
        //
        // We attempt to update non-existent file "Z" and expect no update.
        //
        test('expect no update for a non-existent file', () => {
            // Build a tree with files A through E.
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            
            // Create a hash for a file that doesn't exist in the tree.
            const nonExistentFile = createFileHash('Z');
            
            // Attempt to update the non-existent file should throw an error.
            const updated = updateFile(tree, nonExistentFile);

            expect(updated).toBe(false); // Ensure no update was made.
        });
        
        // Test 6: Update a file and verify the entire tree structure remains unchanged
        // Tree before (10 nodes):
        //              ABCDEFGHIJ (root)
        //             /          \
        //          ABCDEFGH        IJ
        //         /        \      |  \
        //     ABCD         EFGH   I   J
        //    /    \       /    \
        //   AB    CD     EF     GH
        //  / \    / \   / \    / \
        // A   B  C   D E   F  G   H
        //            ^
        //            D will be updated
        //
        // Tree after (same structure, only hashes change):
        //              ABCDEFGHIJ' (root)
        //             /           \
        //          ABCDEFGH'        IJ
        //         /         \      |  \
        //     ABCD'         EFGH   I   J
        //    /    \        /    \
        //   AB    CD'     EF     GH
        //  / \    / \    / \    / \
        // A   B  C   D' E   F  G   H
        //            ^
        //            D's hash changed to D' (D_modified)
        //
        test('maintains tree structure after file update', () => {
            // Build a tree with files A through J
            const originalTree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J']);
            
            // Create modified version of file D
            const modifiedD = createModifiedFileHash('D', 'D_modified');
            
            // Update file D in the tree
            const updated = updateFile(originalTree, modifiedD);
            expect(updated).toBe(true); // Ensure the update was successful.

            const nodeD = findFileNode(originalTree, 'D'); // Verify D is still in the tree.
            expect(nodeD).toBeDefined();
            expect(nodeD!.hash).toEqual(modifiedD.hash); // Hash should have been updated.
            expect(nodeD!.nodeCount).toBe(1); // Ensure node count is still 1

            // Verify the tree structure on the new hash.
            verifyTree(originalTree, {
                tag: 'ABCDEFGHIJ',
                left: {
                    tag: 'ABCDEFGH',
                    left: {
                        tag: 'ABCD',
                        left: {
                            tag: 'AB',
                            left: 'A',
                            right: 'B',
                        },
                        right: {
                            tag: 'CD',
                            left: 'C',
                            right: {
                                fileName: 'D',
                                hash: 'D_modified',
                            },
                        },
                    },
                    right: {
                        tag: 'EFGH',
                        left: {
                            tag: 'EF',
                            left: 'E',
                            right: 'F',
                        },
                        right: {
                            tag: 'GH',
                            left: 'G',
                            right: 'H',
                        },
                    },
                },
                right: {
                    tag: 'IJ',
                    left: 'I',
                    right: 'J',
                },
            });
        });
    });
});