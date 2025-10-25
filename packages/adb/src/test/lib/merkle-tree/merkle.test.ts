import { FileHash, addFile, updateFile, findFileNode, createTree } from '../../../lib/merkle-tree';
import { createFileHash, expectTree, buildTree, deserializeTreeFromJSON, serializeTreeToJSON } from './merkle-verify';

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
            expect(nodeC!.hash).toEqual(Buffer.from('C'));
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
            expect(nodeB?.hash).toEqual(modifiedB.hash); // Hash should have been updated.

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
            expect(nodeE!.hash).toEqual(modifiedE.hash); // Hash should have been updated.

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
            expect(nodeD!.hash).toEqual(modifiedD.hash); // Hash should have been updated.
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

            collectLeaves(tree.sortRoot);

            // Verify the leaf nodes are in the same order as added
            expect(leafNodes).toEqual(fileNames);
        });

        test('deserializes JSON and rebuilds tree by walking leaf nodes in order', () => {
            const jsonData = {
                "h": "92e50c7f92bc24a5ab8b118df751d579ee5344e401a6935b0775d1c9bdb21614",
                "l": {
                    "h": "f90884c26c01f31897e884a7fb5aa9f6eb83ca8e634c1027bbe3c386993d2e42",
                    "l": {
                        "h": "91cb875dcbb40f3d0b1b61c2f6a561f4dd42a7cfc0d152ce37b74b70122393d3",
                        "l": {
                            "h": "6b7a3d067c04ec76f5be8d0bbde2a05d13a70ff78155d1701c82243db06dde91",
                            "l": {
                                "h": "010cd8cf32606be62ca2d680c167353a2ee7f95b0890a55048350bd0b8c7de5b",
                                "l": {
                                    "f": "asset/7b4f6865-26a5-4316-98ba-41e528594ec0",
                                    "h": "426fab8dbdd88ead05220e0a73644b1d77c4591689701090926129af8ba45e7c"
                                },
                                "r": {
                                    "f": "asset/76e2090d-e4d2-479a-8cc8-c9b36178eddf",
                                    "h": "ddf59c460a9ff0bcb90cceb02a6b62c3770a4146c611743f8392e3875febd141"
                                }
                            },
                            "r": {
                                "f": "asset/156b235c-602a-46c2-86e2-a019f3a94376",
                                "h": "8dcb3ce7a5459621d9e84899fd8ded1b50e8acb8770a0930b0302f2962889012"
                            }
                        },
                        "r": {
                            "h": "fc03d693763ca3c1b8eba567642db9a12936134207f74837fee42ef6cc2f3867",
                            "l": {
                                "f": "asset/957e5fd7-2249-430b-b7ab-c9f3d6757d9e",
                                "h": "3d9d6f073e60a13e6706bec322b47615f76b594b17bd64495614996b995908d9"
                            },
                            "r": {
                                "f": "asset/86665993-0f16-4a64-8ce3-55ba5c025685",
                                "h": "baa82d130ce3d49905841ae4132b27003ab1c172b3dcbeabc198c59e3b456ab7"
                            }
                        }
                    },
                    "r": {
                        "h": "b509bd0e8a03974265b30d5da6da3036398fc606ee59575ef51a183d8ab25928",
                        "l": {
                            "h": "fda6f77c1a732835e9a64d5e0891646aafbcfde5376e3e0df6700fe15621d579",
                            "l": {
                                "f": "display/7b4f6865-26a5-4316-98ba-41e528594ec0",
                                "h": "8a2205c424a91b8b643a11bc4c12529d56517198fa977243bbf26cfcd1a165d9"
                            },
                            "r": {
                                "f": "display/76e2090d-e4d2-479a-8cc8-c9b36178eddf",
                                "h": "fe3798ff6fecbe72b280f8a0d9624332e75093c90eb2ef639f08d317cbde3044"
                            }
                        },
                        "r": {
                            "h": "6efd01436f874360fbf80d7e87d905f4f06a2f6e6f1e76f3b4781514039f83ff",
                            "l": {
                                "f": "display/957e5fd7-2249-430b-b7ab-c9f3d6757d9e",
                                "h": "ab8a2ae3d82dc4a2fd2ba9f06dd8f38b92e09d6a19c3700e9c2e0b0148a48167"
                            },
                            "r": {
                                "f": "display/86665993-0f16-4a64-8ce3-55ba5c025685",
                                "h": "3498516cc30e3bea6a2c2dbbdfaa9661d32948246f2859309efdea346c2f81dc"
                            }
                        }
                    }
                },
                "r": {
                    "h": "9913bb3b381801fadd0640cac14debbc328eb0f7f9efe007d5bbd061e7a564a6",
                    "l": {
                        "h": "a039fdddad8453876329c839c79bfc6133d3f50473ee31e8235195069799ee57",
                        "l": {
                            "h": "e089e94205e2f28ce8e07730ac147e86ffcaab6b5948a7df9546a63a2f7aee61",
                            "l": {
                                "f": "README.md",
                                "h": "94f27ca43db9c872cfa4a377f3731cb42811e82ec48f2426a541643145a777b7"
                            },
                            "r": {
                                "f": "thumb/7b4f6865-26a5-4316-98ba-41e528594ec0",
                                "h": "9ecd6efc5383fbda3c1125ea06a1311aa6fa9906fb4c8c85362797b8240c36e6"
                            }
                        },
                        "r": {
                            "f": "thumb/76e2090d-e4d2-479a-8cc8-c9b36178eddf",
                            "h": "baf8d77cc5411e2722360c032cd72bcb77dd89695220d014e4cb3d95fd8b8528"
                        }
                    },
                    "r": {
                        "h": "1869f3763a47fe16c078cb333b5f21a6d0edcbf8b47137ee66bcf7d20da7b473",
                        "l": {
                            "f": "thumb/156b235c-602a-46c2-86e2-a019f3a94376",
                            "h": "b2aea11e2a885df25b0c718b52485d546e0fbe5647178ee145c513ba15d80fa6"
                        },
                        "r": {
                            "h": "0c1440da3d6f85b9895bb75c9dbd6371c9b1e08952e59d6751daf4c7cb9b3834",
                            "l": {
                                "f": "thumb/957e5fd7-2249-430b-b7ab-c9f3d6757d9e",
                                "h": "ceffcf6f12bd0d3dca121a8e134e53f02a6b0564ada72324b3da88da7a399f21"
                            },
                            "r": {
                                "f": "thumb/86665993-0f16-4a64-8ce3-55ba5c025685",
                                "h": "9e783b87290f2dd3edaf3a5489ee29fb2d88cf5997468e5bc3759e70a9bdde2f"
                            }
                        }
                    }
                }
            };

            // Deserialize the JSON to a tree structure
            const deserializedTree = deserializeTreeFromJSON(jsonData);

            // Collect all leaf nodes in order from the deserialized tree
            const leafFileHashes: FileHash[] = [];
            function collectLeafHashes(node: any): void {
                if (!node) {
                    return;
                }
                if (node.fileName) {
                    leafFileHashes.push({
                        fileName: node.fileName,
                        hash: node.hash,
                        length: node.size,
                        lastModified: new Date(),
                    });
                }
                else {
                    collectLeafHashes(node.left);
                    collectLeafHashes(node.right);
                }
            }

            collectLeafHashes(deserializedTree);

            // Build a new tree by adding files in the order they appear
            let rebuiltTree = createTree<any>("12345678-1234-5678-9abc-123456789abc");
            for (const fileHash of leafFileHashes) {
                rebuiltTree = addFile(rebuiltTree, fileHash);
            }

            // Collect leaf nodes from the rebuilt tree
            const rebuiltLeafNodes: string[] = [];
            function collectRebuiltLeaves(node: any): void {
                if (!node) {
                    return;
                }
                if (node.fileName) {
                    rebuiltLeafNodes.push(node.fileName);
                }
                else {
                    collectRebuiltLeaves(node.left);
                    collectRebuiltLeaves(node.right);
                }
            }

            collectRebuiltLeaves(rebuiltTree.sortRoot);

            // Collect leaf nodes from the original tree
            const originalLeafNodes: string[] = [];
            function collectOriginalLeaves(node: any): void {
                if (!node) {
                    return;
                }
                if (node.fileName) {
                    originalLeafNodes.push(node.fileName);
                }
                else {
                    collectOriginalLeaves(node.left);
                    collectOriginalLeaves(node.right);
                }
            }

            collectOriginalLeaves(deserializedTree);

            // Verify that the leaf nodes are in the same order
            expect(rebuiltLeafNodes).toEqual(originalLeafNodes);
        });
    });
});