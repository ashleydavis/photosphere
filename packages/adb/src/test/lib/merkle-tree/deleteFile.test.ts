import * as crypto from 'crypto';
import * as fs from 'fs/promises';
import { 
    addFile, 
    FileHash, 
    IMerkleTree,
    findFileNode,
    deleteFile,
    deleteFiles,
    saveTree,
    loadTree,
    createTree
} from '../../../lib/merkle-tree';
import { FileStorage } from 'storage';

describe('File Deletion (deleteFile)', () => {

    // Helper function to create a file hash
    function createFileHash(fileName: string, content: string = fileName): FileHash {
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
        const initialNodeCount = tree.sort?.nodeCount || 0;
        
        // Verify the file exists before deletion
        const fileToDelete = 'file3.txt';
        const nodeBeforeDeletion = findFileNode(tree, fileToDelete);
        expect(nodeBeforeDeletion).toBeDefined();
        expect(nodeBeforeDeletion?.fileName).toBe(fileToDelete);
        
        // Delete the file completely
        const result = deleteFile(tree, fileToDelete);
        expect(result).toBe(true);
        
        // Verify the file is completely gone
        const nodeAfterDeletion = findFileNode(tree, fileToDelete);
        expect(nodeAfterDeletion).toBeUndefined();
        
        // Verify the tree structure has changed (fewer nodes and files)
        expect(tree.metadata.totalFiles).toBe(initialNumFiles - 1);
        expect(tree.sort?.nodeCount || 0).toBeLessThan(initialNodeCount);
        
        // Verify remaining files are still present
        expect(findFileNode(tree, 'file1.txt')).toBeDefined();
        expect(findFileNode(tree, 'file2.txt')).toBeDefined();
        expect(findFileNode(tree, 'file4.txt')).toBeDefined();
        expect(findFileNode(tree, 'file5.txt')).toBeDefined();
    });

    test('should handle deleting a non-existent file', () => {
        const tree = buildTestTree();
        const result = deleteFile(tree, 'non-existent-file.txt');
        expect(result).toBe(false);
    });

    test('should persist deletion when saving and loading the tree', async () => {
        // Create a test tree and delete a file
        const tree = buildTestTree();
        const fileToDelete = 'file2.txt';
        
        deleteFile(tree, fileToDelete);
        
        // Save the tree to a temporary file
        const tempFile = '/tmp/merkle-tree-delete-test.bin';
        await saveTree(tempFile, tree, new FileStorage(""));
        
        // Load the tree back
        const loadedTree = (await loadTree(tempFile, new FileStorage("")))!;
        
        // Verify the file is completely gone
        expect(findFileNode(loadedTree, fileToDelete)).toBeUndefined();
        
        // Clean up
        await fs.unlink(tempFile).catch(() => {/* ignore error */});
    });

    test('should allow multiple files to be deleted', () => {
        const tree = buildTestTree();
        const initialFiles = tree.metadata.totalFiles;
        
        // Delete multiple files
        deleteFile(tree, 'file1.txt');
        deleteFile(tree, 'file3.txt');
        deleteFile(tree, 'file5.txt');
        
        // Check that all files are completely gone
        expect(findFileNode(tree, 'file1.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file2.txt')).toBeDefined();
        expect(findFileNode(tree, 'file3.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file4.txt')).toBeDefined();
        expect(findFileNode(tree, 'file5.txt')).toBeUndefined();
        
        // Verify metadata is correct
        expect(tree.metadata.totalFiles).toBe(initialFiles - 3);
    });

    test('should update Merkle tree hashes when a file is deleted', () => {
        const tree = buildTestTree();
        
        // Save original root hash
        const originalRootHash = tree.sort?.hash.toString('hex');
        
        // Delete a file
        deleteFile(tree, 'file3.txt');
        
        // Get new root hash
        const newRootHash = tree.sort?.hash.toString('hex');
        
        // The root hash should have changed
        expect(newRootHash).not.toBe(originalRootHash);
    });

    test('should handle deleting the only file in a tree', () => {
        // Create a tree with just one file
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");
        tree = addFile(tree, createFileHash('single-file.txt'));
        
        expect(tree.metadata.totalFiles).toBe(1);
        expect(tree.sort?.nodeCount || 0).toBe(1);
        
        // Delete the only file
        const result = deleteFile(tree, 'single-file.txt');
        expect(result).toBe(true);
        
        // Tree should be empty
        expect(tree.metadata.totalFiles).toBe(0);
        expect(tree.sort?.nodeCount || 0).toBe(0);
    });

    test('should handle deleting from empty tree', () => {
        const emptyTree = createTree("12345678-1234-5678-9abc-123456789abc");
        const result = deleteFile(emptyTree, 'any-file.txt');
        expect(result).toBe(false);
    });
});

describe('Hard File Deletion (deleteFiles)', () => {

    // Helper function to create a file hash
    function createFileHash(fileName: string, content: string = fileName): FileHash {
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
        const initialNodeCount = tree.sort?.nodeCount || 0;
        
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
        
        // Verify the tree structure has changed (fewer nodes and files)
        expect(tree.metadata.totalFiles).toBe(initialNumFiles - 1);
        expect(tree.sort?.nodeCount || 0).toBeLessThan(initialNodeCount);
        
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
        expect(tree.sort?.nodeCount || 0).toBe(1);
        
        // Delete the only file
        const result = deleteFiles(tree, ['single-file.txt']);
        expect(result).toBe(1);
        
        // Tree should be empty
        expect(tree.metadata.totalFiles).toBe(0);
        expect(tree.sort?.nodeCount || 0).toBe(0);
    });

    test('should persist hard deletion when saving and loading the tree', async () => {
        // Create a test tree and delete a file
        const tree = buildTestTree();
        const fileToDelete = 'file2.txt';
        const initialFiles = tree.metadata.totalFiles;
        
        deleteFiles(tree, [fileToDelete]);
        
        // Save the tree to a temporary file
        const tempFile = '/tmp/merkle-tree-hard-delete-test.bin';
        await saveTree(tempFile, tree, new FileStorage(""));
        
        // Load the tree back
        const loadedTree = (await loadTree(tempFile, new FileStorage("")))!;
        
        // Verify the file is completely gone
        expect(findFileNode(loadedTree, fileToDelete)).toBeUndefined();
        
        // Clean up
        await fs.unlink(tempFile).catch(() => {/* ignore error */});
    });

    test('should allow multiple files to be deleted completely', () => {
        const tree = buildTestTree();
        const initialFiles = tree.metadata.totalFiles;
        
        // Delete multiple files
        const result = deleteFiles(tree, ['file1.txt', 'file3.txt', 'file5.txt']);
        expect(result).toBe(3);
        
        // Check that all files are completely gone
        expect(findFileNode(tree, 'file1.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file2.txt')).toBeDefined();
        expect(findFileNode(tree, 'file3.txt')).toBeUndefined();
        expect(findFileNode(tree, 'file4.txt')).toBeDefined();
        expect(findFileNode(tree, 'file5.txt')).toBeUndefined();
        
        // Verify metadata is correct
        expect(tree.metadata.totalFiles).toBe(initialFiles - 3);
    });

    test('should update Merkle tree hashes when a file is deleted', () => {
        const tree = buildTestTree();
        
        // Save original root hash
        const originalRootHash = tree.sort?.hash.toString('hex');
        
        // Delete a file
        deleteFiles(tree, ['file3.txt']);
        
        // Get new root hash
        const newRootHash = tree.sort?.hash.toString('hex');
        
        // The root hash should have changed
        expect(newRootHash).not.toBe(originalRootHash);
    });

    test('should handle deleting all files from a tree', () => {
        const tree = buildTestTree();
        const allFiles = ['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt'];
        
        // Delete all files
        const result = deleteFiles(tree, allFiles);
        expect(result).toBe(allFiles.length);
        
        // Tree should be empty
        expect(tree.metadata.totalFiles).toBe(0);
        expect(tree.sort?.nodeCount || 0).toBe(0);
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
    });

    test('should throw when trying to delete mix of existing and non-existing files', () => {
        const tree = buildTestTree();
        
        expect(() => {
            deleteFiles(tree, ['file1.txt', 'non-existent.txt', 'file3.txt', 'another-missing.txt']);
        }).toThrow('Cannot delete files: the following files do not exist: non-existent.txt, another-missing.txt');
    });
});