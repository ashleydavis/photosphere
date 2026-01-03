import * as crypto from 'crypto';
import {
    findDifferingNodes,
    findMerkleTreeDifferences,
    processRemainingNodes
} from '../lib/merkle-diff';
import { BufferMap } from '../lib/buffer-map';
import { MerkleNode, combineHashes } from '../lib/merkle-tree';

// Helper functions for tests
function createLeaf(name: string, content: string = name): MerkleNode {
    return {
        name,
        hash: crypto.createHash("sha256").update(content).digest(),
        nodeCount: 1
    };
}

/**
 * Builds a simple Merkle tree from an array of leaves.
 * This is a helper function for testing.
 */
function buildMerkleTreeFromLeaves(leafs: MerkleNode[]): MerkleNode {
    // Start with the leaf nodes
    let nodes: MerkleNode[] = leafs;

    // Build tree bottom-up
    while (nodes.length > 1) {
        const nextLevel: MerkleNode[] = [];

        for (let i = 0; i < nodes.length; i += 2) {
            const left = nodes[i];
            
            // If there's an odd number of nodes, promote the last one directly
            if (i + 1 >= nodes.length) {
                nextLevel.push(left);
                break;
            }
            
            const right = nodes[i + 1];

            nextLevel.push({
                left,
                right,
                hash: combineHashes(left.hash, right.hash),
                nodeCount: left.nodeCount + right.nodeCount + 1
            });
        }

        nodes = nextLevel;
    }

    return nodes[0];
}


describe('findMerkleTreeDifferences', () => {
    test('should handle empty trees', () => {
        const tree1 = buildMerkleTreeFromLeaves([]);
        const tree2 = buildMerkleTreeFromLeaves([]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(true);
        expect(diff.onlyInTree1).toHaveLength(0);
        expect(diff.onlyInTree2).toHaveLength(0);
    });

    test('should handle empty tree and non-empty tree', () => {
        const tree1 = buildMerkleTreeFromLeaves([]);
        const tree2 = buildMerkleTreeFromLeaves([createLeaf("file1")]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1).toHaveLength(0);
        expect(diff.onlyInTree2).toHaveLength(1);
        expect(diff.onlyInTree2[0].name).toBe("file1");
    });

    test('should handle non-empty tree and empty tree', () => {
        const tree1 = buildMerkleTreeFromLeaves([createLeaf("file1")]);
        const tree2 = buildMerkleTreeFromLeaves([]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1).toHaveLength(1);
        expect(diff.onlyInTree1[0].name).toBe("file1");
        expect(diff.onlyInTree2).toHaveLength(0);
    });

    test('should detect identical trees', () => {
        const leaves = [
            createLeaf("file1"),
            createLeaf("file2"),
            createLeaf("file3")
        ];
        
        const tree1 = buildMerkleTreeFromLeaves(leaves);
        const tree2 = buildMerkleTreeFromLeaves(leaves);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(true);
        expect(diff.onlyInTree1).toHaveLength(0);
        expect(diff.onlyInTree2).toHaveLength(0);
    });
    
    test('should detect single leaf difference', () => {
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2-modified")
        ]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1.length).toBe(1);
        expect(diff.onlyInTree1[0].name).toBe("file2");
        expect(diff.onlyInTree2.length).toBe(1);
        expect(diff.onlyInTree2[0].name).toBe("file2-modified");
    });
    
    test('should detect added file', () => {
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2"),
            createLeaf("file3")
        ]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1.length).toBe(0);
        expect(diff.onlyInTree2.length).toBe(1);
        expect(diff.onlyInTree2[0].name).toBe("file3");
    });
    
    test('should detect removed file', () => {
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2"),
            createLeaf("file3")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2")
        ]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1.length).toBe(1);
        expect(diff.onlyInTree1[0].name).toBe("file3");
        expect(diff.onlyInTree2.length).toBe(0);
    });
    
    test('should handle completely different trees', () => {
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("fileA"),
            createLeaf("fileB")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("fileX"),
            createLeaf("fileY")
        ]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1.length).toBe(2);
        expect(diff.onlyInTree1[0].name).toBe("fileA");
        expect(diff.onlyInTree1[1].name).toBe("fileB");
        expect(diff.onlyInTree2.length).toBe(2);
        expect(diff.onlyInTree2[0].name).toBe("fileX");
        expect(diff.onlyInTree2[1].name).toBe("fileY");
    });
    
    test('should handle single node trees', () => {
        const tree1 = buildMerkleTreeFromLeaves([createLeaf("file1")]);
        const tree2 = buildMerkleTreeFromLeaves([createLeaf("file2")]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1).toHaveLength(1);
        expect(diff.onlyInTree1[0].name).toBe("file1");
        expect(diff.onlyInTree2).toHaveLength(1);
        expect(diff.onlyInTree2[0].name).toBe("file2");
    });
    
    test('should detect multiple changes', () => {
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("file1", "content1"),
            createLeaf("file2", "content2"),
            createLeaf("file3", "content3"),
            createLeaf("file4", "content4")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("file1", "content1-modified"),
            createLeaf("file2", "content2"),
            createLeaf("file3", "content3-modified"),
            createLeaf("file4", "content4")
        ]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1.length).toBe(2);
        expect(diff.onlyInTree1[0].name).toBe("file1");
        expect(diff.onlyInTree1[1].name).toBe("file3");
        expect(diff.onlyInTree2.length).toBe(2);
        expect(diff.onlyInTree2[0].name).toBe("file1");
        expect(diff.onlyInTree2[1].name).toBe("file3");
    });
    
    test('should handle trees with overlapping content', () => {
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2"),
            createLeaf("file3")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("file2"),
            createLeaf("file3"),
            createLeaf("file4")
        ]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1.length).toBe(1);
        expect(diff.onlyInTree1[0].name).toBe("file1");
        expect(diff.onlyInTree2.length).toBe(1);
        expect(diff.onlyInTree2[0].name).toBe("file4");
    });
    
    test('should handle large trees efficiently', () => {
        const leaves1 = Array.from({ length: 1000 }, (_, i) => 
            createLeaf(`file${i}`, `content${i}`)
        );
        
        const leaves2 = Array.from({ length: 1000 }, (_, i) => 
            createLeaf(`file${i}`, i < 50 ? `content${i}` : `modified${i}`)
        );
        
        const tree1 = buildMerkleTreeFromLeaves(leaves1);
        const tree2 = buildMerkleTreeFromLeaves(leaves2);
        
        const startTime = Date.now();
        const diff = findMerkleTreeDifferences(tree1, tree2);
        const endTime = Date.now();
        
        expect(diff.identical).toBe(false);
        expect(endTime - startTime).toBeLessThan(200);
    });
    
    test('should detect changes when trees have different structures but same leaves', () => {
        // This tests the structural awareness of the algorithm
        const leaves1 = [
            createLeaf("a"),
            createLeaf("b"),
            createLeaf("c")
        ];
        
        // Same content but could have different structure due to odd number
        const tree1 = buildMerkleTreeFromLeaves(leaves1);
        const tree2 = buildMerkleTreeFromLeaves([...leaves1]); // Same leaves
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(true); // Same leaves, same order = identical
    });
    
    test('should handle empty overlap', () => {
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("unique1"),
            createLeaf("unique2")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("different1"),
            createLeaf("different2")
        ]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1.length).toBe(2);
        expect(diff.onlyInTree1[0].name).toBe("unique1");
        expect(diff.onlyInTree1[1].name).toBe("unique2");
        expect(diff.onlyInTree2.length).toBe(2);
        expect(diff.onlyInTree2[0].name).toBe("different1");
        expect(diff.onlyInTree2[1].name).toBe("different2");
    });
    
    test('should detect subset relationship', () => {
        const sharedLeaves = [
            createLeaf("file1"),
            createLeaf("file2")
        ];
        
        const tree1 = buildMerkleTreeFromLeaves(sharedLeaves);
        const tree2 = buildMerkleTreeFromLeaves([
            ...sharedLeaves,
            createLeaf("file3"),
            createLeaf("file4")
        ]);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1.length).toBe(0);
        expect(diff.onlyInTree2.length).toBe(2);
        expect(diff.onlyInTree2[0].name).toBe("file3");
        expect(diff.onlyInTree2[1].name).toBe("file4");
    });
    
    test('should handle trees with 7 nodes (complex odd structure)', () => {
        const leaves1 = Array.from({ length: 7 }, (_, i) => createLeaf(`file${i}`));
        const leaves2 = Array.from({ length: 7 }, (_, i) => 
            createLeaf(`file${i}`, i === 3 ? "modified" : `file${i}`)
        );
        
        const tree1 = buildMerkleTreeFromLeaves(leaves1);
        const tree2 = buildMerkleTreeFromLeaves(leaves2);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1.length).toBe(1);
        expect(diff.onlyInTree1[0].name).toBe("file3");
        expect(diff.onlyInTree2.length).toBe(1);
        expect(diff.onlyInTree2[0].name).toBe("file3");
    });

    test('should detect missing files in tree 2 (a1098947 case)', () => {
        // Tree 1: Contains all files including the three a1098947 files
        const tree1Leaves = [
            createLeaf("asset/15cccc63-a628-45c3-9dfb-fcd8c00f6a4b"),
            createLeaf("asset/3171e283-0fe4-4378-8f1a-e364a209ed67"),
            createLeaf("asset/03861e30-e852-4589-96cf-87cd760ff662"),
            createLeaf("asset/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9"),
            createLeaf("asset/a1098947-c6a3-4fe3-abb3-58c6ea951e21"), // Only in tree 1
            createLeaf("asset/ebb4a79f-e991-4934-a164-15f032804e0e"),
            createLeaf("display/3171e283-0fe4-4378-8f1a-e364a209ed67"),
            createLeaf("display/03861e30-e852-4589-96cf-87cd760ff662"),
            createLeaf("display/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9"),
            createLeaf("display/a1098947-c6a3-4fe3-abb3-58c6ea951e21"), // Only in tree 1
            createLeaf("display/ebb4a79f-e991-4934-a164-15f032804e0e"),
            createLeaf("README.md"),
            createLeaf("thumb/15cccc63-a628-45c3-9dfb-fcd8c00f6a4b"),
            createLeaf("thumb/3171e283-0fe4-4378-8f1a-e364a209ed67"),
            createLeaf("thumb/03861e30-e852-4589-96cf-87cd760ff662"),
            createLeaf("thumb/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9"),
            createLeaf("thumb/a1098947-c6a3-4fe3-abb3-58c6ea951e21"), // Only in tree 1
            createLeaf("thumb/ebb4a79f-e991-4934-a164-15f032804e0e"),
        ];

        // Tree 2: Missing the three a1098947 files
        const tree2Leaves = [
            createLeaf("asset/15cccc63-a628-45c3-9dfb-fcd8c00f6a4b"),
            createLeaf("asset/3171e283-0fe4-4378-8f1a-e364a209ed67"),
            createLeaf("asset/03861e30-e852-4589-96cf-87cd760ff662"),
            createLeaf("asset/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9"),
            // asset/a1098947 is missing
            createLeaf("asset/ebb4a79f-e991-4934-a164-15f032804e0e"),
            createLeaf("display/3171e283-0fe4-4378-8f1a-e364a209ed67"),
            createLeaf("display/03861e30-e852-4589-96cf-87cd760ff662"),
            createLeaf("display/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9"),
            // display/a1098947 is missing
            createLeaf("display/ebb4a79f-e991-4934-a164-15f032804e0e"),
            createLeaf("README.md"),
            createLeaf("thumb/15cccc63-a628-45c3-9dfb-fcd8c00f6a4b"),
            createLeaf("thumb/3171e283-0fe4-4378-8f1a-e364a209ed67"),
            createLeaf("thumb/03861e30-e852-4589-96cf-87cd760ff662"),
            createLeaf("thumb/6677d1a7-514e-42dc-8b77-2c0fd4ab80e9"),
            // thumb/a1098947 is missing
            createLeaf("thumb/ebb4a79f-e991-4934-a164-15f032804e0e"),
        ];

        const tree1 = buildMerkleTreeFromLeaves(tree1Leaves);
        const tree2 = buildMerkleTreeFromLeaves(tree2Leaves);

        const diff = findMerkleTreeDifferences(tree1, tree2);

        expect(diff.identical).toBe(false);
        
        // Extract leaf names from the diff results
        const onlyInTree1Names = diff.onlyInTree1
            .map(node => {
                // If it's a leaf, return its name
                if (node.name && !node.left && !node.right) {
                    return node.name;
                }
                // If it's an internal node, recursively extract leaf names
                const names: string[] = [];
                const extract = (n: MerkleNode) => {
                    if (n.name && !n.left && !n.right) {
                        names.push(n.name);
                    } else {
                        if (n.left) extract(n.left);
                        if (n.right) extract(n.right);
                    }
                };
                extract(node);
                return names;
            })
            .flat()
            .sort();

        expect(onlyInTree1Names).toEqual([
            "asset/a1098947-c6a3-4fe3-abb3-58c6ea951e21",
            "display/a1098947-c6a3-4fe3-abb3-58c6ea951e21",
            "thumb/a1098947-c6a3-4fe3-abb3-58c6ea951e21",
        ]);

        expect(diff.onlyInTree2).toHaveLength(0);
    });    
});

describe('findDifferingNodes (one-way diff)', () => {
    test('should return empty array for identical trees', () => {
        const leaves = [createLeaf("file1"), createLeaf("file2")];
        const tree1 = buildMerkleTreeFromLeaves(leaves);
        const tree2 = buildMerkleTreeFromLeaves(leaves);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        expect(diff).toHaveLength(0);
    });
    
    test('should find nodes unique to tree A', () => {
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2"),
            createLeaf("file3")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2")
        ]);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        expect(diff.length).toBe(1);
        expect(diff[0].name).toBe("file3");
    });
    
    test('should not find nodes when tree A is subset of tree B', () => {
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2"),
            createLeaf("file3")
        ]);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        // If all of tree1's content is in tree2, should be empty
        // (though structure might differ)
        expect(diff).toHaveLength(0);
    });

    test('should handle when queueB becomes empty first (treeB exhausted)', () => {
        // TreeA has more nodes than treeB
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2"),
            createLeaf("file3"),
            createLeaf("file4")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("file1")
        ]);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        // Should return remaining nodes from tree1 (file2, file3, file4)
        // Internal nodes are expanded to check individual leaves for duplicate detection
        const diffNames = diff
            .map(node => {
                if (node.name && !node.left && !node.right) {
                    return node.name;
                }
                const names: string[] = [];
                const extract = (n: MerkleNode) => {
                    if (n.name && !n.left && !n.right) {
                        names.push(n.name);
                    }
                    else {
                        if (n.left) extract(n.left);
                        if (n.right) extract(n.right);
                    }
                };
                extract(node);
                return names;
            })
            .flat()
            .sort();
        
        expect(diffNames).toEqual(["file2", "file3", "file4"]);
    });

    test('should handle when queueA becomes empty first (treeA exhausted)', () => {
        // TreeA has fewer nodes than treeB
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("file1")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("file1"),
            createLeaf("file2"),
            createLeaf("file3")
        ]);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        // If all of tree1 is in tree2, should return empty
        expect(diff).toHaveLength(0);
    });

    test('should skip identical subtrees via hash matching', () => {
        // Create trees where some subtrees are identical (should skip them)
        const sharedLeaf = createLeaf("shared");
        const tree1 = buildMerkleTreeFromLeaves([
            sharedLeaf,
            createLeaf("unique1")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            sharedLeaf,
            createLeaf("unique2")
        ]);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        // Should find unique1 but skip the shared subtree
        expect(diff.length).toBe(1);
        expect(diff[0].name).toBe("unique1");
    });

    test('should handle leaf node requeueing when hash not found initially', () => {
        // Single leaf nodes that differ
        const tree1 = buildMerkleTreeFromLeaves([createLeaf("file1")]);
        const tree2 = buildMerkleTreeFromLeaves([createLeaf("file2")]);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        // Leaf should be requeued and eventually returned
        expect(diff.length).toBe(1);
        expect(diff[0].name).toBe("file1");
    });

    test('should throw error for invalid tree structure - nodeA with left but no right', () => {
        const leftLeaf = createLeaf("left");
        const invalidNode: MerkleNode = {
            hash: crypto.createHash("sha256").update("invalid").digest(),
            nodeCount: 2,
            left: leftLeaf,
            right: undefined // Missing right child
        };
        
        const validTree = buildMerkleTreeFromLeaves([createLeaf("file1")]);
        
        expect(() => findDifferingNodes(invalidNode, validTree)).toThrow(
            'Invalid tree structure: nodeA has a left child but no right child'
        );
    });

    test('should throw error for invalid tree structure - nodeA with right but no left', () => {
        const rightLeaf = createLeaf("right");
        const invalidNode: MerkleNode = {
            hash: crypto.createHash("sha256").update("invalid").digest(),
            nodeCount: 2,
            left: undefined, // Missing left child
            right: rightLeaf
        };
        
        const validTree = buildMerkleTreeFromLeaves([createLeaf("file1")]);
        
        expect(() => findDifferingNodes(invalidNode, validTree)).toThrow(
            'Invalid tree structure: nodeA has a right child but no left child'
        );
    });

    test('should throw error for invalid tree structure - nodeB with left but no right', () => {
        const validTree = buildMerkleTreeFromLeaves([createLeaf("file1")]);
        const leftLeaf = createLeaf("left");
        const invalidNode: MerkleNode = {
            hash: crypto.createHash("sha256").update("invalid").digest(),
            nodeCount: 2,
            left: leftLeaf,
            right: undefined // Missing right child
        };
        
        expect(() => findDifferingNodes(validTree, invalidNode)).toThrow(
            'Invalid tree structure: nodeB has a left child but no right child'
        );
    });

    test('should throw error for invalid tree structure - nodeB with right but no left', () => {
        const validTree = buildMerkleTreeFromLeaves([createLeaf("file1")]);
        const rightLeaf = createLeaf("right");
        const invalidNode: MerkleNode = {
            hash: crypto.createHash("sha256").update("invalid").digest(),
            nodeCount: 2,
            left: undefined, // Missing left child
            right: rightLeaf
        };
        
        expect(() => findDifferingNodes(validTree, invalidNode)).toThrow(
            'Invalid tree structure: nodeB has a right child but no left child'
        );
    });

    test('should handle deep trees with multiple levels', () => {
        // Create deep trees to test multi-level traversal
        const tree1 = buildMerkleTreeFromLeaves([
            createLeaf("a"),
            createLeaf("b"),
            createLeaf("c"),
            createLeaf("d"),
            createLeaf("e"),
            createLeaf("f"),
            createLeaf("g"),
            createLeaf("h")
        ]);
        
        const tree2 = buildMerkleTreeFromLeaves([
            createLeaf("a"),
            createLeaf("b"),
            createLeaf("c"),
            createLeaf("d"),
            createLeaf("e"),
            createLeaf("f"),
            createLeaf("g"),
            createLeaf("x") // Different last leaf
        ]);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        // Should return the differing node containing "h"
        expect(diff.length).toBe(1);
        expect(diff[0].name).toBe("h");
    });

    test('should handle internal nodes with matching hashes', () => {
        // Create trees where internal nodes match (subtree pruning)
        const leaf1 = createLeaf("file1");
        const leaf2 = createLeaf("file2");
        const leaf3 = createLeaf("file3");
        
        // Tree1: (file1, file2), file3
        const tree1 = buildMerkleTreeFromLeaves([leaf1, leaf2, leaf3]);
        
        // Tree2: (file1, file2), file4 (shared subtree should match)
        const tree2 = buildMerkleTreeFromLeaves([leaf1, leaf2, createLeaf("file4")]);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        // Should skip the (file1, file2) subtree and only return file3 node
        expect(diff.length).toBe(1);
        expect(diff[0].name).toBe("file3");
    });
});

describe('findDifferingNodes with duplicate files (same hash)', () => {
    test('should correctly identify identical trees when both have duplicate files with same hash', () => {
        // Create two files with the same content (same hash)
        const duplicateContent = "same content";
        
        // Tree 1: Has two files with the same hash
        const tree1Leaves = [
            createLeaf("file1", duplicateContent), // Same hash
            createLeaf("file2", duplicateContent), // Same hash
            createLeaf("file3", "different content")
        ];
        
        // Tree 2: Copy of Tree 1 (should be identical)
        const tree2Leaves = [
            createLeaf("file1", duplicateContent), // Same hash
            createLeaf("file2", duplicateContent), // Same hash
            createLeaf("file3", "different content")
        ];
        
        const tree1 = buildMerkleTreeFromLeaves(tree1Leaves);
        const tree2 = buildMerkleTreeFromLeaves(tree2Leaves);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        // The trees should be identical since they have the same files
        expect(diff.identical).toBe(true);
        expect(diff.onlyInTree1).toHaveLength(0);
        expect(diff.onlyInTree2).toHaveLength(0);
    });
    
    test('should correctly handle when tree1 has 2 duplicates and tree2 has 1 duplicate', () => {
        // Create files with the same content (same hash)
        const duplicateContent = "same content";
        
        // Tree 1: Has two files with the same hash
        const tree1Leaves = [
            createLeaf("file1", duplicateContent), // Same hash
            createLeaf("file2", duplicateContent), // Same hash
            createLeaf("file3", "other content")
        ];
        
        // Tree 2: Has only one file with that hash
        const tree2Leaves = [
            createLeaf("file1", duplicateContent), // Same hash
            createLeaf("file3", "other content")
        ];
        
        const tree1 = buildMerkleTreeFromLeaves(tree1Leaves);
        const tree2 = buildMerkleTreeFromLeaves(tree2Leaves);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        // Tree 1 should have one extra file (file2) that tree2 doesn't have
        expect(diff.identical).toBe(false);
        
        // Extract leaf names from the diff results
        const onlyInTree1Names = diff.onlyInTree1
            .map(node => {
                if (node.name && !node.left && !node.right) {
                    return node.name;
                }
                const names: string[] = [];
                const extract = (n: MerkleNode) => {
                    if (n.name && !n.left && !n.right) {
                        names.push(n.name);
                    }
                    else {
                        if (n.left) extract(n.left);
                        if (n.right) extract(n.right);
                    }
                };
                extract(node);
                return names;
            })
            .flat()
            .sort();
        
        // Should detect that file2 is only in tree1
        expect(onlyInTree1Names).toContain("file2");
        expect(diff.onlyInTree2).toHaveLength(0);
    });
    
    test('should correctly handle when tree1 has 1 duplicate and tree2 has 2 duplicates', () => {
        // Create files with the same content (same hash)
        const duplicateContent = "same content";
        
        // Tree 1: Has one file with the duplicate hash
        const tree1Leaves = [
            createLeaf("file1", duplicateContent), // Same hash
            createLeaf("file3", "other content")
        ];
        
        // Tree 2: Has two files with that hash
        const tree2Leaves = [
            createLeaf("file1", duplicateContent), // Same hash
            createLeaf("file2", duplicateContent), // Same hash
            createLeaf("file3", "other content")
        ];
        
        const tree1 = buildMerkleTreeFromLeaves(tree1Leaves);
        const tree2 = buildMerkleTreeFromLeaves(tree2Leaves);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        // Tree 2 should have one extra file (file2) that tree1 doesn't have
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1).toHaveLength(0);
        
        // Extract leaf names from the diff results
        const onlyInTree2Names = diff.onlyInTree2
            .map(node => {
                if (node.name && !node.left && !node.right) {
                    return node.name;
                }
                const names: string[] = [];
                const extract = (n: MerkleNode) => {
                    if (n.name && !n.left && !n.right) {
                        names.push(n.name);
                    }
                    else {
                        if (n.left) extract(n.left);
                        if (n.right) extract(n.right);
                    }
                };
                extract(node);
                return names;
            })
            .flat()
            .sort();
        
        // Should detect that file2 is only in tree2
        expect(onlyInTree2Names).toContain("file2");
    });
    
    test('should correctly handle two sets of duplicate files', () => {
        // Create two sets of duplicate files
        const duplicateContentA = "content A";
        const duplicateContentB = "content B";
        
        // Tree 1: Has two files with content A, and two files with content B
        const tree1Leaves = [
            createLeaf("file1", duplicateContentA), // Set A, duplicate 1
            createLeaf("file2", duplicateContentA), // Set A, duplicate 2
            createLeaf("file3", duplicateContentB), // Set B, duplicate 1
            createLeaf("file4", duplicateContentB), // Set B, duplicate 2
            createLeaf("file5", "unique content")
        ];
        
        // Tree 2: Has one file with content A, and one file with content B
        const tree2Leaves = [
            createLeaf("file1", duplicateContentA), // Set A, only one
            createLeaf("file3", duplicateContentB), // Set B, only one
            createLeaf("file5", "unique content")
        ];
        
        const tree1 = buildMerkleTreeFromLeaves(tree1Leaves);
        const tree2 = buildMerkleTreeFromLeaves(tree2Leaves);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        // Tree 1 should have file2 and file4 that tree2 doesn't have
        expect(diff.identical).toBe(false);
        
        // Extract leaf names from the diff results
        const onlyInTree1Names = diff.onlyInTree1
            .map(node => {
                if (node.name && !node.left && !node.right) {
                    return node.name;
                }
                const names: string[] = [];
                const extract = (n: MerkleNode) => {
                    if (n.name && !n.left && !n.right) {
                        names.push(n.name);
                    }
                    else {
                        if (n.left) extract(n.left);
                        if (n.right) extract(n.right);
                    }
                };
                extract(node);
                return names;
            })
            .flat()
            .sort();
        
        // Should detect that file2 and file4 are only in tree1
        expect(onlyInTree1Names).toContain("file2");
        expect(onlyInTree1Names).toContain("file4");
        expect(diff.onlyInTree2).toHaveLength(0);
    });
    
    test('should correctly handle two sets of duplicate files - reverse case', () => {
        // Create two sets of duplicate files
        const duplicateContentA = "content A";
        const duplicateContentB = "content B";
        
        // Tree 1: Has one file with content A, and one file with content B
        const tree1Leaves = [
            createLeaf("file1", duplicateContentA), // Set A, only one
            createLeaf("file3", duplicateContentB), // Set B, only one
            createLeaf("file5", "unique content")
        ];
        
        // Tree 2: Has two files with content A, and two files with content B
        const tree2Leaves = [
            createLeaf("file1", duplicateContentA), // Set A, duplicate 1
            createLeaf("file2", duplicateContentA), // Set A, duplicate 2
            createLeaf("file3", duplicateContentB), // Set B, duplicate 1
            createLeaf("file4", duplicateContentB), // Set B, duplicate 2
            createLeaf("file5", "unique content")
        ];
        
        const tree1 = buildMerkleTreeFromLeaves(tree1Leaves);
        const tree2 = buildMerkleTreeFromLeaves(tree2Leaves);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        // Tree 2 should have file2 and file4 that tree1 doesn't have
        expect(diff.identical).toBe(false);
        expect(diff.onlyInTree1).toHaveLength(0);
        
        // Extract leaf names from the diff results
        const onlyInTree2Names = diff.onlyInTree2
            .map(node => {
                if (node.name && !node.left && !node.right) {
                    return node.name;
                }
                const names: string[] = [];
                const extract = (n: MerkleNode) => {
                    if (n.name && !n.left && !n.right) {
                        names.push(n.name);
                    }
                    else {
                        if (n.left) extract(n.left);
                        if (n.right) extract(n.right);
                    }
                };
                extract(node);
                return names;
            })
            .flat()
            .sort();
        
        // Should detect that file2 and file4 are only in tree2
        expect(onlyInTree2Names).toContain("file2");
        expect(onlyInTree2Names).toContain("file4");
    });
    
    test('should correctly handle mixed duplicate scenarios', () => {
        // Create multiple sets of duplicate files with different counts
        const duplicateContentA = "content A";
        const duplicateContentB = "content B";
        const duplicateContentC = "content C";
        
        // Tree 1: Has 2x A, 1x B, 3x C
        const tree1Leaves = [
            createLeaf("file1", duplicateContentA), // Set A, duplicate 1
            createLeaf("file2", duplicateContentA), // Set A, duplicate 2
            createLeaf("file3", duplicateContentB), // Set B, only one
            createLeaf("file4", duplicateContentC), // Set C, duplicate 1
            createLeaf("file5", duplicateContentC), // Set C, duplicate 2
            createLeaf("file6", duplicateContentC), // Set C, duplicate 3
        ];
        
        // Tree 2: Has 1x A, 2x B, 2x C
        const tree2Leaves = [
            createLeaf("file1", duplicateContentA), // Set A, only one
            createLeaf("file3", duplicateContentB), // Set B, duplicate 1
            createLeaf("file7", duplicateContentB), // Set B, duplicate 2
            createLeaf("file4", duplicateContentC), // Set C, duplicate 1
            createLeaf("file5", duplicateContentC), // Set C, duplicate 2
        ];
        
        const tree1 = buildMerkleTreeFromLeaves(tree1Leaves);
        const tree2 = buildMerkleTreeFromLeaves(tree2Leaves);
        
        const diff = findMerkleTreeDifferences(tree1, tree2);
        
        expect(diff.identical).toBe(false);
        
        // Extract leaf names from the diff results
        const onlyInTree1Names = diff.onlyInTree1
            .map(node => {
                if (node.name && !node.left && !node.right) {
                    return node.name;
                }
                const names: string[] = [];
                const extract = (n: MerkleNode) => {
                    if (n.name && !n.left && !n.right) {
                        names.push(n.name);
                    }
                    else {
                        if (n.left) extract(n.left);
                        if (n.right) extract(n.right);
                    }
                };
                extract(node);
                return names;
            })
            .flat()
            .sort();
        
        const onlyInTree2Names = diff.onlyInTree2
            .map(node => {
                if (node.name && !node.left && !node.right) {
                    return node.name;
                }
                const names: string[] = [];
                const extract = (n: MerkleNode) => {
                    if (n.name && !n.left && !n.right) {
                        names.push(n.name);
                    }
                    else {
                        if (n.left) extract(n.left);
                        if (n.right) extract(n.right);
                    }
                };
                extract(node);
                return names;
            })
            .flat()
            .sort();
        
        // Tree1 should have: file2 (extra A), file6 (extra C)
        expect(onlyInTree1Names).toContain("file2");
        expect(onlyInTree1Names).toContain("file6");
        
        // Tree2 should have: file7 (extra B)
        expect(onlyInTree2Names).toContain("file7");
    });
});

describe('processRemainingNodes', () => {
    test('should handle empty nodes array', () => {
        const mapB = new BufferMap<number>();
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([], mapB, onlyInTree1);
        
        expect(onlyInTree1).toHaveLength(0);
    });

    test('should add leaf node when hash not in map', () => {
        const leaf = createLeaf("file1");
        const mapB = new BufferMap<number>();
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([leaf], mapB, onlyInTree1);
        
        expect(onlyInTree1).toHaveLength(1);
        expect(onlyInTree1[0]).toBe(leaf);
    });

    test('should add leaf node when count is zero', () => {
        const leaf = createLeaf("file1");
        const mapB = new BufferMap<number>();
        mapB.set(leaf.hash, 0); // Count is zero
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([leaf], mapB, onlyInTree1);
        
        expect(onlyInTree1).toHaveLength(1);
        expect(onlyInTree1[0]).toBe(leaf);
        expect(mapB.get(leaf.hash)).toBe(0); // Count remains zero
    });

    test('should decrement count and not add leaf when hash matches', () => {
        const leaf = createLeaf("file1");
        const mapB = new BufferMap<number>();
        mapB.set(leaf.hash, 2); // Count is 2
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([leaf], mapB, onlyInTree1);
        
        expect(onlyInTree1).toHaveLength(0);
        expect(mapB.get(leaf.hash)).toBe(1); // Count decremented
    });

    test('should handle multiple leaf nodes with same hash (duplicates)', () => {
        const duplicateContent = "same content";
        const leaf1 = createLeaf("file1", duplicateContent);
        const leaf2 = createLeaf("file2", duplicateContent); // Same hash as leaf1
        const mapB = new BufferMap<number>();
        mapB.set(leaf1.hash, 2); // Two matches available
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([leaf1, leaf2], mapB, onlyInTree1);
        
        // Both should match and decrement count
        expect(onlyInTree1).toHaveLength(0);
        expect(mapB.get(leaf1.hash)).toBe(0); // Both matched
    });

    test('should handle leaf nodes with partial duplicates', () => {
        const duplicateContent = "same content";
        const leaf1 = createLeaf("file1", duplicateContent);
        const leaf2 = createLeaf("file2", duplicateContent); // Same hash
        const leaf3 = createLeaf("file3", duplicateContent); // Same hash
        const mapB = new BufferMap<number>();
        mapB.set(leaf1.hash, 2); // Only 2 matches available
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([leaf1, leaf2, leaf3], mapB, onlyInTree1);
        
        // First two should match, third should be added
        expect(onlyInTree1).toHaveLength(1);
        expect(onlyInTree1[0]).toBe(leaf3);
        expect(mapB.get(leaf1.hash)).toBe(0); // Both matches used
    });

    test('should skip internal node when hash matches', () => {
        const leaf1 = createLeaf("file1");
        const leaf2 = createLeaf("file2");
        const internal = {
            left: leaf1,
            right: leaf2,
            hash: combineHashes(leaf1.hash, leaf2.hash),
            nodeCount: 3
        };
        const mapB = new BufferMap<number>();
        mapB.set(internal.hash, 1); // Internal node hash matches
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([internal], mapB, onlyInTree1);
        
        // Should skip children and not add anything
        expect(onlyInTree1).toHaveLength(0);
        expect(mapB.get(internal.hash)).toBe(0); // Count decremented
    });

    test('should expand internal node when hash does not match', () => {
        const leaf1 = createLeaf("file1");
        const leaf2 = createLeaf("file2");
        const internal = {
            left: leaf1,
            right: leaf2,
            hash: combineHashes(leaf1.hash, leaf2.hash),
            nodeCount: 3
        };
        const mapB = new BufferMap<number>();
        // Internal hash not in map, but leaf1 is
        mapB.set(leaf1.hash, 1);
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([internal], mapB, onlyInTree1);
        
        // Should expand and check children
        // leaf1 matches, leaf2 doesn't
        expect(onlyInTree1).toHaveLength(1);
        expect(onlyInTree1[0].name).toBe("file2");
        expect(mapB.get(leaf1.hash)).toBe(0); // leaf1 matched
    });

    test('should recursively expand nested internal nodes', () => {
        const leaf1 = createLeaf("file1");
        const leaf2 = createLeaf("file2");
        const leaf3 = createLeaf("file3");
        const leaf4 = createLeaf("file4");
        
        // Build nested structure: ((file1, file2), (file3, file4))
        const leftSubtree = {
            left: leaf1,
            right: leaf2,
            hash: combineHashes(leaf1.hash, leaf2.hash),
            nodeCount: 3
        };
        const rightSubtree = {
            left: leaf3,
            right: leaf4,
            hash: combineHashes(leaf3.hash, leaf4.hash),
            nodeCount: 3
        };
        const root = {
            left: leftSubtree,
            right: rightSubtree,
            hash: combineHashes(leftSubtree.hash, rightSubtree.hash),
            nodeCount: 7
        };
        
        const mapB = new BufferMap<number>();
        // Only leaf1 and leaf3 are in mapB
        mapB.set(leaf1.hash, 1);
        mapB.set(leaf3.hash, 1);
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([root], mapB, onlyInTree1);
        
        // Should recursively expand and find leaf2 and leaf4
        const names = onlyInTree1.map(n => n.name).sort();
        expect(names).toEqual(["file2", "file4"]);
        expect(mapB.get(leaf1.hash)).toBe(0);
        expect(mapB.get(leaf3.hash)).toBe(0);
    });

    test('should handle mixed leaf and internal nodes', () => {
        const leaf1 = createLeaf("file1");
        const leaf2 = createLeaf("file2");
        const leaf3 = createLeaf("file3");
        const internal = {
            left: leaf2,
            right: leaf3,
            hash: combineHashes(leaf2.hash, leaf3.hash),
            nodeCount: 3
        };
        
        const mapB = new BufferMap<number>();
        mapB.set(leaf1.hash, 1); // leaf1 matches
        mapB.set(leaf2.hash, 1); // leaf2 matches
        // leaf3 and internal don't match
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([leaf1, internal], mapB, onlyInTree1);
        
        // leaf1 should match, internal should expand
        // leaf2 matches, leaf3 doesn't
        expect(onlyInTree1).toHaveLength(1);
        expect(onlyInTree1[0].name).toBe("file3");
        expect(mapB.get(leaf1.hash)).toBe(0);
        expect(mapB.get(leaf2.hash)).toBe(0);
    });

    test('should throw error for invalid tree structure - left child but no right', () => {
        const leaf = createLeaf("file1");
        const invalidInternal: MerkleNode = {
            left: leaf,
            right: undefined,
            hash: crypto.createHash("sha256").update("invalid").digest(),
            nodeCount: 2
        };
        const mapB = new BufferMap<number>();
        const onlyInTree1: MerkleNode[] = [];
        
        expect(() => {
            processRemainingNodes([invalidInternal], mapB, onlyInTree1);
        }).toThrow('Invalid tree structure: nodeA has a left child but no right child');
    });

    test('should throw error for invalid tree structure - right child but no left', () => {
        const leaf = createLeaf("file1");
        const invalidInternal: MerkleNode = {
            left: undefined,
            right: leaf,
            hash: crypto.createHash("sha256").update("invalid").digest(),
            nodeCount: 2
        };
        const mapB = new BufferMap<number>();
        const onlyInTree1: MerkleNode[] = [];
        
        expect(() => {
            processRemainingNodes([invalidInternal], mapB, onlyInTree1);
        }).toThrow('Invalid tree structure: nodeA has a right child but no left child');
    });

    test('should handle internal node with no children (edge case)', () => {
        const invalidInternal: MerkleNode = {
            left: undefined,
            right: undefined,
            hash: crypto.createHash("sha256").update("invalid").digest(),
            nodeCount: 2 // Claims to be internal but has no children
        };
        const mapB = new BufferMap<number>();
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([invalidInternal], mapB, onlyInTree1);
        
        // Should handle gracefully and add to onlyInTree1
        expect(onlyInTree1).toHaveLength(1);
        expect(onlyInTree1[0]).toBe(invalidInternal);
    });

    test('should handle complex scenario with multiple internal nodes and duplicates', () => {
        const duplicateContent = "duplicate";
        const leaf1 = createLeaf("file1", duplicateContent);
        const leaf2 = createLeaf("file2", duplicateContent); // Same hash as leaf1
        const leaf3 = createLeaf("file3");
        const leaf4 = createLeaf("file4");
        
        const internal1 = {
            left: leaf1,
            right: leaf2,
            hash: combineHashes(leaf1.hash, leaf2.hash),
            nodeCount: 3
        };
        const internal2 = {
            left: leaf3,
            right: leaf4,
            hash: combineHashes(leaf3.hash, leaf4.hash),
            nodeCount: 3
        };
        
        const mapB = new BufferMap<number>();
        mapB.set(leaf1.hash, 1); // One duplicate match available
        mapB.set(leaf3.hash, 1); // leaf3 matches
        // leaf2, leaf4, and internal nodes don't match
        const onlyInTree1: MerkleNode[] = [];
        
        processRemainingNodes([internal1, internal2], mapB, onlyInTree1);
        
        // internal1 expands: leaf1 matches (uses duplicate), leaf2 doesn't match (duplicate exhausted)
        // internal2 expands: leaf3 matches, leaf4 doesn't
        const names = onlyInTree1.map(n => n.name).sort();
        expect(names).toEqual(["file2", "file4"]);
        expect(mapB.get(leaf1.hash)).toBe(0);
        expect(mapB.get(leaf3.hash)).toBe(0);
    });
});

describe('findDifferingNodes with merged map (leaf and internal nodes)', () => {
    test('should correctly handle merged map with both leaf and internal node hashes', () => {
        // This tests that the merged map correctly tracks both leaf and internal node hashes
        // in the same map without conflicts
        const leaf1 = createLeaf("file1");
        const leaf2 = createLeaf("file2");
        const leaf3 = createLeaf("file3");
        const leaf4 = createLeaf("file4");
        
        // Tree1 has all 4 files
        const tree1 = buildMerkleTreeFromLeaves([
            leaf1,
            leaf2,
            leaf3,
            leaf4
        ]);
        
        // Tree2 has only file1 and file2
        const tree2 = buildMerkleTreeFromLeaves([
            leaf1,
            leaf2
        ]);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        // Should detect file3 and file4 as only in tree1
        // The merged map should correctly track both the internal node hash
        // (from the (file1, file2) subtree) and the leaf hashes
        const diffNames = diff
            .map(node => {
                if (node.name && !node.left && !node.right) {
                    return node.name;
                }
                const names: string[] = [];
                const extract = (n: MerkleNode) => {
                    if (n.name && !n.left && !n.right) {
                        names.push(n.name);
                    }
                    else {
                        if (n.left) extract(n.left);
                        if (n.right) extract(n.right);
                    }
                };
                extract(node);
                return names;
            })
            .flat()
            .sort();
        
        expect(diffNames).toContain("file3");
        expect(diffNames).toContain("file4");
        expect(diffNames).not.toContain("file1");
        expect(diffNames).not.toContain("file2");
    });

    test('should handle large trees with many duplicates using merged map', () => {
        const duplicateContent = "duplicate";
        const uniqueContent = "unique";
        
        // Create tree with many duplicates
        const tree1Leaves = [
            createLeaf("file1", duplicateContent),
            createLeaf("file2", duplicateContent),
            createLeaf("file3", duplicateContent),
            createLeaf("file4", duplicateContent),
            createLeaf("file5", uniqueContent),
            createLeaf("file6", uniqueContent)
        ];
        
        const tree2Leaves = [
            createLeaf("file1", duplicateContent),
            createLeaf("file2", duplicateContent),
            createLeaf("file5", uniqueContent)
        ];
        
        const tree1 = buildMerkleTreeFromLeaves(tree1Leaves);
        const tree2 = buildMerkleTreeFromLeaves(tree2Leaves);
        
        const diff = findDifferingNodes(tree1, tree2);
        
        // Should detect file3, file4, and file6 as only in tree1
        const diffNames = diff
            .map(node => {
                if (node.name && !node.left && !node.right) {
                    return node.name;
                }
                const names: string[] = [];
                const extract = (n: MerkleNode) => {
                    if (n.name && !n.left && !n.right) {
                        names.push(n.name);
                    }
                    else {
                        if (n.left) extract(n.left);
                        if (n.right) extract(n.right);
                    }
                };
                extract(node);
                return names;
            })
            .flat()
            .sort();
        
        expect(diffNames).toContain("file3");
        expect(diffNames).toContain("file4");
        expect(diffNames).toContain("file6");
        expect(diffNames).not.toContain("file1");
        expect(diffNames).not.toContain("file2");
        expect(diffNames).not.toContain("file5");
    });
});


