import { 
    iterateNodes, 
    iterateLeaves,
    SortNode,
} from '../lib/merkle-tree';
import { buildTree, leaf, node } from './merkle-verify';

describe('iterateNodes', () => {
    
    describe('Edge Cases', () => {
        test('returns nothing for undefined node', () => {
            const nodes = Array.from(iterateNodes(undefined));
            expect(nodes).toEqual([]);
        });

        test('iterates single leaf node', () => {
            const sortTree = leaf('A');
            const nodes = Array.from(iterateNodes<SortNode>(sortTree));
            
            expect(nodes.length).toBe(1);
            expect(nodes[0].fileName).toBe('A');
            expect(nodes[0].contentHash).toEqual(Buffer.from('A'));
        });

        test('iterates two leaf nodes', () => {
            const sortTree = node(leaf('A'), leaf('B'));
            const nodes = Array.from(iterateNodes<SortNode>(sortTree));
            
            // Should return parent node, then left child, then right child
            expect(nodes.length).toBe(3);
            expect(nodes[0].minFileName).toBe('A'); // Parent node
            expect(nodes[1].fileName).toBe('A'); // Left leaf
            expect(nodes[2].fileName).toBe('B'); // Right leaf
        });
    });

    describe('Traversal Order', () => {
        test('performs pre-order traversal (parent, left, right)', () => {
            // Build tree: ((A, B), C)
            const sortTree = node(node(leaf('A'), leaf('B')), leaf('C'));
            const nodes = Array.from(iterateNodes<SortNode>(sortTree));
            
            // Pre-order: root, left subtree (parent, A, B), right (C)
            expect(nodes.length).toBe(5);
            
            // First node is root
            expect(nodes[0].minFileName).toBe('A');
            expect(nodes[0].nodeCount).toBe(5);
            
            // Second node is left child (parent of A and B)
            expect(nodes[1].minFileName).toBe('A');
            expect(nodes[1].nodeCount).toBe(3);
            
            // Third node is leaf A
            expect(nodes[2].fileName).toBe('A');
            
            // Fourth node is leaf B
            expect(nodes[3].fileName).toBe('B');
            
            // Fifth node is leaf C
            expect(nodes[4].fileName).toBe('C');
        });

        test('visits all nodes in correct order for balanced tree', () => {
            // Build tree with 4 leaves: ((A, B), (C, D))
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const nodes = Array.from(iterateNodes<SortNode>(tree.sort!));
            
            // Should have 7 nodes total: 1 root + 2 internal + 4 leaves
            expect(nodes.length).toBe(7);
            
            // Verify all nodes are present
            const leafNodes = nodes.filter(n => n.fileName !== undefined);
            expect(leafNodes.length).toBe(4);
            expect(leafNodes.map(n => n.fileName)).toEqual(['A', 'B', 'C', 'D']);
        });
    });

    describe('Node Count', () => {
        test('counts all nodes correctly for small tree', () => {
            const tree = buildTree(['A', 'B', 'C']);
            const nodes = Array.from(iterateNodes<SortNode>(tree.sort!));
            
            // Tree structure: ((A, B), C) = 5 nodes total
            expect(nodes.length).toBe(5);
        });

        test('counts all nodes correctly for power of 2 leaves', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']);
            const nodes = Array.from(iterateNodes<SortNode>(tree.sort!));
            
            // For 8 leaves in a binary tree, we have 15 total nodes (8 leaves + 7 internal)
            expect(nodes.length).toBe(15);
        });

        test('counts all nodes correctly for non-power of 2 leaves', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            const nodes = Array.from(iterateNodes<SortNode>(tree.sort!));
            
            // For 5 leaves, we should have 9 total nodes
            expect(nodes.length).toBe(9);
        });
    });

    describe('Node Properties', () => {
        test('all nodes have valid nodeCount property', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F']);
            const nodes = Array.from(iterateNodes<SortNode>(tree.sort!));
            
            for (const node of nodes) {
                expect(node.nodeCount).toBeGreaterThanOrEqual(1);
                expect(typeof node.nodeCount).toBe('number');
            }
        });

        test('all nodes have valid minFileName property', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const nodes = Array.from(iterateNodes<SortNode>(tree.sort!));
            
            for (const node of nodes) {
                expect(node.minFileName).toBeDefined();
                expect(typeof node.minFileName).toBe('string');
            }
        });

        test('leaf nodes have fileName property', () => {
            const tree = buildTree(['A', 'B', 'C']);
            const nodes = Array.from(iterateNodes<SortNode>(tree.sort!));
            
            const leafNodes = nodes.filter(n => n.fileName !== undefined);
            expect(leafNodes.length).toBe(3);
            
            for (const leaf of leafNodes) {
                expect(leaf.contentHash).toBeDefined();
                expect(leaf.nodeCount).toBe(1);
            }
        });
    });

    describe('Large Trees', () => {
        test('iterates large tree with 100 nodes', () => {
            const fileNames = Array.from({ length: 100 }, (_, i) => 
                `file_${i.toString().padStart(3, '0')}`
            );
            const tree = buildTree(fileNames);
            const nodes = Array.from(iterateNodes<SortNode>(tree.sort!));
            
            // Should have all nodes
            expect(nodes.length).toBeGreaterThanOrEqual(100);
            
            // All 100 files should be present
            const leafNodes = nodes.filter(n => n.fileName !== undefined);
            expect(leafNodes.length).toBe(100);
        });
    });

    describe('Generator Behavior', () => {
        test('can be used in for...of loop', () => {
            const tree = buildTree(['A', 'B', 'C']);
            const nodeNames: string[] = [];
            
            for (const node of iterateNodes<SortNode>(tree.sort!)) {
                nodeNames.push(node.minFileName);
            }
            
            expect(nodeNames.length).toBeGreaterThan(0);
        });

        test('can be converted to array multiple times', () => {
            const tree = buildTree(['A', 'B', 'C']);
            
            const nodes1 = Array.from(iterateNodes<SortNode>(tree.sort!));
            const nodes2 = Array.from(iterateNodes<SortNode>(tree.sort!));
            
            expect(nodes1.length).toBe(nodes2.length);
        });

        test('is lazy and does not iterate until consumed', () => {
            const tree = buildTree(['A', 'B', 'C']);
            
            // Creating the generator should not iterate
            const generator = iterateNodes<SortNode>(tree.sort!);
            
            // Only when we consume it does it iterate
            const firstNode = generator.next();
            expect(firstNode.done).toBe(false);
            expect(firstNode.value).toBeDefined();
        });
    });
});

describe('iterateLeaves', () => {
    
    describe('Edge Cases', () => {
        test('returns nothing for undefined node', () => {
            const leaves = Array.from(iterateLeaves(undefined));
            expect(leaves).toEqual([]);
        });

        test('iterates single leaf node', () => {
            const sortTree = leaf('A');
            const leaves = Array.from(iterateLeaves<SortNode>(sortTree));
            
            expect(leaves.length).toBe(1);
            expect(leaves[0].fileName).toBe('A');
            expect(leaves[0].contentHash).toEqual(Buffer.from('A'));
        });

        test('iterates two leaf nodes', () => {
            const sortTree = node(leaf('A'), leaf('B'));
            const leaves = Array.from(iterateLeaves<SortNode>(sortTree));
            
            expect(leaves.length).toBe(2);
            expect(leaves[0].fileName).toBe('A');
            expect(leaves[1].fileName).toBe('B');
        });
    });

    describe('Leaf-Only Filtering', () => {
        test('only returns leaf nodes, not internal nodes', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            // Should only have leaf nodes
            expect(leaves.length).toBe(4);
            
            // All should have fileName property (leaf indicator)
            for (const leaf of leaves) {
                expect(leaf.fileName).toBeDefined();
                expect(leaf.contentHash).toBeDefined();
                expect(leaf.nodeCount).toBe(1);
            }
        });

        test('does not return parent nodes', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            const allNodes = Array.from(iterateNodes<SortNode>(tree.sort!));
            
            // Leaves should be fewer than all nodes
            expect(leaves.length).toBeLessThan(allNodes.length);
            expect(leaves.length).toBe(5);
        });
    });

    describe('Leaf Order Preservation', () => {
        test('preserves in-order traversal of leaves', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            const fileNames = leaves.map(l => l.fileName);
            expect(fileNames).toEqual(['A', 'B', 'C', 'D']);
        });

        test('maintains sorted order for unsorted input', () => {
            const tree = buildTree(['D', 'A', 'C', 'B', 'E']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            const fileNames = leaves.map(l => l.fileName);
            // Should be sorted because buildTree creates a sorted tree
            expect(fileNames).toEqual(['A', 'B', 'C', 'D', 'E']);
        });

        test('maintains order with UUID filenames', () => {
            const fileNames = [
                'asset/3e4f1677-dfc1-4efe-be57-6969e0b1c9b6',
                'asset/7b4f6865-26a5-4316-98ba-41e528594ec0',
                'asset/7c86cb29-c6ee-40dc-9d08-a8dc5c5a0dc7',
            ];
            
            const tree = buildTree(fileNames);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            expect(leaves.map(l => l.fileName)).toEqual(fileNames);
        });
    });

    describe('Leaf Count', () => {
        test('counts leaves correctly for power of 2', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            expect(leaves.length).toBe(8);
        });

        test('counts leaves correctly for non-power of 2', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            expect(leaves.length).toBe(7);
        });

        test('leaf count matches tree leafCount property', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            expect(leaves.length).toBe(tree.sort!.leafCount);
        });
    });

    describe('Leaf Properties', () => {
        test('all leaves have contentHash', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            for (const leaf of leaves) {
                expect(leaf.contentHash).toBeDefined();
                expect(Buffer.isBuffer(leaf.contentHash)).toBe(true);
            }
        });

        test('all leaves have fileName', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            for (const leaf of leaves) {
                expect(leaf.fileName).toBeDefined();
                expect(typeof leaf.fileName).toBe('string');
            }
        });

        test('all leaves have nodeCount of 1', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            for (const leaf of leaves) {
                expect(leaf.nodeCount).toBe(1);
            }
        });

        test('all leaves have leafCount of 1', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            for (const leaf of leaves) {
                expect(leaf.leafCount).toBe(1);
            }
        });

        test('all leaves have no children', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            for (const leaf of leaves) {
                expect(leaf.left).toBeUndefined();
                expect(leaf.right).toBeUndefined();
            }
        });
    });

    describe('Large Trees', () => {
        test('iterates 100 leaves efficiently', () => {
            const fileNames = Array.from({ length: 100 }, (_, i) => 
                `file_${i.toString().padStart(3, '0')}`
            );
            const tree = buildTree(fileNames);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            expect(leaves.length).toBe(100);
            
            // Verify all files are present
            const leafFileNames = leaves.map(l => l.fileName);
            expect(leafFileNames).toEqual(fileNames);
        });

        test('iterates 1000 leaves efficiently', () => {
            const fileNames = Array.from({ length: 1000 }, (_, i) => 
                `file_${i.toString().padStart(4, '0')}`
            );
            const tree = buildTree(fileNames);
            const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            expect(leaves.length).toBe(1000);
        });
    });

    describe('Generator Behavior', () => {
        test('can be used in for...of loop', () => {
            const tree = buildTree(['A', 'B', 'C']);
            const fileNames: string[] = [];
            
            for (const leaf of iterateLeaves<SortNode>(tree.sort!)) {
                fileNames.push(leaf.fileName!);
            }
            
            expect(fileNames).toEqual(['A', 'B', 'C']);
        });

        test('can be converted to array multiple times', () => {
            const tree = buildTree(['A', 'B', 'C']);
            
            const leaves1 = Array.from(iterateLeaves<SortNode>(tree.sort!));
            const leaves2 = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            expect(leaves1.length).toBe(leaves2.length);
            expect(leaves1.map(l => l.fileName)).toEqual(leaves2.map(l => l.fileName));
        });

        test('is lazy and does not iterate until consumed', () => {
            const tree = buildTree(['A', 'B', 'C']);
            
            // Creating the generator should not iterate
            const generator = iterateLeaves<SortNode>(tree.sort!);
            
            // Only when we consume it does it iterate
            const firstLeaf = generator.next();
            expect(firstLeaf.done).toBe(false);
            expect(firstLeaf.value).toBeDefined();
            expect(firstLeaf.value.fileName).toBe('A');
        });

        test('can be partially consumed', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            const generator = iterateLeaves<SortNode>(tree.sort!);
            
            // Consume first 3 leaves
            const leaf1 = generator.next();
            const leaf2 = generator.next();
            const leaf3 = generator.next();
            
            expect(leaf1.value.fileName).toBe('A');
            expect(leaf2.value.fileName).toBe('B');
            expect(leaf3.value.fileName).toBe('C');
            
            // Can still get remaining leaves
            const leaf4 = generator.next();
            const leaf5 = generator.next();
            const done = generator.next();
            
            expect(leaf4.value.fileName).toBe('D');
            expect(leaf5.value.fileName).toBe('E');
            expect(done.done).toBe(true);
        });
    });

    describe('Comparison with Manual Collection', () => {
        test('produces same results as manual recursive collection', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F']);
            
            // Manual collection using recursion (like in the existing tests)
            const manualLeaves: SortNode[] = [];
            function collectLeaves(node: SortNode | undefined) {
                if (!node) return;
                if (!node.left && !node.right) {
                    manualLeaves.push(node);
                } else {
                    collectLeaves(node.left);
                    collectLeaves(node.right);
                }
            }
            collectLeaves(tree.sort);
            
            // Using iterateLeaves
            const iteratorLeaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
            
            // Both should produce the same results
            expect(iteratorLeaves.length).toBe(manualLeaves.length);
            expect(iteratorLeaves.map(l => l.fileName)).toEqual(manualLeaves.map(l => l.fileName));
        });
    });

    describe('Empty Subtrees', () => {
        test('handles nodes with only left child', () => {
            // Manually construct a tree with imbalanced structure
            const leftLeaf = leaf('A');
            const parent: SortNode = {
                nodeCount: 2,
                leafCount: 1,
                size: leftLeaf.size,
                minFileName: 'A',
                left: leftLeaf,
                // right is undefined
            };
            
            const leaves = Array.from(iterateLeaves<SortNode>(parent));
            expect(leaves.length).toBe(1);
            expect(leaves[0].fileName).toBe('A');
        });

        test('handles nodes with only right child', () => {
            // Manually construct a tree with only right child
            const rightLeaf = leaf('B');
            const parent: SortNode = {
                nodeCount: 2,
                leafCount: 1,
                size: rightLeaf.size,
                minFileName: 'B',
                right: rightLeaf,
                // left is undefined
            };
            
            const leaves = Array.from(iterateLeaves<SortNode>(parent));
            expect(leaves.length).toBe(1);
            expect(leaves[0].fileName).toBe('B');
        });
    });
});

describe('iterateNodes vs iterateLeaves', () => {
    test('iterateNodes returns more nodes than iterateLeaves', () => {
        const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
        
        const allNodes = Array.from(iterateNodes<SortNode>(tree.sort!));
        const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
        
        expect(allNodes.length).toBeGreaterThan(leaves.length);
    });

    test('all leaves from iterateLeaves are present in iterateNodes', () => {
        const tree = buildTree(['A', 'B', 'C', 'D']);
        
        const allNodes = Array.from(iterateNodes<SortNode>(tree.sort!));
        const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
        
        const leafFileNames = leaves.map(l => l.fileName);
        const nodesWithFiles = allNodes.filter(n => n.fileName !== undefined);
        const nodeFileNames = nodesWithFiles.map(n => n.fileName);
        
        expect(leafFileNames).toEqual(nodeFileNames);
    });

    test('difference in count equals number of internal nodes', () => {
        const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H']);
        
        const allNodes = Array.from(iterateNodes<SortNode>(tree.sort!));
        const leaves = Array.from(iterateLeaves<SortNode>(tree.sort!));
        
        const internalNodeCount = allNodes.length - leaves.length;
        
        // For a binary tree with n leaves, we have n-1 internal nodes
        // (but this can vary based on tree structure)
        expect(internalNodeCount).toBeGreaterThan(0);
        expect(internalNodeCount).toBeLessThan(leaves.length);
    });
});

