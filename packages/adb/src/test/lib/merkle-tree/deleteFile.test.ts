import * as crypto from 'crypto';
import * as fs from 'fs/promises';
import { 
    addFile, 
    FileHash, 
    IMerkleTree,
    findFileNode,
    findFileNodeWithDeletionStatus,
    markFileAsDeleted,
    isFileDeleted,
    getActiveFiles,
    saveTree,
    loadTree,
    createTree
} from '../../../lib/merkle-tree';
import { FileStorage } from 'storage';
import { TestTimestampProvider, TestUuidGenerator } from 'node-utils';

describe('File Deletion', () => {
    const timestampProvider = new TestTimestampProvider();
    const uuidGenerator = new TestUuidGenerator();

    // Helper function to create a file hash
    function createFileHash(fileName: string, content: string = fileName): FileHash {
        const hash = crypto.createHash('sha256')
            .update(content)
            .digest();
        return {
            fileName,
            hash,
            length: content.length,
        };
    }

    // Helper function to build a small test tree
    function buildTestTree(): IMerkleTree {
        let tree = createTree(timestampProvider, uuidGenerator);
        const fileNames = ['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt'];
        
        for (const fileName of fileNames) {
            tree = addFile(tree, createFileHash(fileName), timestampProvider, uuidGenerator);
        }
        
        if (!tree) {
            throw new Error('Failed to build test tree');
        }
        
        return tree;
    }

    test('should mark a file as deleted without removing it', () => {
        // Build a test tree
        const tree = buildTestTree();
        const initialNumFiles = tree.metadata.totalFiles;
        const initialNodeCount = tree.nodes.length;
        
        // Verify the file exists before deletion
        const fileToDelete = 'file3.txt';
        const nodeBeforeDeletion = findFileNode(tree, fileToDelete);
        expect(nodeBeforeDeletion).toBeDefined();
        expect(nodeBeforeDeletion?.fileName).toBe(fileToDelete);
        
        // Mark the file as deleted
        const result = markFileAsDeleted(tree, fileToDelete, timestampProvider);
        expect(result).toBe(true);
        
        // Verify the node is still in the tree but marked as deleted
        const nodeAfterDeletion = findFileNodeWithDeletionStatus(tree, fileToDelete, true);
        expect(nodeAfterDeletion).toBeDefined();
        expect(nodeAfterDeletion?.fileName).toBe(fileToDelete);
        expect(nodeAfterDeletion?.isDeleted).toBe(true);
        
        // Verify the tree structure hasn't changed
        expect(tree.metadata.totalFiles).toBe(initialNumFiles);
        expect(tree.nodes.length).toBe(initialNodeCount);
        
        // Verify the node ref is marked as deleted
        const nodeRefs = tree.sortedNodeRefs.filter(ref => ref.fileName === fileToDelete);
        expect(nodeRefs.length).toBe(1);
        expect(nodeRefs[0].isDeleted).toBe(true);
        
        // Verify regular file lookup doesn't find the deleted file
        const regularLookup = findFileNode(tree, fileToDelete);
        expect(regularLookup).toBeUndefined();
        
        // Check isFileDeleted helper function
        expect(isFileDeleted(tree, fileToDelete)).toBe(true);
        expect(isFileDeleted(tree, 'file1.txt')).toBe(false);
        
        // Check getActiveFiles helper function
        const activeFiles = getActiveFiles(tree);
        expect(activeFiles.length).toBe(initialNumFiles - 1);
        expect(activeFiles).not.toContain(fileToDelete);
    });

    test('should handle deleting a non-existent file', () => {
        const tree = buildTestTree();
        const result = markFileAsDeleted(tree, 'non-existent-file.txt', timestampProvider);
        expect(result).toBe(false);
    });

    test('should persist deletion status when saving and loading the tree', async () => {
        // Create a test tree and delete a file
        const tree = buildTestTree();
        const fileToDelete = 'file2.txt';
        
        markFileAsDeleted(tree, fileToDelete, timestampProvider);
        
        // Save the tree to a temporary file
        const tempFile = '/tmp/merkle-tree-delete-test.bin';
        await saveTree(tempFile, tree, new FileStorage(""));
        
        // Load the tree back
        const loadedTree = (await loadTree(tempFile, new FileStorage("")))!;
        
        // Verify the deletion status was preserved
        expect(isFileDeleted(loadedTree, fileToDelete)).toBe(true);
        expect(getActiveFiles(loadedTree)).not.toContain(fileToDelete);
        
        // Clean up
        await fs.unlink(tempFile).catch(() => {/* ignore error */});
    });

    test('should allow multiple files to be deleted', () => {
        const tree = buildTestTree();
        
        // Delete multiple files
        markFileAsDeleted(tree, 'file1.txt', timestampProvider);
        markFileAsDeleted(tree, 'file3.txt', timestampProvider);
        markFileAsDeleted(tree, 'file5.txt', timestampProvider);
        
        // Check that all files are marked correctly
        expect(isFileDeleted(tree, 'file1.txt')).toBe(true);
        expect(isFileDeleted(tree, 'file2.txt')).toBe(false);
        expect(isFileDeleted(tree, 'file3.txt')).toBe(true);
        expect(isFileDeleted(tree, 'file4.txt')).toBe(false);
        expect(isFileDeleted(tree, 'file5.txt')).toBe(true);
        
        // Verify active files
        const activeFiles = getActiveFiles(tree);
        expect(activeFiles.length).toBe(2);
        expect(activeFiles).toContain('file2.txt');
        expect(activeFiles).toContain('file4.txt');
    });

    test('should update Merkle tree hashes when a file is deleted', () => {
        const tree = buildTestTree();
        
        // Save original root hash
        const originalRootHash = tree.nodes[0].hash.toString('hex');
        
        // Delete a file
        markFileAsDeleted(tree, 'file3.txt', timestampProvider);
        
        // Get new root hash
        const newRootHash = tree.nodes[0].hash.toString('hex');
        
        // The root hash should have changed
        expect(newRootHash).not.toBe(originalRootHash);
    });
});