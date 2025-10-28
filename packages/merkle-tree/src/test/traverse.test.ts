import { 
    traverseTreeSync,
    traverseTreeAsync,
} from '../lib/traverse';
import { SortNode } from '../lib/merkle-tree';
import { buildTree, leaf, node } from './merkle-verify';

describe('traverseTreeSync', () => {
    
    describe('Edge Cases', () => {
        test('handles undefined node', () => {
            const visited: string[] = [];
            traverseTreeSync(undefined, (node: SortNode) => {
                visited.push(node.minName);
                return true;
            });
            expect(visited).toEqual([]);
        });

        test('traverses single leaf node', () => {
            const sortTree = leaf('A');
            const visited: string[] = [];
            
            traverseTreeSync<SortNode>(sortTree, (node) => {
                visited.push(node.minName);
                return true;
            });
            
            expect(visited).toEqual(['A']);
        });

        test('traverses two leaf nodes', () => {
            const sortTree = node(leaf('A'), leaf('B'));
            const visited: string[] = [];
            
            traverseTreeSync<SortNode>(sortTree, (node) => {
                visited.push(node.minName);
                return true;
            });
            
            expect(visited.length).toBe(3);
            expect(visited[0]).toBe('A'); // Parent with minName 'A'
            expect(visited[1]).toBe('A'); // Left leaf
            expect(visited[2]).toBe('B'); // Right leaf
        });
    });

    describe('Traversal Order', () => {
        test('performs pre-order traversal (parent, left, right)', () => {
            // Build tree: ((A, B), C)
            const sortTree = node(node(leaf('A'), leaf('B')), leaf('C'));
            const visited: string[] = [];
            
            traverseTreeSync<SortNode>(sortTree, (node) => {
                visited.push(node.minName);
                return true;
            });
            
            // Pre-order: root, left subtree (parent, A, B), right (C)
            expect(visited.length).toBe(5);
            expect(visited[0]).toBe('A'); // Root
            expect(visited[1]).toBe('A'); // Left child (parent of A and B)
            expect(visited[2]).toBe('A'); // Leaf A
            expect(visited[3]).toBe('B'); // Leaf B
            expect(visited[4]).toBe('C'); // Leaf C
        });

        test('visits all nodes in pre-order for balanced tree', () => {
            // Build tree with 4 leaves: ((A, B), (C, D))
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const nodeNames: string[] = [];
            const nodeCounts: number[] = [];
            
            traverseTreeSync<SortNode>(tree.sort!, (node) => {
                nodeNames.push(node.minName);
                nodeCounts.push(node.nodeCount);
                return true;
            });
            
            // Should have 7 nodes total: 1 root + 2 internal + 4 leaves
            expect(nodeNames.length).toBe(7);
            
            // First node should be root with highest nodeCount
            expect(nodeCounts[0]).toBeGreaterThan(nodeCounts[1]);
        });
    });

    describe('Early Termination', () => {
        test('stops node children when callback returns false', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const visited: string[] = [];
            
            traverseTreeSync<SortNode>(tree.sort!, (node) => {
                visited.push(node.minName);
                // Stop at the first internal node (nodeCount === 3)
                // This should skip its children but not siblings
                if (node.nodeCount === 3 && node.minName === 'A') {
                    return false;
                }
                return true;
            });
            
            // Should visit root, left subtree root (stops here), then right subtree
            // Root + left internal (no children) + right leaf = depends on tree structure
            expect(visited.length).toBeGreaterThan(2);
            expect(visited.length).toBeLessThan(7); // Less than all nodes
        });

        test('stops traversing children of node when it returns false', () => {
            // Create a simple tree where we can control termination
            const sortTree = node(
                node(leaf('A'), leaf('B')),
                node(leaf('C'), leaf('D'))
            );
            const visited: string[] = [];
            const leafNames: string[] = [];
            
            traverseTreeSync<SortNode>(sortTree, (node) => {
                visited.push(node.minName);
                if (node.name) {
                    leafNames.push(node.name);
                }
                // Stop at first internal node (left subtree root)
                if (node.nodeCount === 3 && node.minName === 'A') {
                    return false;
                }
                return true;
            });
            
            // Should visit: root, left internal (stops), right internal, C, D
            expect(visited).toContain('C');
            expect(visited).toContain('D');
            // Should NOT visit leaf nodes A or B (children of stopped node)
            expect(leafNames).toEqual(['C', 'D']);
            expect(leafNames).not.toContain('A');
            expect(leafNames).not.toContain('B');
        });

        test('continues traversal when callback returns true', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            const visited: string[] = [];
            
            traverseTreeSync<SortNode>(tree.sort!, (node) => {
                visited.push(node.minName);
                return true; // Always continue
            });
            
            // Should visit all 9 nodes
            expect(visited.length).toBe(9);
        });

        test('prevents children traversal for leaf nodes when returning false', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const leafNames: string[] = [];
            
            traverseTreeSync<SortNode>(tree.sort!, (node) => {
                // Collect leaf names but stop traversal at leaves
                if (node.name) {
                    leafNames.push(node.name);
                    return false; // Stop at leaves (they have no children anyway)
                }
                return true;
            });
            
            // Should still find all leaves
            expect(leafNames).toEqual(['A', 'B', 'C', 'D']);
        });
    });

    describe('Node Collection', () => {
        test('collects all leaf nodes', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const leaves: SortNode[] = [];
            
            traverseTreeSync<SortNode>(tree.sort!, (node) => {
                if (node.nodeCount === 1 && node.name) {
                    leaves.push(node);
                }
                return true;
            });
            
            expect(leaves.length).toBe(4);
            expect(leaves.map(l => l.name)).toEqual(['A', 'B', 'C', 'D']);
        });

        test('collects all internal nodes', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const internalNodes: SortNode[] = [];
            
            traverseTreeSync<SortNode>(tree.sort!, (node) => {
                if (node.nodeCount > 1) {
                    internalNodes.push(node);
                }
                return true;
            });
            
            expect(internalNodes.length).toBe(3); // 1 root + 2 internal
        });

        test('counts total nodes', () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            let nodeCount = 0;
            
            traverseTreeSync<SortNode>(tree.sort!, () => {
                nodeCount++;
                return true;
            });
            
            expect(nodeCount).toBe(9); // 5 leaves + 4 internal nodes
        });
    });

    describe('Node Validation', () => {
        test('verifies all nodes have required properties', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            let allValid = true;
            
            traverseTreeSync<SortNode>(tree.sort!, (node) => {
                if (!node.minName || typeof node.nodeCount !== 'number') {
                    allValid = false;
                }
                return true;
            });
            
            expect(allValid).toBe(true);
        });

        test('can validate tree structure', () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const invalidNodes: SortNode[] = [];
            
            traverseTreeSync<SortNode>(tree.sort!, (node) => {
                // Check if nodeCount matches actual structure
                if (node.nodeCount === 1 && (node.left || node.right)) {
                    invalidNodes.push(node); // Leaf shouldn't have children
                }
                return true;
            });
            
            expect(invalidNodes.length).toBe(0);
        });
    });

    describe('Large Trees', () => {
        test('traverses tree with 100 nodes', () => {
            const fileNames = Array.from({ length: 100 }, (_, i) => 
                `file_${i.toString().padStart(3, '0')}`
            );
            const tree = buildTree(fileNames);
            let count = 0;
            
            traverseTreeSync<SortNode>(tree.sort!, () => {
                count++;
                return true;
            });
            
            expect(count).toBeGreaterThanOrEqual(100);
        });

        test('can limit traversal in large tree', () => {
            const fileNames = Array.from({ length: 100 }, (_, i) => 
                `file_${i.toString().padStart(3, '0')}`
            );
            const tree = buildTree(fileNames);
            let count = 0;
            
            traverseTreeSync<SortNode>(tree.sort!, () => {
                count++;
                // Stop after visiting some nodes (will skip their children)
                return count < 50;
            });
            
            // Should visit fewer nodes than the full tree
            expect(count).toBeLessThan(199); // 100 leaves + 99 internal = 199 total
            expect(count).toBeGreaterThan(0);
        });
    });

    describe('Empty Subtrees', () => {
        test('handles nodes with only left child', () => {
            const leftLeaf = leaf('A');
            const parent: SortNode = {
                nodeCount: 2,
                leafCount: 1,
                size: leftLeaf.size,
                minName: 'A',
                left: leftLeaf,
                // right is undefined
            };
            
            const visited: string[] = [];
            traverseTreeSync<SortNode>(parent, (node) => {
                visited.push(node.minName);
                return true;
            });
            
            expect(visited.length).toBe(2); // Parent and left child
            expect(visited).toEqual(['A', 'A']);
        });

        test('handles nodes with only right child', () => {
            const rightLeaf = leaf('B');
            const parent: SortNode = {
                nodeCount: 2,
                leafCount: 1,
                size: rightLeaf.size,
                minName: 'B',
                right: rightLeaf,
                // left is undefined
            };
            
            const visited: string[] = [];
            traverseTreeSync<SortNode>(parent, (node) => {
                visited.push(node.minName);
                return true;
            });
            
            expect(visited.length).toBe(2); // Parent and right child
            expect(visited).toEqual(['B', 'B']);
        });
    });
});

describe('traverseTreeAsync', () => {
    
    describe('Edge Cases', () => {
        test('handles undefined node', async () => {
            const visited: string[] = [];
            await traverseTreeAsync(undefined, async (node: SortNode) => {
                visited.push(node.minName);
                return true;
            });
            expect(visited).toEqual([]);
        });

        test('traverses single leaf node', async () => {
            const sortTree = leaf('A');
            const visited: string[] = [];
            
            await traverseTreeAsync<SortNode>(sortTree, async (node) => {
                visited.push(node.minName);
                return true;
            });
            
            expect(visited).toEqual(['A']);
        });

        test('traverses two leaf nodes', async () => {
            const sortTree = node(leaf('A'), leaf('B'));
            const visited: string[] = [];
            
            await traverseTreeAsync<SortNode>(sortTree, async (node) => {
                visited.push(node.minName);
                return true;
            });
            
            expect(visited.length).toBe(3);
            expect(visited[0]).toBe('A'); // Parent
            expect(visited[1]).toBe('A'); // Left leaf
            expect(visited[2]).toBe('B'); // Right leaf
        });
    });

    describe('Traversal Order', () => {
        test('performs pre-order traversal (parent, left, right)', async () => {
            const sortTree = node(node(leaf('A'), leaf('B')), leaf('C'));
            const visited: string[] = [];
            
            await traverseTreeAsync<SortNode>(sortTree, async (node) => {
                visited.push(node.minName);
                return true;
            });
            
            expect(visited.length).toBe(5);
            expect(visited[0]).toBe('A'); // Root
            expect(visited[1]).toBe('A'); // Left subtree root
            expect(visited[2]).toBe('A'); // Leaf A
            expect(visited[3]).toBe('B'); // Leaf B
            expect(visited[4]).toBe('C'); // Leaf C
        });

        test('visits all nodes in pre-order for balanced tree', async () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const nodeNames: string[] = [];
            
            await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
                nodeNames.push(node.minName);
                return true;
            });
            
            expect(nodeNames.length).toBe(7);
        });
    });

    describe('Async Behavior', () => {
        test('waits for async callback to complete', async () => {
            const tree = buildTree(['A', 'B', 'C']);
            const visited: string[] = [];
            const delays: number[] = [];
            
            await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
                const delay = Math.random() * 10;
                delays.push(delay);
                await new Promise(resolve => setTimeout(resolve, delay));
                visited.push(node.minName);
                return true;
            });
            
            // All nodes should be visited despite async delays
            expect(visited.length).toBe(5);
        });

        test('processes nodes sequentially in pre-order', async () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const visitOrder: number[] = [];
            let counter = 0;
            
            await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
                await new Promise(resolve => setTimeout(resolve, 5));
                visitOrder.push(counter++);
                return true;
            });
            
            // Should be sequential: 0, 1, 2, 3, 4, 5, 6
            expect(visitOrder).toEqual([0, 1, 2, 3, 4, 5, 6]);
        });

        test('can perform async operations in callback', async () => {
            const tree = buildTree(['A', 'B', 'C']);
            const asyncResults: string[] = [];
            
            await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
                // Simulate async operation
                const result = await Promise.resolve(`processed-${node.minName}`);
                asyncResults.push(result);
                return true;
            });
            
            expect(asyncResults.length).toBe(5);
            expect(asyncResults.every(r => r.startsWith('processed-'))).toBe(true);
        });
    });

    describe('Early Termination', () => {
        test('stops node children when callback returns false', async () => {
            // Create a simple tree where we can control termination
            const sortTree = node(
                node(leaf('A'), leaf('B')),
                node(leaf('C'), leaf('D'))
            );
            const visited: string[] = [];
            
            await traverseTreeAsync<SortNode>(sortTree, async (node) => {
                visited.push(node.minName);
                // Stop at first internal node (left subtree root)
                if (node.nodeCount === 3 && node.minName === 'A') {
                    return false;
                }
                return true;
            });
            
            // Should visit: root, left internal (stops), right internal, C, D
            expect(visited).toContain('C');
            expect(visited).toContain('D');
            expect(visited.length).toBeLessThan(7); // Less than all nodes
        });

        test('stops after async operation returns false', async () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const leafNames: string[] = [];
            
            await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
                await new Promise(resolve => setTimeout(resolve, 1));
                
                // Stop at leaf nodes (prevents visiting children, but they don't have any)
                if (node.name) {
                    leafNames.push(node.name);
                    return false;
                }
                return true;
            });
            
            // Should still collect all leaves
            expect(leafNames).toEqual(['A', 'B', 'C', 'D']);
        });

        test('can conditionally terminate based on async check', async () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const visited: string[] = [];
            
            await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
                // Simulate async validation
                const shouldContinue = await Promise.resolve(visited.length < 4);
                if (shouldContinue) {
                    visited.push(node.minName);
                }
                return shouldContinue;
            });
            
            // Will visit some nodes and stop when condition is met
            expect(visited.length).toBeGreaterThan(0);
            expect(visited.length).toBeLessThanOrEqual(7);
        });
    });

    describe('Node Collection', () => {
        test('collects all leaf nodes asynchronously', async () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const leaves: SortNode[] = [];
            
            await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
                if (node.nodeCount === 1 && node.name) {
                    leaves.push(node);
                }
                return true;
            });
            
            expect(leaves.length).toBe(4);
            expect(leaves.map(l => l.name)).toEqual(['A', 'B', 'C', 'D']);
        });

        test('can perform async filtering', async () => {
            const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
            const filtered: SortNode[] = [];
            
            await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
                // Simulate async check
                const passes = await Promise.resolve(node.nodeCount > 1);
                if (passes) {
                    filtered.push(node);
                }
                return true;
            });
            
            // Should have collected all internal nodes
            expect(filtered.length).toBeGreaterThan(0);
            expect(filtered.every(n => n.nodeCount > 1)).toBe(true);
        });
    });

    describe('Error Handling', () => {
        test('propagates errors from async callback', async () => {
            const tree = buildTree(['A', 'B', 'C']);
            
            await expect(async () => {
                await traverseTreeAsync<SortNode>(tree.sort!, async () => {
                    throw new Error('Callback error');
                });
            }).rejects.toThrow('Callback error');
        });

        test('stops traversal on error', async () => {
            const tree = buildTree(['A', 'B', 'C', 'D']);
            const visited: string[] = [];
            
            try {
                await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
                    visited.push(node.minName);
                    if (visited.length === 3) {
                        throw new Error('Stop here');
                    }
                    return true;
                });
            } catch (e) {
                // Expected error
            }
            
            expect(visited.length).toBe(3);
        });
    });

    describe('Large Trees', () => {
        test('traverses tree with 100 nodes asynchronously', async () => {
            const fileNames = Array.from({ length: 100 }, (_, i) => 
                `file_${i.toString().padStart(3, '0')}`
            );
            const tree = buildTree(fileNames);
            let count = 0;
            
            await traverseTreeAsync<SortNode>(tree.sort!, async () => {
                await new Promise(resolve => setTimeout(resolve, 1));
                count++;
                return true;
            });
            
            expect(count).toBeGreaterThanOrEqual(100);
        });

        test('can limit traversal in large tree', async () => {
            const fileNames = Array.from({ length: 100 }, (_, i) => 
                `file_${i.toString().padStart(3, '0')}`
            );
            const tree = buildTree(fileNames);
            let count = 0;
            
            await traverseTreeAsync<SortNode>(tree.sort!, async () => {
                count++;
                // Stop after visiting some nodes (will skip their children)
                return count < 50;
            });
            
            // Should visit fewer nodes than the full tree
            expect(count).toBeLessThan(199); // 100 leaves + 99 internal = 199 total
            expect(count).toBeGreaterThan(0);
        });
    });

    describe('Empty Subtrees', () => {
        test('handles nodes with only left child', async () => {
            const leftLeaf = leaf('A');
            const parent: SortNode = {
                nodeCount: 2,
                leafCount: 1,
                size: leftLeaf.size,
                minName: 'A',
                left: leftLeaf,
            };
            
            const visited: string[] = [];
            await traverseTreeAsync<SortNode>(parent, async (node) => {
                visited.push(node.minName);
                return true;
            });
            
            expect(visited.length).toBe(2);
            expect(visited).toEqual(['A', 'A']);
        });

        test('handles nodes with only right child', async () => {
            const rightLeaf = leaf('B');
            const parent: SortNode = {
                nodeCount: 2,
                leafCount: 1,
                size: rightLeaf.size,
                minName: 'B',
                right: rightLeaf,
            };
            
            const visited: string[] = [];
            await traverseTreeAsync<SortNode>(parent, async (node) => {
                visited.push(node.minName);
                return true;
            });
            
            expect(visited.length).toBe(2);
            expect(visited).toEqual(['B', 'B']);
        });
    });
});

describe('traverseTreeSync vs traverseTreeAsync', () => {
    test('both produce same traversal order', async () => {
        const tree = buildTree(['A', 'B', 'C', 'D', 'E']);
        const syncOrder: string[] = [];
        const asyncOrder: string[] = [];
        
        traverseTreeSync<SortNode>(tree.sort!, (node) => {
            syncOrder.push(node.minName);
            return true;
        });
        
        await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
            asyncOrder.push(node.minName);
            return true;
        });
        
        expect(syncOrder).toEqual(asyncOrder);
    });

    test('both handle early termination similarly', async () => {
        // Use a controlled tree structure
        const sortTree = node(
            node(leaf('A'), leaf('B')),
            node(leaf('C'), leaf('D'))
        );
        const syncVisited: string[] = [];
        const asyncVisited: string[] = [];
        
        traverseTreeSync<SortNode>(sortTree, (node) => {
            syncVisited.push(node.minName);
            // Stop at first internal node
            if (node.nodeCount === 3 && node.minName === 'A') {
                return false;
            }
            return true;
        });
        
        await traverseTreeAsync<SortNode>(sortTree, async (node) => {
            asyncVisited.push(node.minName);
            // Stop at first internal node
            if (node.nodeCount === 3 && node.minName === 'A') {
                return false;
            }
            return true;
        });
        
        expect(syncVisited).toEqual(asyncVisited);
    });

    test('both collect same nodes', async () => {
        const tree = buildTree(['A', 'B', 'C', 'D', 'E', 'F']);
        const syncLeaves: string[] = [];
        const asyncLeaves: string[] = [];
        
        traverseTreeSync<SortNode>(tree.sort!, (node) => {
            if (node.name) {
                syncLeaves.push(node.name);
            }
            return true;
        });
        
        await traverseTreeAsync<SortNode>(tree.sort!, async (node) => {
            if (node.name) {
                asyncLeaves.push(node.name);
            }
            return true;
        });
        
        expect(syncLeaves).toEqual(asyncLeaves);
    });
});

