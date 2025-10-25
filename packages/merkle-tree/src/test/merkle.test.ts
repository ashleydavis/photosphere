import { FileHash, addFile, updateFile, findFileNode, createTree } from '../lib/merkle-tree';
import { createFileHash, expectTree, buildTree } from './merkle-verify';

describe('Merkle Tree', () => {

    describe('File Addition', () => {

        test('creates a new tree with a single file', () => {
            const fileHash = createFileHash('A');
            const tree = addFile(createTree("12345678-1234-5678-9abc-123456789abc"), fileHash);

            expectTree(expect.getState().currentTestName!, tree, 'A');
        });

        test('adds a second file to an existing tree', () => {
            const fileHashA = createFileHash('A');            
            const treeA = addFile(createTree("12345678-1234-5678-9abc-123456789abc"), fileHashA);

            const fileHashB = createFileHash('B');
            const treeAB = addFile(treeA, fileHashB);

            expectTree(expect.getState().currentTestName!, treeAB, {
                tag: 'AB',
                left: 'A',
                right: 'B',
            });
        });

        test('adds a third file to an existing tree', () => {
            
            // Build tree with files A and B, then add C.
            const tree = buildTree(['A', 'B']);
            
            // Add C to the tree.
            const fileHashC = createFileHash('C');
            const treeABC = addFile(tree, fileHashC);

            expectTree(expect.getState().currentTestName!, treeABC, {
                tag: 'ABC',
                left: {
                    tag: 'AB',
                    left: 'A',
                    right: 'B',
                },
                right: 'C',
            });
        });

        test('adds a fourth file to an existing tree (balanced approach)', () => {
            
            // Build tree with A, B, C, then add D.
            const tree = buildTree(['A', 'B', 'C']);
            
            // Add D to the tree.
            const fileHashD = createFileHash('D');
            const treeABCD = addFile(tree, fileHashD);

            expectTree(expect.getState().currentTestName!, treeABCD, {
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
        });
        
        test('adds a fifth file to an existing tree (balanced approach)', () => {
            
            // Build tree with A, B, C, and D.
            const tree = buildTree(['A', 'B', 'C', 'D']);
            
            // Add E to the tree.
            const fileHashE = createFileHash('E');
            const treeABCDE = addFile(tree, fileHashE);

            expectTree(expect.getState().currentTestName!, treeABCDE, {
                tag: 'ABCDE',
                left: {
                    tag: 'ABC',
                    left: {
                        tag: 'AB',
                        left: 'A',
                        right: 'B',
                    },
                    right: 'C',
                },
                right: {
                    tag: 'DE',
                    left: 'D',
                    right: 'E',
                },
            });
        });
        
        test('adds a sixth file to an existing tree (balanced approach)', () => {
            
            // Build tree with A through E.
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);

            // Add F to the tree.
            const fileHashF = createFileHash('F');
            const treeABCDEF = addFile(tree, fileHashF);

            expectTree(expect.getState().currentTestName!, treeABCDEF, {
                tag: 'ABCDEF',
                left: {
                    tag: 'ABC',
                    left: {
                        tag: 'AB',
                        left: 'A',
                        right: 'B',
                    },
                    right: 'C',
                },
                right: {
                    tag: 'DEF',
                    left: {
                        tag: 'DE',
                        left: 'D',
                        right: 'E',
                    },
                    right: 'F',
                },
            });
        });
        
        test('adds a seventh file to an existing tree (balanced approach)', () => {
            
            // Build tree with A through F.
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F']);
            
            // Add G to the tree.
            const fileHashG = createFileHash('G');
            const treeABCDEFG = addFile(tree, fileHashG);

            expectTree(expect.getState().currentTestName!, treeABCDEFG, {
                tag: 'ABCDEFG',
                left: {
                    tag: 'ABCDE',
                    left: {
                        tag: 'ABC',
                        left: {
                            tag: 'AB',
                            left: 'A',
                            right: 'B',
                        },
                        right: "C",
                    },
                    right: {
                        tag: 'DE',
                        left: 'D',
                        right: 'E',
                    },
                },
                right: {
                    tag: 'FG',
                    left: 'F',
                    right: 'G',
                },
            });
        });
        
        test('adds an eighth file to an existing tree (perfectly balanced)', () => {
            
            // Build tree with A through G
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G']);

            // Add H to the tree.
            const fileHashH = createFileHash('H');
            const treeABCDEFGH = addFile(tree, fileHashH);

            expectTree(expect.getState().currentTestName!, treeABCDEFGH, {
                tag: 'ABCDEFGH',
                left: {
                    tag: 'ABC',
                    left: {
                        tag: 'AB',
                        left: 'A',
                        right: 'B',
                    },
                    right: 'C',
                },
                right: {
                    tag: 'DEFGH',
                    left: {
                        tag: 'DE',
                        left: 'D',
                        right: 'E',
                    },
                    right: {
                        tag: 'FGH',
                        left: {
                            tag: 'FG',
                            left: 'F',
                            right: 'G',
                        },
                        right: 'H',
                    },
                },
            });
        });
        
        test('adds a ninth file to create a balanced binary merkle tree', () => {
            
            // Build tree with A through H, assuming the implementation gives a balanced tree
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']);

            // Add I to the tree.
            const fileHashI = createFileHash('I');
            const rootABCDEFGHI = addFile(tree, fileHashI);

            expectTree(expect.getState().currentTestName!, rootABCDEFGHI, {
                tag: 'ABCDEFGHI',
                left: {
                    tag: 'ABCDE',
                    left: {
                        tag: 'ABC',
                        left: {
                            tag: 'AB',
                            left: 'A',
                            right: 'B',
                        },
                        right: 'C',
                    },
                    right: {
                        tag: 'DE',
                        left: 'D',
                        right: 'E',
                    },
                },
                right: {
                    tag: 'FGHI',
                    left: {
                        tag: 'FG',
                        left: 'F',
                        right: 'G',
                    },
                    right: {
                        tag: 'HI',
                        left: 'H',
                        right: 'I',
                    },
                },
            });
        });
        
        test('adds a tenth file to create a balanced binary merkle tree', () => {
            
            // Build tree with A through I
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I']);

            // Add J to the tree.
            const fileHashJ = createFileHash('J');
            const treeABCDEFGHIJ = addFile(tree, fileHashJ);

            expectTree(expect.getState().currentTestName!, treeABCDEFGHIJ, {
                tag: 'ABCDEFGHIJ',
                left: {
                    tag: 'ABCDE',
                    left: {
                        tag: 'ABC',
                        left: {
                            tag: 'AB',
                            left: 'A',
                            right: 'B',
                        },
                        right: 'C',
                    },
                    right: {
                        tag: 'DE',
                        left: 'D',
                        right: 'E',
                    },
                },
                right: {
                    tag: 'FGHIJ',
                    left: {
                        tag: 'FGH',
                        left: {
                            tag: 'FG',
                            left: 'F',
                            right: 'G',
                        },
                        right: 'H',
                    },
                    right: {
                        tag: 'IJ',
                        left: 'I',
                        right: 'J',
                    },
               },
            });
        });
        
        test('adds an eleventh file to create a balanced binary merkle tree', () => {
            
            // Build tree with A through J
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J']);

            // Add K to the tree.
            const fileHashK = createFileHash('K');
            const treeABCDEFGHIJK = addFile(tree, fileHashK);

            expectTree(expect.getState().currentTestName!, treeABCDEFGHIJK, {
                tag: 'ABCDEFGHIJK',
                left: {
                    tag: 'ABCDEFGH',
                    left: {
                        tag: 'ABCDE',
                        left: {
                            tag: 'ABC',
                            left: {
                                tag: 'AB',
                                left: 'A',
                                right: 'B',
                            },
                            right: 'C',
                        },
                        right: {
                            tag: 'DE',
                            left: 'D',
                            right: 'E',
                        },
                    },
                    right: {
                        tag: 'FGH',
                        left: {
                            tag: 'FG',
                            left: 'F',
                            right: 'G',
                        },
                        right: 'H',
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
        });
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
        
        test('finds a file node by name in the tree', () => {
            // Build a tree with files A through E
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            
            // Find node with file C
            const nodeC = findFileNode(tree, 'C');

            // Verify it's the correct node
            expect(nodeC).toBeDefined();
            expect(nodeC!.contentHash).toEqual(Buffer.from('C'));
            expect(nodeC!.nodeCount).toBe(1);
        });
        
        test('returns undefined when file is not found in the tree', () => {
            // Build a tree with files A through E
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            
            // Try to find a non-existent file
            const nodeZ = findFileNode(tree, 'Z');
            
            // Verify it returns undefined
            expect(nodeZ).toBeUndefined();
        });
        
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
            expect(nodeB?.contentHash).toEqual(modifiedB.hash); // Hash should have been updated.

            // Verify the tree structure on the new hash.
            expectTree(expect.getState().currentTestName!, tree, {
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
            expect(nodeE!.contentHash).toEqual(modifiedE.hash); // Hash should have been updated.

            // Verify the tree structure on the new hash.
            expectTree(expect.getState().currentTestName!, tree, {
                tag: 'ABCDEFG',
                left: {
                    tag: 'ABCDE',
                    left: {
                        tag: 'ABC',
                        left: {
                            tag: 'AB',
                            left: 'A',
                            right: 'B',
                        },
                        right: 'C',
                    },
                    right: {
                        tag: 'DE',
                        left: 'D',
                        right: {
                            fileName: 'E',
                            hash: 'E_modified',
                        },
                    },
                },
                right: {
                    tag: 'FG',
                    left: 'F',
                    right: 'G',
                },
            });
        });
        
        test('expect no update for a non-existent file', () => {
            // Build a tree with files A through E.
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            
            // Create a hash for a file that doesn't exist in the tree.
            const nonExistentFile = createFileHash('Z');
            
            // Attempt to update the non-existent file should throw an error.
            const updated = updateFile(tree, nonExistentFile);

            expect(updated).toBe(false); // Ensure no update was made.
        });
        
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
            expect(nodeD!.contentHash).toEqual(modifiedD.hash); // Hash should have been updated.
            expect(nodeD!.nodeCount).toBe(1); // Ensure node count is still 1

            // Verify the tree structure on the new hash.
            expectTree(expect.getState().currentTestName!, originalTree, {
                tag: 'ABCDEFGHIJ',
                left: {
                    tag: 'ABCDE',
                    left: {
                        tag: 'ABC',
                        left: {
                            tag: 'AB',
                            left: 'A',
                            right: 'B',
                        },
                        right: 'C',
                    },
                    right: {
                        tag: 'DE',
                        left: {
                            fileName: 'D',
                            hash: 'D_modified',
                        },
                        right: 'E',
                    },
                },
                right: {
                    tag: 'FGHIJ',
                    left: {
                        tag: 'FGH',
                        left: {
                            tag: 'FG',
                            left: 'F',
                            right: 'G',
                        },
                        right: 'H',                        
                    },
                    right: {
                        tag: 'IJ',
                        left: 'I',
                        right: 'J',
                    },
                },
            });
        });
    });

    describe('Specific File Order', () => {
        test('adds files with UUIDs and verifies leaf order', () => {
            const fileNames = [
                'asset/3e4f1677-dfc1-4efe-be57-6969e0b1c9b6',
                'asset/7b4f6865-26a5-4316-98ba-41e528594ec0',
                'asset/7c86cb29-c6ee-40dc-9d08-a8dc5c5a0dc7',
                'asset/f7ef0545-219b-4bf0-92e6-62a79c1f24de',
                'asset/fde1d531-1559-472f-9df9-878b7acec068',
            ];

            const tree = buildTree(fileNames);

            // Collect all leaf nodes in order
            const leafNodes: string[] = [];
            function collectLeaves(node: any): void {
                if (!node) {
                    return;
                }
                if (node.fileName) {
                    leafNodes.push(node.fileName);
                }
                else {
                    collectLeaves(node.left);
                    collectLeaves(node.right);
                }
            }

            collectLeaves(tree.sort);

            // Verify the leaf nodes are in the same order as added
            expect(leafNodes).toEqual(fileNames);
        });
    });
});