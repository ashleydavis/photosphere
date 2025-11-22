import * as crypto from 'crypto';
import {
    findDifferingNodes,
    findMerkleTreeDifferences
} from '../lib/merkle-diff';
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
        expect(diff.length).toBe(2);
        // Check each diff node directly
        // diff[0] is an internal node containing file1 and file2 subtree, but file1 matches so only file2 is different
        // diff[1] is the internal node containing file3 and file4
        expect(diff[0].left!.name).toBe("file1");
        expect(diff[0].right!.name).toBe("file2");
        expect(diff[1].left!.name).toBe("file3");
        expect(diff[1].right!.name).toBe("file4");
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


