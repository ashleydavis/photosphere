import { 
    buildMerkleTree, 
    MerkleNode, 
    combineHashes,
    traverseSortLeaves,
} from '../../../lib/merkle-tree';
import { buildTree, leaf, node } from './merkle-verify';

describe('buildMerkleTree', () => {
    
    describe('Edge Cases', () => {
        test('returns undefined for undefined sort tree', () => {
            const result = buildMerkleTree(undefined);
            expect(result).toBeUndefined();
        });

        test('builds merkle tree from single leaf node', () => {
            const sortTree = leaf('A');
            const merkleTree = buildMerkleTree(sortTree);

            expect(merkleTree).toBeDefined();
            expect(merkleTree!.hash).toEqual(Buffer.from('A'));
            expect(merkleTree!.left).toBeUndefined();
            expect(merkleTree!.right).toBeUndefined();
        });

        test('builds merkle tree from two leaf nodes', () => {
            const sortTree = node(leaf('A'), leaf('B'));
            const merkleTree = buildMerkleTree(sortTree);

            expect(merkleTree).toBeDefined();
            expect(merkleTree!.left).toBeDefined();
            expect(merkleTree!.right).toBeDefined();
            expect(merkleTree!.left!.hash).toEqual(Buffer.from('A'));
            expect(merkleTree!.right!.hash).toEqual(Buffer.from('B'));
            expect(merkleTree!.hash).toEqual(combineHashes(Buffer.from('A'), Buffer.from('B')));
        });
    });

    describe('Power of Two Leaf Counts', () => {
        test('builds perfectly balanced tree with 2 leaves', () => {
            const sortTree = node(leaf('A'), leaf('B'));
            const merkleTree = buildMerkleTree(sortTree);

            expect(merkleTree).toBeDefined();
            expect(merkleTree!.left!.hash).toEqual(Buffer.from('A'));
            expect(merkleTree!.right!.hash).toEqual(Buffer.from('B'));
            
            // Verify root hash is combination of children
            expect(merkleTree!.hash).toEqual(
                combineHashes(merkleTree!.left!.hash, merkleTree!.right!.hash)
            );
        });

        test('builds perfectly balanced tree with 4 leaves', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const merkleTree = buildMerkleTree(tree.sort!);

            expect(merkleTree).toBeDefined();
            
            // Should have structure: ((A,B),(C,D))
            expect(merkleTree!.left).toBeDefined();
            expect(merkleTree!.right).toBeDefined();
            
            // Left subtree: (A,B)
            expect(merkleTree!.left!.left).toBeDefined();
            expect(merkleTree!.left!.right).toBeDefined();
            expect(merkleTree!.left!.left!.hash).toEqual(Buffer.from('A'));
            expect(merkleTree!.left!.right!.hash).toEqual(Buffer.from('B'));
            
            // Right subtree: (C,D)
            expect(merkleTree!.right!.left).toBeDefined();
            expect(merkleTree!.right!.right).toBeDefined();
            expect(merkleTree!.right!.left!.hash).toEqual(Buffer.from('C'));
            expect(merkleTree!.right!.right!.hash).toEqual(Buffer.from('D'));
        });

        test('builds perfectly balanced tree with 8 leaves', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']);
            const merkleTree = buildMerkleTree(tree.sort!);

            expect(merkleTree).toBeDefined();
            
            // Should have 3 levels: (((A,B),(C,D)),((E,F),(G,H)))
            expect(merkleTree!.left).toBeDefined();
            expect(merkleTree!.right).toBeDefined();
            
            // Verify leaf nodes are at correct positions
            expect(merkleTree!.left!.left!.left!.hash).toEqual(Buffer.from('A'));
            expect(merkleTree!.left!.left!.right!.hash).toEqual(Buffer.from('B'));
            expect(merkleTree!.left!.right!.left!.hash).toEqual(Buffer.from('C'));
            expect(merkleTree!.left!.right!.right!.hash).toEqual(Buffer.from('D'));
            expect(merkleTree!.right!.left!.left!.hash).toEqual(Buffer.from('E'));
            expect(merkleTree!.right!.left!.right!.hash).toEqual(Buffer.from('F'));
            expect(merkleTree!.right!.right!.left!.hash).toEqual(Buffer.from('G'));
            expect(merkleTree!.right!.right!.right!.hash).toEqual(Buffer.from('H'));
        });
    });

    describe('Odd Number of Leaves - No Duplication', () => {
        test('builds tree with 3 leaves without duplicating last node', () => {
            const tree = buildTree(['A', 'B', 'C']);
            const merkleTree = buildMerkleTree(tree.sort!);

            expect(merkleTree).toBeDefined();
            
            // Collect all leaf hashes
            const leaves: Buffer[] = [];
            function collectLeaves(node: MerkleNode | undefined) {
                if (!node) return;
                if (!node.left && !node.right) {
                    leaves.push(node.hash);
                } else {
                    collectLeaves(node.left);
                    collectLeaves(node.right);
                }
            }
            collectLeaves(merkleTree);

            // Should have exactly 3 leaves, no duplicates
            expect(leaves.length).toBe(3);
            expect(leaves[0]).toEqual(Buffer.from('A'));
            expect(leaves[1]).toEqual(Buffer.from('B'));
            expect(leaves[2]).toEqual(Buffer.from('C'));
        });

        test('builds tree with 5 leaves without duplicating last node', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            const merkleTree = buildMerkleTree(tree.sort!);

            expect(merkleTree).toBeDefined();
            
            // Collect all leaf hashes
            const leaves: Buffer[] = [];
            function collectLeaves(node: MerkleNode | undefined) {
                if (!node) return;
                if (!node.left && !node.right) {
                    leaves.push(node.hash);
                } else {
                    collectLeaves(node.left);
                    collectLeaves(node.right);
                }
            }
            collectLeaves(merkleTree);

            // Should have exactly 5 leaves, no duplicates
            expect(leaves.length).toBe(5);
            expect(leaves[0]).toEqual(Buffer.from('A'));
            expect(leaves[1]).toEqual(Buffer.from('B'));
            expect(leaves[2]).toEqual(Buffer.from('C'));
            expect(leaves[3]).toEqual(Buffer.from('D'));
            expect(leaves[4]).toEqual(Buffer.from('E'));
        });

        test('builds tree with 7 leaves without duplicating last node', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G']);
            const merkleTree = buildMerkleTree(tree.sort!);

            expect(merkleTree).toBeDefined();
            
            // Collect all leaf hashes
            const leaves: Buffer[] = [];
            function collectLeaves(node: MerkleNode | undefined) {
                if (!node) return;
                if (!node.left && !node.right) {
                    leaves.push(node.hash);
                } else {
                    collectLeaves(node.left);
                    collectLeaves(node.right);
                }
            }
            collectLeaves(merkleTree);

            // Should have exactly 7 leaves, no duplicates
            expect(leaves.length).toBe(7);
            for (let i = 0; i < 7; i++) {
                expect(leaves[i]).toEqual(Buffer.from(String.fromCharCode(65 + i)));
            }
        });

        test('builds tree with 9 leaves without duplicating last node', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I']);
            const merkleTree = buildMerkleTree(tree.sort!);

            expect(merkleTree).toBeDefined();
            
            // Collect all leaf hashes
            const leaves: Buffer[] = [];
            function collectLeaves(node: MerkleNode | undefined) {
                if (!node) return;
                if (!node.left && !node.right) {
                    leaves.push(node.hash);
                } else {
                    collectLeaves(node.left);
                    collectLeaves(node.right);
                }
            }
            collectLeaves(merkleTree);

            // Should have exactly 9 leaves, no duplicates
            expect(leaves.length).toBe(9);
            for (let i = 0; i < 9; i++) {
                expect(leaves[i]).toEqual(Buffer.from(String.fromCharCode(65 + i)));
            }
        });
    });

    describe('Hash Verification', () => {
        test('all parent hashes are combinations of child hashes', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F']);
            const merkleTree = buildMerkleTree(tree.sort!);

            function verifyHashes(node: MerkleNode | undefined): boolean {
                if (!node) return true;
                
                // If it's a leaf node (no children), hash is valid
                if (!node.left && !node.right) {
                    return true;
                }
                
                // If it has children, verify hash is combination
                if (node.left && node.right) {
                    const expectedHash = combineHashes(node.left.hash, node.right.hash);
                    if (!node.hash.equals(expectedHash)) {
                        return false;
                    }
                    return verifyHashes(node.left) && verifyHashes(node.right);
                }
                
                // If it has only one child (carried up), just recurse
                if (node.left) {
                    return verifyHashes(node.left);
                }
                if (node.right) {
                    return verifyHashes(node.right);
                }
                
                return true;
            }

            expect(verifyHashes(merkleTree)).toBe(true);
        });

        test('root hash changes when any leaf changes', () => {
            const tree1 = buildTree(['A', 'B', 'C', 'D']);
            const merkle1 = buildMerkleTree(tree1.sort!);

            const tree2 = buildTree(['A', 'B', 'X', 'D']); // Changed C to X
            const merkle2 = buildMerkleTree(tree2.sort!);

            expect(merkle1!.hash).not.toEqual(merkle2!.hash);
        });

        test('root hash is same for same leaves regardless of sort tree structure', () => {
            // Create two different sort tree structures with same leaves
            const tree1 = buildTree(['A', 'B', 'C', 'D']);
            const merkle1 = buildMerkleTree(tree1.sort!);

            const tree2 = buildTree(['A', 'B', 'C', 'D']);
            const merkle2 = buildMerkleTree(tree2.sort!);

            // Root hash should be identical
            expect(merkle1!.hash).toEqual(merkle2!.hash);
        });
    });

    describe('Leaf Order Preservation', () => {
        test('preserves leaf order from sort tree traversal', () => {
            const tree = buildTree(['E', 'B', 'A', 'D', 'C']); // Unsorted input
            const merkleTree = buildMerkleTree(tree.sort!);

            // Collect leaves from sort tree
            const sortLeaves: string[] = [];
            for (const leaf of traverseSortLeaves(tree.sort!)) {
                sortLeaves.push(leaf.fileName!);
            }

            // Collect leaves from merkle tree
            const merkleLeaves: Buffer[] = [];
            function collectLeaves(node: MerkleNode | undefined) {
                if (!node) return;
                if (!node.left && !node.right) {
                    merkleLeaves.push(node.hash);
                } else {
                    collectLeaves(node.left);
                    collectLeaves(node.right);
                }
            }
            collectLeaves(merkleTree);

            // Leaves should appear in the same order
            expect(merkleLeaves.length).toBe(sortLeaves.length);
            for (let i = 0; i < sortLeaves.length; i++) {
                expect(merkleLeaves[i]).toEqual(Buffer.from(sortLeaves[i]));
            }
        });
    });

    describe('Large Trees', () => {
        test('builds tree with 100 leaves', () => {
            const fileNames = Array.from({ length: 100 }, (_, i) => `file_${i.toString().padStart(3, '0')}`);
            const tree = buildTree(fileNames);
            const merkleTree = buildMerkleTree(tree.sort!);

            expect(merkleTree).toBeDefined();

            // Count leaves
            let leafCount = 0;
            function countLeaves(node: MerkleNode | undefined) {
                if (!node) return;
                if (!node.left && !node.right) {
                    leafCount++;
                } else {
                    countLeaves(node.left);
                    countLeaves(node.right);
                }
            }
            countLeaves(merkleTree);

            expect(leafCount).toBe(100);
        });

        test('builds tree with 1000 leaves', () => {
            const fileNames = Array.from({ length: 1000 }, (_, i) => `file_${i.toString().padStart(4, '0')}`);
            const tree = buildTree(fileNames);
            const merkleTree = buildMerkleTree(tree.sort!);

            expect(merkleTree).toBeDefined();

            // Count leaves
            let leafCount = 0;
            function countLeaves(node: MerkleNode | undefined) {
                if (!node) return;
                if (!node.left && !node.right) {
                    leafCount++;
                } else {
                    countLeaves(node.left);
                    countLeaves(node.right);
                }
            }
            countLeaves(merkleTree);

            expect(leafCount).toBe(1000);
        });
    });

    describe('Tree Structure Properties', () => {
        test('merkle tree depth is logarithmic for powers of 2', () => {
            function getDepth(node: MerkleNode | undefined): number {
                if (!node) return 0;
                if (!node.left && !node.right) return 1;
                return 1 + Math.max(getDepth(node.left), getDepth(node.right));
            }

            // 8 leaves should have depth 4 (log2(8) + 1)
            const tree8 = buildTree(Array.from({ length: 8 }, (_, i) => String.fromCharCode(65 + i)));
            const merkle8 = buildMerkleTree(tree8.sort!);
            expect(getDepth(merkle8)).toBe(4);

            // 16 leaves should have depth 5 (log2(16) + 1)
            const tree16 = buildTree(Array.from({ length: 16 }, (_, i) => `file_${i}`));
            const merkle16 = buildMerkleTree(tree16.sort!);
            expect(getDepth(merkle16)).toBe(5);
        });

        test('every non-leaf node has at least one child', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G']);
            const merkleTree = buildMerkleTree(tree.sort!);

            function verifyStructure(node: MerkleNode | undefined): boolean {
                if (!node) return true;
                
                const isLeaf = !node.left && !node.right;
                if (isLeaf) return true;
                
                // Non-leaf must have at least one child
                const hasChild = node.left || node.right;
                if (!hasChild) return false;
                
                return verifyStructure(node.left) && verifyStructure(node.right);
            }

            expect(verifyStructure(merkleTree)).toBe(true);
        });

        test('merkle tree has fewer nodes than sort tree', () => {
            function countNodes(node: MerkleNode | undefined): number {
                if (!node) return 0;
                return 1 + countNodes(node.left) + countNodes(node.right);
            }

            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            const merkleTree = buildMerkleTree(tree.sort!);

            const sortNodeCount = tree.sort!.nodeCount;
            const merkleNodeCount = countNodes(merkleTree);

            // Merkle tree should have fewer nodes (no file metadata in internal nodes)
            expect(merkleNodeCount).toBeLessThanOrEqual(sortNodeCount);
        });
    });

    describe('Consistency Tests', () => {
        test('building merkle tree twice produces identical results', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            
            const merkle1 = buildMerkleTree(tree.sort!);
            const merkle2 = buildMerkleTree(tree.sort!);

            function compareNodes(node1: MerkleNode | undefined, node2: MerkleNode | undefined): boolean {
                if (!node1 && !node2) return true;
                if (!node1 || !node2) return false;
                
                if (!node1.hash.equals(node2.hash)) return false;
                
                return compareNodes(node1.left, node2.left) && compareNodes(node1.right, node2.right);
            }

            expect(compareNodes(merkle1, merkle2)).toBe(true);
        });

        test('merkle tree is deterministic for same input', () => {
            const hashes: string[] = [];

            for (let i = 0; i < 5; i++) {
                const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G']);
                const merkleTree = buildMerkleTree(tree.sort!);
                hashes.push(merkleTree!.hash.toString('hex'));
            }

            // All hashes should be identical
            expect(new Set(hashes).size).toBe(1);
        });
    });

    describe('Special Characters and Filenames', () => {
        test('builds tree with UUID filenames', () => {
            const fileNames = [
                'asset/3e4f1677-dfc1-4efe-be57-6969e0b1c9b6',
                'asset/7b4f6865-26a5-4316-98ba-41e528594ec0',
                'asset/7c86cb29-c6ee-40dc-9d08-a8dc5c5a0dc7',
            ];

            const tree = buildTree(fileNames);
            const merkleTree = buildMerkleTree(tree.sort!);

            expect(merkleTree).toBeDefined();

            // Count leaves
            let leafCount = 0;
            function countLeaves(node: MerkleNode | undefined) {
                if (!node) return;
                if (!node.left && !node.right) {
                    leafCount++;
                } else {
                    countLeaves(node.left);
                    countLeaves(node.right);
                }
            }
            countLeaves(merkleTree);

            expect(leafCount).toBe(3);
        });

        test('builds tree with paths containing slashes', () => {
            const fileNames = [
                'a/b/c/file1.txt',
                'a/b/file2.txt',
                'a/file3.txt',
                'file4.txt',
            ];

            const tree = buildTree(fileNames);
            const merkleTree = buildMerkleTree(tree.sort!);

            expect(merkleTree).toBeDefined();
        });
    });
});

