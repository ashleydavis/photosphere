import * as crypto from 'crypto';
import { 
    addFile, 
    IMerkleTree,
    markFileAsDeleted,
    compareTrees,
    generateTreeDiffReport,
    createTree
} from '../../../lib/merkle-tree';
import { TestTimestampProvider, TestUuidGenerator } from 'node-utils';

describe('Tree Comparison', () => {
    const timestampProvider = new TestTimestampProvider();
    const uuidGenerator = new TestUuidGenerator();

    // Helper function to create a file hash
    function createFileHash(fileName: string, content: string = fileName) {
        const hash = crypto.createHash('sha256')
            .update(content)
            .digest();
        return {
            fileName,
            hash,
            length: content.length,
        };
    }

    // Helper function to build test trees
    function buildTestTrees() {
        // Create first tree
        let treeA = buildTree(['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt']);
        markFileAsDeleted(treeA, 'file3.txt', timestampProvider);

        // Create second tree with differences
        let treeB = buildTree(['file1.txt']);
        treeB = addFile(treeB, createFileHash('file4.txt', 'Modified content'), timestampProvider, uuidGenerator); // Modified
        treeB = addFile(treeB, createFileHash('file5.txt'), timestampProvider, uuidGenerator);
        treeB = addFile(treeB, createFileHash('file6.txt'), timestampProvider, uuidGenerator); // New file

        return { treeA, treeB };
    }

    function buildTree(fileNames: string[]): IMerkleTree<any> {
        let tree = createTree<any>(timestampProvider, uuidGenerator);
        
        for (const fileName of fileNames) {
            tree = addFile(tree, createFileHash(fileName), timestampProvider, uuidGenerator);
        }
        
        if (!tree) {
            throw new Error('Failed to build test tree');
        }
        
        return tree;
    }

    test('should identify files only in first tree', () => {
        const { treeA, treeB } = buildTestTrees();
        
        const diff = compareTrees(treeA, treeB);
        
        // File2 exists in A but not in B
        expect(diff.onlyInA).toContain('file2.txt');
        
        // File3 is deleted in A, so shouldn't be in onlyInA
        expect(diff.onlyInA).not.toContain('file3.txt');
    });

    test('should identify files only in second tree', () => {
        const { treeA, treeB } = buildTestTrees();
        
        const diff = compareTrees(treeA, treeB);
        
        // File6 exists in B but not in A
        expect(diff.onlyInB).toContain('file6.txt');
    });

    test('should identify modified files', () => {
        const { treeA, treeB } = buildTestTrees();
        
        const diff = compareTrees(treeA, treeB);
        
        // File4 is modified (different content)
        expect(diff.modified).toContain('file4.txt');
        
        // File1 and file5 are identical, so shouldn't be in modified
        expect(diff.modified).not.toContain('file1.txt');
        expect(diff.modified).not.toContain('file5.txt');
    });

    test('should identify deleted files', () => {
        const { treeA, treeB } = buildTestTrees();
        
        const diff = compareTrees(treeA, treeB);
        
        // File3 is deleted in A but exists in B
        // Note: in our test case, file3 is deleted in A but not present in B
        // so we don't have a good test case for the deleted category
        expect(diff.deleted).toEqual([]);
        
        // Let's add file3 to B to test this properly
        const treeB2 = addFile(treeB, createFileHash('file3.txt'), timestampProvider, uuidGenerator);
        const diff2 = compareTrees(treeA, treeB2);
        
        // Now file3 should be in the deleted category
        expect(diff2.deleted).toContain('file3.txt');
    });

    test('should generate a comprehensive report', () => {
        const { treeA, treeB } = buildTestTrees();
        
        const report = generateTreeDiffReport(treeA, treeB);
        
        // Verify the report contains all sections
        expect(report).toContain('Merkle Tree Comparison Report');
        expect(report).toContain('Files only in first tree:');
        expect(report).toContain('Files only in second tree:');
        expect(report).toContain('Modified files:');
        expect(report).toContain('Deleted files');
        expect(report).toContain('Summary:');
        
        // Check for specific files in the report
        expect(report).toContain('file2.txt');
        expect(report).toContain('file4.txt');
        expect(report).toContain('file6.txt');
    });

    test('should handle identical trees', () => {
        const treeA = buildTree(['file1.txt', 'file2.txt']);
        const treeB = buildTree(['file1.txt', 'file2.txt']);
        
        const diff = compareTrees(treeA, treeB);
        
        // Should have no differences
        expect(diff.onlyInA).toEqual([]);
        expect(diff.onlyInB).toEqual([]);
        expect(diff.modified).toEqual([]);
        expect(diff.deleted).toEqual([]);
    });

    test('should handle completely different trees', () => {
        const treeA = buildTree(['fileA.txt', 'fileB.txt']);
        const treeB = buildTree(['fileC.txt', 'fileD.txt']);
        
        const diff = compareTrees(treeA, treeB);
        
        // All files should be in their respective "only in" categories
        expect(diff.onlyInA).toEqual(['fileA.txt', 'fileB.txt']);
        expect(diff.onlyInB).toEqual(['fileC.txt', 'fileD.txt']);
        expect(diff.modified).toEqual([]);
        expect(diff.deleted).toEqual([]);
    });
});