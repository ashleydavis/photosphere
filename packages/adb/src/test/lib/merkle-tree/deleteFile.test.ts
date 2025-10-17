import * as crypto from 'crypto';
import * as fs from 'fs/promises';
import { 
    addFile, 
    IFileHash, 
    IMerkleTree,
    findFileNode,
    findFileNodeWithDeletionStatus,
    markFileAsDeleted,
    deleteFiles,
    isFileDeleted,
    getActiveFiles,
    saveTree,
    loadTree,
    createTree
} from '../../../lib/merkle-tree';
import { FileStorage } from 'storage';

describe('File Deletion', () => {

    // Helper function to create a file hash
    function createFileHash(fileName: string, content: string = fileName): IFileHash {
        const hash = crypto.createHash('sha256')
            .update(content)
            .digest();
        return {
            fileName,
            hash,
            length: content.length,
            lastModified: new Date(),
        };
    }

    // Helper function to build a small test tree
    function buildTestTree(): IMerkleTree<any>{
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");
        const fileNames = ['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt'];
        
        for (const fileName of fileNames) {
            tree = addFile(tree, createFileHash(fileName));
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
        const result = markFileAsDeleted(tree, fileToDelete);
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
        const result = markFileAsDeleted(tree, 'non-existent-file.txt');
        expect(result).toBe(false);
    });

    test('should persist deletion status when saving and loading the tree', async () => {
        // Create a test tree and delete a file
        const tree = buildTestTree();
        const fileToDelete = 'file2.txt';
        
        markFileAsDeleted(tree, fileToDelete);
        
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
        markFileAsDeleted(tree, 'file1.txt');
        markFileAsDeleted(tree, 'file3.txt');
        markFileAsDeleted(tree, 'file5.txt');
        
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
        markFileAsDeleted(tree, 'file3.txt');
        
        // Get new root hash
        const newRootHash = tree.nodes[0].hash.toString('hex');
        
        // The root hash should have changed
        expect(newRootHash).not.toBe(originalRootHash);
    });
});

describe('Hard File Deletion (deleteFiles)', () => {

    // Helper function to create a file hash
    function createFileHash(fileName: string, content: string = fileName): IFileHash {
        const hash = crypto.createHash('sha256')
            .update(content)
            .digest();
        return {
            fileName,
            hash,
            length: content.length,
            lastModified: new Date(),
        };
    }

    // Helper function to build a small test tree
    function buildTestTree(): IMerkleTree<any>{
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");
        const fileNames = ['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt'];
        
        for (const fileName of fileNames) {
            tree = addFile(tree, createFileHash(fileName));
        }
        
        if (!tree) {
            throw new Error('Failed to build test tree');
        }
        
        return tree;
    }

    test('should completely remove a file from the tree', () => {
        // Build a test tree
        const tree = buildTestTree();
        const initialNumFiles = tree.metadata.totalFiles;
        const initialNodeCount = tree.nodes.length;
        
        // Verify the file exists before deletion
        const fileToDelete = 'file3.txt';
        const nodeBeforeDeletion = findFileNode(tree, fileToDelete);
        expect(nodeBeforeDeletion).toBeDefined();
        expect(nodeBeforeDeletion?.fileName).toBe(fileToDelete);
        
        // Delete the file completely
        const result = deleteFiles(tree, [fileToDelete]);
        expect(result).toBe(1);
        
        // Verify the file is completely gone
        const nodeAfterDeletion = findFileNode(tree, fileToDelete);
        expect(nodeAfterDeletion).toBeUndefined();
        
        // Verify the file is not found even with deletion status check
        const nodeWithDeletionCheck = findFileNodeWithDeletionStatus(tree, fileToDelete, true);
        expect(nodeWithDeletionCheck).toBeUndefined();
        
        // Verify the tree structure has changed (fewer nodes and files)
        expect(tree.metadata.totalFiles).toBe(initialNumFiles - 1);
        expect(tree.nodes.length).toBeLessThan(initialNodeCount);
        
        // Verify no node refs exist for the deleted file
        const nodeRefs = tree.sortedNodeRefs.filter(ref => ref.fileName === fileToDelete);
        expect(nodeRefs.length).toBe(0);
        
        // Verify isFileDeleted returns false (file doesn't exist at all)
        expect(isFileDeleted(tree, fileToDelete)).toBe(false);
        
        // Check getActiveFiles helper function
        const activeFiles = getActiveFiles(tree);
        expect(activeFiles.length).toBe(initialNumFiles - 1);
        expect(activeFiles).not.toContain(fileToDelete);
        
        // Verify remaining files are still present
        expect(findFileNode(tree, 'file1.txt')).toBeDefined();
        expect(findFileNode(tree, 'file2.txt')).toBeDefined();
        expect(findFileNode(tree, 'file4.txt')).toBeDefined();
        expect(findFileNode(tree, 'file5.txt')).toBeDefined();
    });

    test('should throw when trying to delete a non-existent file', () => {
        const tree = buildTestTree();
        
        expect(() => {
            deleteFiles(tree, ['non-existent-file.txt']);
        }).toThrow('Cannot delete files: the following files do not exist: non-existent-file.txt');
    });

    test('should handle deleting the only file in a tree', () => {
        // Create a tree with just one file
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");
        tree = addFile(tree, createFileHash('single-file.txt'));
        
        expect(tree.metadata.totalFiles).toBe(1);
        expect(tree.nodes.length).toBe(1);
        
        // Delete the only file
        const result = deleteFiles(tree, ['single-file.txt']);
        expect(result).toBe(1);
        
        // Tree should be empty
        expect(tree.metadata.totalFiles).toBe(0);
        expect(tree.nodes.length).toBe(0);
        expect(tree.sortedNodeRefs.length).toBe(0);
    });

    test('should persist hard deletion when saving and loading the tree', async () => {
        // Create a test tree and delete a file
        const tree = buildTestTree();
        const fileToDelete = 'file2.txt';
        const initialFiles = getActiveFiles(tree);
        
        deleteFiles(tree, [fileToDelete]);
        
        // Save the tree to a temporary file
        const tempFile = '/tmp/merkle-tree-hard-delete-test.bin';
        await saveTree(tempFile, tree, new FileStorage(""));
        
        // Load the tree back
        const loadedTree = (await loadTree(tempFile, new FileStorage("")))!;
        
        // Verify the file is completely gone
        expect(findFileNode(loadedTree, fileToDelete)).toBeUndefined();
        expect(isFileDeleted(loadedTree, fileToDelete)).toBe(false);
        
        const activeFiles = getActiveFiles(loadedTree);
        expect(activeFiles).not.toContain(fileToDelete);
        expect(activeFiles.length).toBe(initialFiles.length - 1);
        
        // Clean up
        await fs.unlink(tempFile).catch(() => {/* ignore error */});
    });

    test('should allow multiple files to be deleted completely', () => {
        const tree = buildTestTree();
        const initialFiles = getActiveFiles(tree);
        
        // Delete multiple files
        const result = deleteFiles(tree, ['file1.txt', 'file3.txt', 'file5.txt']);
        expect(result).toBe(3);
        
        // Check that all files are completely gone
        expect(findFileNode(tree, 'file1.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file2.txt')).toBeDefined();
        expect(findFileNode(tree, 'file3.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file4.txt')).toBeDefined();
        expect(findFileNode(tree, 'file5.txt')).toBeUndefined();
        
        // Verify active files
        const activeFiles = getActiveFiles(tree);
        expect(activeFiles.length).toBe(2);
        expect(activeFiles).toContain('file2.txt');
        expect(activeFiles).toContain('file4.txt');
        expect(activeFiles).not.toContain('file1.txt');
        expect(activeFiles).not.toContain('file3.txt');
        expect(activeFiles).not.toContain('file5.txt');
        
        // Verify metadata is correct
        expect(tree.metadata.totalFiles).toBe(2);
    });

    test('should update Merkle tree hashes when a file is deleted', () => {
        const tree = buildTestTree();
        
        // Save original root hash
        const originalRootHash = tree.nodes[0].hash.toString('hex');
        
        // Delete a file
        deleteFiles(tree, ['file3.txt']);
        
        // Get new root hash
        const newRootHash = tree.nodes[0].hash.toString('hex');
        
        // The root hash should have changed
        expect(newRootHash).not.toBe(originalRootHash);
    });

    test('should handle deleting all files from a tree', () => {
        const tree = buildTestTree();
        const allFiles = getActiveFiles(tree);
        
        // Delete all files
        const result = deleteFiles(tree, allFiles);
        expect(result).toBe(allFiles.length);
        
        // Tree should be empty
        expect(tree.metadata.totalFiles).toBe(0);
        expect(tree.nodes.length).toBe(0);
        expect(tree.sortedNodeRefs.length).toBe(0);
        expect(getActiveFiles(tree).length).toBe(0);
    });

    test('should preserve metadata id and update counts correctly', () => {
        const tree = buildTestTree();
        const originalMetadata = { ...tree.metadata };
        
        // Delete a file
        deleteFiles(tree, ['file3.txt']);
        
        // Check that metadata is preserved but counts are updated
        expect(tree.metadata.id).toBe(originalMetadata.id);
        expect(tree.metadata.totalFiles).toBe(originalMetadata.totalFiles - 1);
        expect(tree.metadata.totalNodes).toBeLessThan(originalMetadata.totalNodes);
        expect(tree.metadata.totalSize).toBeLessThan(originalMetadata.totalSize);
    });

    test('should throw when trying to delete from empty tree', () => {
        const emptyTree = createTree("12345678-1234-5678-9abc-123456789abc");
        
        expect(() => {
            deleteFiles(emptyTree, ['any-file.txt']);
        }).toThrow('Cannot delete files from empty or invalid merkle tree');
    });

    test('should throw when trying to delete 0 files (empty array)', () => {
        const tree = buildTestTree();
        
        expect(() => {
            deleteFiles(tree, []);
        }).toThrow('Cannot delete files: no file names provided');
    });

    test('should handle deleting 1 file', () => {
        const tree = buildTestTree();
        const initialFiles = tree.metadata.totalFiles;
        
        const result = deleteFiles(tree, ['file2.txt']);
        expect(result).toBe(1);
        
        // Tree should have one less file
        expect(tree.metadata.totalFiles).toBe(initialFiles - 1);
        expect(findFileNode(tree, 'file2.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file1.txt')).toBeDefined();
        expect(findFileNode(tree, 'file3.txt')).toBeDefined();
        expect(getActiveFiles(tree).length).toBe(initialFiles - 1);
    });

    test('should handle deleting 2 files', () => {
        const tree = buildTestTree();
        const initialFiles = tree.metadata.totalFiles;
        
        const result = deleteFiles(tree, ['file1.txt', 'file4.txt']);
        expect(result).toBe(2);
        
        // Tree should have two less files
        expect(tree.metadata.totalFiles).toBe(initialFiles - 2);
        expect(findFileNode(tree, 'file1.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file4.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file2.txt')).toBeDefined();
        expect(findFileNode(tree, 'file3.txt')).toBeDefined();
        expect(findFileNode(tree, 'file5.txt')).toBeDefined();
        expect(getActiveFiles(tree).length).toBe(initialFiles - 2);
    });

    test('should handle deleting 3 files', () => {
        const tree = buildTestTree();
        const initialFiles = tree.metadata.totalFiles;
        
        const result = deleteFiles(tree, ['file2.txt', 'file3.txt', 'file5.txt']);
        expect(result).toBe(3);
        
        // Tree should have three less files
        expect(tree.metadata.totalFiles).toBe(initialFiles - 3);
        expect(findFileNode(tree, 'file2.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file3.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file5.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file1.txt')).toBeDefined();
        expect(findFileNode(tree, 'file4.txt')).toBeDefined();
        expect(getActiveFiles(tree).length).toBe(initialFiles - 3);
    });

    test('should throw when trying to delete mix of existing and non-existing files', () => {
        const tree = buildTestTree();
        
        expect(() => {
            deleteFiles(tree, ['file1.txt', 'non-existent.txt', 'file3.txt', 'another-missing.txt']);
        }).toThrow('Cannot delete files: the following files do not exist: non-existent.txt, another-missing.txt');
    });
});