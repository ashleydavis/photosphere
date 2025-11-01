import * as crypto from 'crypto';
import { 
    addItem, 
    IMerkleTree,
    deleteItem,
    createTree,
    buildMerkleTree
} from '../lib/merkle-tree';
import { compareTrees, generateTreeDiffReport } from '../lib/compare';

describe('Tree Comparison', () => {

    // Helper function to create a file hash
    function createHashedItem(name: string, content: string = name) {
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

    // Helper function to build test trees
    function buildTestTrees() {
        // Create first tree
        let treeA = buildTree(['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt']);
        deleteItem(treeA, 'file3.txt');
        treeA.merkle = buildMerkleTree(treeA.sort);
        treeA.dirty = false;

        // Create second tree with differences
        let treeB = buildTree(['file1.txt']);
        treeB = addItem(treeB, createHashedItem('file4.txt', 'Modified content')); // Modified
        treeB = addItem(treeB, createHashedItem('file5.txt'));
        treeB = addItem(treeB, createHashedItem('file6.txt')); // New file
        treeB.merkle = buildMerkleTree(treeB.sort);
        treeB.dirty = false;

        return { treeA, treeB };
    }

    function buildTree(fileNames: string[]): IMerkleTree<any> {
        let tree = createTree<any>("12345678-1234-5678-9abc-123456789abc");
        
        for (const fileName of fileNames) {
            tree = addItem(tree, createHashedItem(fileName));
        }
        
        if (!tree) {
            throw new Error('Failed to build test tree');
        }
        
        // Build the merkle tree from the sort tree
        tree.merkle = buildMerkleTree(tree.sort);
        tree.dirty = false;
        return tree;
    }

    test('should identify files only in first tree', async () => {
        const { treeA, treeB } = buildTestTrees();
        
        const diff = compareTrees(treeA, treeB);
        
        // File2 exists in A but not in B
        expect(diff.onlyInA).toContain('file2.txt');
        
        // File3 is deleted in A, so shouldn't be in onlyInA
        expect(diff.onlyInA).not.toContain('file3.txt');
    });

    test('should identify files only in second tree', async () => {
        const { treeA, treeB } = buildTestTrees();
        
        const diff = compareTrees(treeA, treeB);
        
        // File6 exists in B but not in A
        expect(diff.onlyInB).toContain('file6.txt');
    });

    test('should identify modified files', async () => {
        const { treeA, treeB } = buildTestTrees();
        
        const diff = compareTrees(treeA, treeB);
        
        // File4 is modified (different content)
        expect(diff.modified).toContain('file4.txt');
        
        // File1 and file5 are identical, so shouldn't be in modified
        expect(diff.modified).not.toContain('file1.txt');
        expect(diff.modified).not.toContain('file5.txt');
    });

    test('should identify deleted files', async () => {
        // Create two trees with the same files initially
        let treeA = buildTree(['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt']);
        let treeB = buildTree(['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt']);
        
        // Delete file3 from treeA
        deleteItem(treeA, 'file3.txt');
        treeA.merkle = buildMerkleTree(treeA.sort);
        treeA.dirty = false;
        
        const diff = compareTrees(treeA, treeB);
        
        // file3 should be in the onlyInB category (exists in B but not in A)
        // Note: The current comparison logic doesn't distinguish between "deleted" and "only in B"
        // Both represent files that exist in B but not in A
        expect(diff.onlyInB).toContain('file3.txt');
    });

    test('should generate a comprehensive report', async () => {
        const { treeA, treeB } = buildTestTrees();
        
        const report = generateTreeDiffReport(treeA, treeB);
        
        // Verify the report contains all sections
        expect(report).toContain('Merkle Tree Comparison Report');
        expect(report).toContain('Files only in first tree:');
        expect(report).toContain('Files only in second tree:');
        expect(report).toContain('Modified files:');
        expect(report).toContain('Summary:');
        
        // Check for specific files in the report
        expect(report).toContain('file2.txt');
        expect(report).toContain('file4.txt');
        expect(report).toContain('file6.txt');
    });

    test('should handle identical trees', async () => {
        const treeA = buildTree(['file1.txt', 'file2.txt']);
        const treeB = buildTree(['file1.txt', 'file2.txt']);
        
        const diff = compareTrees(treeA, treeB);
        
        // Should have no differences
        expect(diff.onlyInA).toEqual([]);
        expect(diff.onlyInB).toEqual([]);
        expect(diff.modified).toEqual([]);
    });

    test('should handle completely different trees', async () => {
        const treeA = buildTree(['fileA.txt', 'fileB.txt']);
        const treeB = buildTree(['fileC.txt', 'fileD.txt']);
        
        const diff = compareTrees(treeA, treeB);
        
        // All files should be in their respective "only in" categories
        expect(diff.onlyInA).toEqual(['fileA.txt', 'fileB.txt']);
        expect(diff.onlyInB).toEqual(['fileC.txt', 'fileD.txt']);
        expect(diff.modified).toEqual([]);
    });
});