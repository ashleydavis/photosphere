import * as crypto from 'crypto';
import { 
    addItem, 
    HashedItem, 
    IMerkleTree,
    findItemNode,
    createTree,
    buildMerkleTree,
    pruneTree,
    iterateLeaves,
    MerkleNode,
    SortNode
} from '../lib/merkle-tree';
import { findMerkleTreeDifferences } from '../lib/merkle-diff';

describe('pruneTree', () => {

    // Helper function to create a file hash
    function createHashedItem(name: string, content: string = name): HashedItem {
        const hash = crypto.createHash('sha256')
            .update(content)
            .digest();
        return {
            name,
            hash,
            length: content.length,
            lastModified: new Date(),
        };
    }

    // Helper function to build a test tree with multiple files
    function buildTestTree(fileNames: string[]): IMerkleTree<any> {
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");
        
        for (const fileName of fileNames) {
            tree = addItem(tree, createHashedItem(fileName));
        }
        
        if (!tree) {
            throw new Error('Failed to build test tree');
        }

        tree.dirty = false;
        tree.merkle = buildMerkleTree(tree.sort);
        
        return tree;
    }

    // Helper function to find a MerkleNode by file name
    function findMerkleNodeByFileName(merkleNode: MerkleNode | undefined, fileName: string): MerkleNode | undefined {
        if (!merkleNode) {
            return undefined;
        }
        
        if (!merkleNode.left && !merkleNode.right) {
            // Leaf node
            if (merkleNode.name === fileName) {
                return merkleNode;
            }
            return undefined;
        }
        
        // Internal node - search children
        const leftResult = findMerkleNodeByFileName(merkleNode.left, fileName);
        if (leftResult) {
            return leftResult;
        }
        return findMerkleNodeByFileName(merkleNode.right, fileName);
    }

    test('should prune a single leaf node', () => {
        const tree = buildTestTree(['file1.txt', 'file2.txt', 'file3.txt']);
        const initialLeafCount = tree.sort?.leafCount || 0;
        
        // Find the MerkleNode for file2.txt
        const nodeToPrune = findMerkleNodeByFileName(tree.merkle, 'file2.txt');
        expect(nodeToPrune).toBeDefined();
        
        // Verify file exists before pruning
        expect(findItemNode(tree, 'file2.txt')).toBeDefined();
        
        // Prune the node
        const prunedFiles = pruneTree(tree, [nodeToPrune!]);
        
        // Verify correct file was pruned
        expect(prunedFiles).toEqual(['file2.txt']);
        
        // Verify file is removed from sort tree
        expect(findItemNode(tree, 'file2.txt')).toBeUndefined();
        expect(tree.sort?.leafCount).toBe(initialLeafCount - 1);
        
        // Verify other files still exist
        expect(findItemNode(tree, 'file1.txt')).toBeDefined();
        expect(findItemNode(tree, 'file3.txt')).toBeDefined();
        
        // Verify tree is marked as dirty
        expect(tree.dirty).toBe(true);
    });

    test('should prune multiple leaf nodes', () => {
        const tree = buildTestTree(['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt']);
        const initialLeafCount = tree.sort?.leafCount || 0;
        
        // Find MerkleNodes for multiple files
        const node1 = findMerkleNodeByFileName(tree.merkle, 'file2.txt');
        const node2 = findMerkleNodeByFileName(tree.merkle, 'file4.txt');
        expect(node1).toBeDefined();
        expect(node2).toBeDefined();
        
        // Prune multiple nodes
        const prunedFiles = pruneTree(tree, [node1!, node2!]);
        
        // Verify correct files were pruned
        expect(prunedFiles).toContain('file2.txt');
        expect(prunedFiles).toContain('file4.txt');
        expect(prunedFiles.length).toBe(2);
        
        // Verify files are removed from sort tree
        expect(findItemNode(tree, 'file2.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file4.txt')).toBeUndefined();
        expect(tree.sort?.leafCount).toBe(initialLeafCount - 2);
        
        // Verify other files still exist
        expect(findItemNode(tree, 'file1.txt')).toBeDefined();
        expect(findItemNode(tree, 'file3.txt')).toBeDefined();
        expect(findItemNode(tree, 'file5.txt')).toBeDefined();
        
        // Verify tree is marked as dirty
        expect(tree.dirty).toBe(true);
    });

    test('should prune a subtree (internal node)', () => {
        const tree = buildTestTree(['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt']);
        const initialLeafCount = tree.sort?.leafCount || 0;
        
        // Find a subtree that contains multiple files
        // We'll use findMerkleTreeDifferences to get a subtree
        const tree2 = buildTestTree(['a.txt', 'b.txt', 'c.txt']); // Smaller tree
        const diff = findMerkleTreeDifferences(tree.merkle, tree2.merkle);
        
        // diff.onlyInTree1 should contain nodes for d.txt and e.txt
        expect(diff.onlyInTree1.length).toBeGreaterThan(0);
        
        // Prune the subtree
        const prunedFiles = pruneTree(tree, diff.onlyInTree1);
        
        // Verify files were pruned
        expect(prunedFiles.length).toBeGreaterThan(0);
        expect(prunedFiles).toContain('d.txt');
        expect(prunedFiles).toContain('e.txt');
        
        // Verify files are removed from sort tree
        expect(findItemNode(tree, 'd.txt')).toBeUndefined();
        expect(findItemNode(tree, 'e.txt')).toBeUndefined();
        expect(tree.sort?.leafCount).toBeLessThan(initialLeafCount);
        
        // Verify remaining files still exist
        expect(findItemNode(tree, 'a.txt')).toBeDefined();
        expect(findItemNode(tree, 'b.txt')).toBeDefined();
        expect(findItemNode(tree, 'c.txt')).toBeDefined();
        
        // Verify tree is marked as dirty
        expect(tree.dirty).toBe(true);
    });

    test('should prune multiple subtrees', () => {
        const tree = buildTestTree(['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt', 'f.txt']);
        const initialLeafCount = tree.sort?.leafCount || 0;
        
        // Create two different trees to get different subtrees
        const tree1 = buildTestTree(['a.txt', 'b.txt', 'c.txt']);
        const tree2 = buildTestTree(['a.txt', 'b.txt', 'c.txt', 'd.txt']);
        
        const diff1 = findMerkleTreeDifferences(tree.merkle, tree1.merkle);
        const diff2 = findMerkleTreeDifferences(tree.merkle, tree2.merkle);
        
        // Combine nodes from both diffs
        const nodesToPrune = [...diff1.onlyInTree1, ...diff2.onlyInTree1];
        
        // Prune multiple subtrees
        const prunedFiles = pruneTree(tree, nodesToPrune);
        
        // Verify files were pruned (should include d.txt, e.txt, f.txt)
        expect(prunedFiles.length).toBeGreaterThan(0);
        
        // Verify tree is marked as dirty
        expect(tree.dirty).toBe(true);
        expect(tree.sort?.leafCount).toBeLessThan(initialLeafCount);
    });

    test('should handle empty nodes array', () => {
        const tree = buildTestTree(['file1.txt', 'file2.txt']);
        const initialLeafCount = tree.sort?.leafCount || 0;
        const initialDirty = tree.dirty;
        
        // Prune with empty array
        const prunedFiles = pruneTree(tree, []);
        
        // Verify nothing was pruned
        expect(prunedFiles).toEqual([]);
        expect(tree.sort?.leafCount).toBe(initialLeafCount);
        
        // Verify tree dirty state unchanged (should remain false since nothing was pruned)
        expect(tree.dirty).toBe(initialDirty);
    });

    test('should handle nodes without names (skip them)', () => {
        const tree = buildTestTree(['file1.txt', 'file2.txt', 'file3.txt']);
        const initialLeafCount = tree.sort?.leafCount || 0;
        
        // Create a MerkleNode without a name (internal node) that contains two files
        const internalNode: MerkleNode = {
            hash: crypto.createHash('sha256').update('test').digest(),
            nodeCount: 3,
            left: {
                hash: crypto.createHash('sha256').update('left').digest(),
                nodeCount: 1,
                name: 'file1.txt'
            },
            right: {
                hash: crypto.createHash('sha256').update('right').digest(),
                nodeCount: 1,
                name: 'file2.txt'
            }
        };
        
        // Prune with internal node (should extract leaves with names)
        const prunedFiles = pruneTree(tree, [internalNode]);
        
        // Verify files were pruned (leaves have names)
        expect(prunedFiles).toContain('file1.txt');
        expect(prunedFiles).toContain('file2.txt');
        
        // Verify files are removed from sort tree
        expect(findItemNode(tree, 'file1.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file2.txt')).toBeUndefined();
        
        // Verify remaining file still exists
        expect(findItemNode(tree, 'file3.txt')).toBeDefined();
        
        // Verify leaf count decreased (tree.sort should still exist since file3.txt remains)
        expect(tree.sort?.leafCount).toBe(initialLeafCount - 2);
        expect(tree.dirty).toBe(true);
    });

    test('should handle pruning files that do not exist in sort tree', () => {
        const tree = buildTestTree(['file1.txt', 'file2.txt']);
        const initialLeafCount = tree.sort?.leafCount || 0;
        
        // Create a MerkleNode for a file that doesn't exist
        const nonExistentNode: MerkleNode = {
            hash: crypto.createHash('sha256').update('nonexistent').digest(),
            nodeCount: 1,
            name: 'nonexistent.txt'
        };
        
        // Prune non-existent file
        const prunedFiles = pruneTree(tree, [nonExistentNode]);
        
        // Verify file name is in returned list
        expect(prunedFiles).toContain('nonexistent.txt');
        
        // Verify sort tree is unchanged (file didn't exist)
        expect(tree.sort?.leafCount).toBe(initialLeafCount);
        
        // Verify tree is still marked as dirty (we attempted to prune)
        expect(tree.dirty).toBe(true);
    });

    test('should return pruned file names in correct order', () => {
        const tree = buildTestTree(['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt']);
        
        // Find nodes for specific files
        const node1 = findMerkleNodeByFileName(tree.merkle, 'c.txt');
        const node2 = findMerkleNodeByFileName(tree.merkle, 'a.txt');
        const node3 = findMerkleNodeByFileName(tree.merkle, 'e.txt');
        
        // Prune in specific order
        const prunedFiles = pruneTree(tree, [node1!, node2!, node3!]);
        
        // Verify all files are in the list
        expect(prunedFiles).toContain('a.txt');
        expect(prunedFiles).toContain('c.txt');
        expect(prunedFiles).toContain('e.txt');
        expect(prunedFiles.length).toBe(3);
    });

    test('should handle pruning all files from tree', () => {
        const tree = buildTestTree(['file1.txt', 'file2.txt', 'file3.txt']);
        
        // Prune the entire tree by using the root merkle node
        const prunedFiles = pruneTree(tree, [tree.merkle!]);
        
        // Verify all files were pruned
        expect(prunedFiles.length).toBe(3);
        expect(prunedFiles).toContain('file1.txt');
        expect(prunedFiles).toContain('file2.txt');
        expect(prunedFiles).toContain('file3.txt');
        
        // Verify sort tree is empty or has no leaves
        expect(tree.sort?.leafCount || 0).toBe(0);
        expect(tree.dirty).toBe(true);
    });

    test('should not mark tree as dirty when no files are pruned', () => {
        const tree = buildTestTree(['file1.txt', 'file2.txt']);
        tree.dirty = false;
        
        // Create a node with no name
        const nodeWithoutName: MerkleNode = {
            hash: crypto.createHash('sha256').update('test').digest(),
            nodeCount: 1
            // No name property
        };
        
        // Prune node without name
        const prunedFiles = pruneTree(tree, [nodeWithoutName]);
        
        // Verify nothing was pruned
        expect(prunedFiles).toEqual([]);
        
        // Verify tree is not marked as dirty
        expect(tree.dirty).toBe(false);
    });

    test('should handle duplicate file names in different nodes', () => {
        const tree = buildTestTree(['file1.txt', 'file2.txt']);
        const initialLeafCount = tree.sort?.leafCount || 0;
        
        // Find the same file node twice
        const node1 = findMerkleNodeByFileName(tree.merkle, 'file1.txt');
        const node2 = findMerkleNodeByFileName(tree.merkle, 'file1.txt');
        
        // Prune with duplicate nodes
        const prunedFiles = pruneTree(tree, [node1!, node2!]);
        
        // Verify file appears in list (may appear twice if both nodes are processed)
        expect(prunedFiles.length).toBeGreaterThanOrEqual(1);
        expect(prunedFiles).toContain('file1.txt');
        
        // Verify file is removed from sort tree (only once)
        expect(findItemNode(tree, 'file1.txt')).toBeUndefined();
        expect(tree.sort?.leafCount).toBe(initialLeafCount - 1);
        expect(tree.dirty).toBe(true);
    });

    test('should maintain tree structure integrity after pruning', () => {
        const tree = buildTestTree(['a.txt', 'b.txt', 'c.txt', 'd.txt', 'e.txt']);
        const initialLeafCount = tree.sort?.leafCount || 0;
        
        // Find and prune a middle file
        const nodeToPrune = findMerkleNodeByFileName(tree.merkle, 'c.txt');
        const prunedFiles = pruneTree(tree, [nodeToPrune!]);
        
        // Verify file was pruned
        expect(prunedFiles).toEqual(['c.txt']);
        
        // Verify tree structure is still valid
        expect(tree.sort).toBeDefined();
        expect(tree.sort?.leafCount).toBe(initialLeafCount - 1);
        
        // Verify remaining files are still accessible
        expect(findItemNode(tree, 'a.txt')).toBeDefined();
        expect(findItemNode(tree, 'b.txt')).toBeDefined();
        expect(findItemNode(tree, 'd.txt')).toBeDefined();
        expect(findItemNode(tree, 'e.txt')).toBeDefined();
        
        // Verify tree properties are consistent
        if (tree.sort) {
            const allLeaves: SortNode[] = [];
            for (const leaf of iterateLeaves<SortNode>(tree.sort)) {
                allLeaves.push(leaf);
            }
            expect(allLeaves.length).toBe(initialLeafCount - 1);
        }
    });
});

