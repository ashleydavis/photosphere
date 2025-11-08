import * as crypto from 'crypto';
import * as fs from 'fs/promises';
import { 
    addItem, 
    HashedItem, 
    IMerkleTree,
    findItemNode,
    deleteItem,
    deleteItems,
    saveTree,
    loadTree,
    createTree,
    buildMerkleTree
} from '../lib/merkle-tree';
import { FileStorage } from 'storage';

describe('File Deletion (deleteItem)', () => {

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

    // Helper function to build a small test tree
    function buildTestTree(): IMerkleTree<any>{
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");
        const fileNames = ['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt'];
        
        for (const fileName of fileNames) {
            tree = addItem(tree, createHashedItem(fileName));
        }
        
        if (!tree) {
            throw new Error('Failed to build test tree');
        }

        tree.dirty = false;
        tree.merkle = buildMerkleTree(tree.sort); // Force tree rebuild.
        
        return tree;
    }

    test('should completely remove a file from the tree', () => {
        // Build a test tree
        const tree = buildTestTree();
        const initialNumFiles = tree.sort?.leafCount || 0;
        const initialNodeCount = tree.sort?.nodeCount || 0;
        
        // Verify the file exists before deletion
        const fileToDelete = 'file3.txt';
        const nodeBeforeDeletion = findItemNode(tree, fileToDelete);
        expect(nodeBeforeDeletion).toBeDefined();
        expect(nodeBeforeDeletion?.name).toBe(fileToDelete);
        
        // Delete the file completely
        deleteItem(tree, fileToDelete);
        
        // Verify the file is completely gone
        const nodeAfterDeletion = findItemNode(tree, fileToDelete);
        expect(nodeAfterDeletion).toBeUndefined();
        
        // Verify the tree structure has changed (fewer nodes and files)
        expect(tree.sort?.leafCount).toBe(initialNumFiles - 1);
        expect(tree.sort?.nodeCount || 0).toBeLessThan(initialNodeCount);
        
        // Verify remaining files are still present
        expect(findItemNode(tree, 'file1.txt')).toBeDefined();
        expect(findItemNode(tree, 'file2.txt')).toBeDefined();
        expect(findItemNode(tree, 'file4.txt')).toBeDefined();
        expect(findItemNode(tree, 'file5.txt')).toBeDefined();
    });

    test('should handle deleting a non-existent file', () => {
        const tree = buildTestTree();
        const initialLeafCount = tree.sort?.leafCount || 0;
        const initialNodeCount = tree.sort?.nodeCount || 0;
        
        // Attempt to delete a non-existent file
        deleteItem(tree, 'non-existent-file.txt');
        
        // Verify the tree structure is unchanged
        expect(tree.sort?.leafCount).toBe(initialLeafCount);
        expect(tree.sort?.nodeCount).toBe(initialNodeCount);
        expect(findItemNode(tree, 'non-existent-file.txt')).toBeUndefined();
    });

    test('should persist deletion when saving and loading the tree', async () => {
        // Create a test tree and delete a file
        const tree = buildTestTree();
        const fileToDelete = 'file2.txt';
        
        deleteItem(tree, fileToDelete);

        tree.dirty = false;
        tree.merkle = buildMerkleTree(tree.sort);
        
        // Save the tree to a temporary file
        const tempFile = '/tmp/merkle-tree-delete-test.bin';
        await saveTree(tempFile, tree, new FileStorage(""));
        
        // Load the tree back
        const loadedTree = (await loadTree(tempFile, new FileStorage("")))!;
        
        // Verify the file is completely gone
        expect(findItemNode(loadedTree, fileToDelete)).toBeUndefined();
        
        // Clean up
        await fs.unlink(tempFile).catch(() => {/* ignore error */});
    });

    test('should allow multiple files to be deleted', () => {
        const tree = buildTestTree();
        const initialFiles = tree.sort?.leafCount || 0;
        
        // Delete multiple files
        deleteItem(tree, 'file1.txt');
        deleteItem(tree, 'file3.txt');
        deleteItem(tree, 'file5.txt');
        
        // Check that all files are completely gone
        expect(findItemNode(tree, 'file1.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file2.txt')).toBeDefined();
        expect(findItemNode(tree, 'file3.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file4.txt')).toBeDefined();
        expect(findItemNode(tree, 'file5.txt')).toBeUndefined();
        
        // Verify metadata is correct
        expect(tree.sort?.leafCount).toBe(initialFiles - 3);
    });

    test('should update Merkle tree hashes when a file is deleted', () => {
        const tree = buildTestTree();
        
        // Save original root hash
        const originalRootHash = tree.merkle!.hash.toString('hex');
        
        // Delete a file
        deleteItem(tree, 'file3.txt');

        tree.dirty = false;
        tree.merkle = buildMerkleTree(tree.sort); // Force tree rebuild.
        
        // Get new root hash
        const newRootHash = tree.merkle!.hash.toString('hex');
        
        // The root hash should have changed
        expect(newRootHash).not.toBe(originalRootHash);
    });

    test('should handle deleting the only file in a tree', () => {
        // Create a tree with just one file
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");
        tree = addItem(tree, createHashedItem('single-file.txt'));
        
        expect(tree.sort?.leafCount).toBe(1);
        expect(tree.sort?.nodeCount || 0).toBe(1);
        
        // Delete the only file
        deleteItem(tree, 'single-file.txt');
        
        // Tree should be empty
        expect(tree.sort?.leafCount || 0).toBe(0);
        expect(tree.sort?.nodeCount || 0).toBe(0);
    });

    test('should handle deleting from empty tree', () => {
        const emptyTree = createTree("12345678-1234-5678-9abc-123456789abc");
        
        // Attempt to delete from empty tree
        deleteItem(emptyTree, 'any-file.txt');
        
        // Tree should remain empty
        expect(emptyTree.sort?.leafCount || 0).toBe(0);
        expect(emptyTree.sort?.nodeCount || 0).toBe(0);
    });
});

describe('Hard File Deletion (deleteItems)', () => {

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

    // Helper function to build a small test tree
    function buildTestTree(): IMerkleTree<any>{
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");
        const fileNames = ['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt'];
        
        for (const fileName of fileNames) {
            tree = addItem(tree, createHashedItem(fileName));
        }
        
        if (!tree) {
            throw new Error('Failed to build test tree');
        }

        tree.dirty = false;
        tree.merkle = buildMerkleTree(tree.sort); // Force tree rebuild.
        
        return tree;
    }

    test('should completely remove a file from the tree', () => {
        // Build a test tree
        const tree = buildTestTree();
        const initialNumFiles = tree.sort?.leafCount || 0;
        const initialNodeCount = tree.sort?.nodeCount || 0;
        
        // Verify the file exists before deletion
        const fileToDelete = 'file3.txt';
        const nodeBeforeDeletion = findItemNode(tree, fileToDelete);
        expect(nodeBeforeDeletion).toBeDefined();
        expect(nodeBeforeDeletion?.name).toBe(fileToDelete);
        
        // Delete the file completely
        const result = deleteItems(tree, [fileToDelete]);
        expect(result).toBe(1);
        
        // Verify the file is completely gone
        const nodeAfterDeletion = findItemNode(tree, fileToDelete);
        expect(nodeAfterDeletion).toBeUndefined();
        
        // Verify the tree structure has changed (fewer nodes and files)
        expect(tree.sort?.leafCount).toBe(initialNumFiles - 1);
        expect(tree.sort?.nodeCount || 0).toBeLessThan(initialNodeCount);
        
        // Verify remaining files are still present
        expect(findItemNode(tree, 'file1.txt')).toBeDefined();
        expect(findItemNode(tree, 'file2.txt')).toBeDefined();
        expect(findItemNode(tree, 'file4.txt')).toBeDefined();
        expect(findItemNode(tree, 'file5.txt')).toBeDefined();
    });

    test('should throw when trying to delete a non-existent file', () => {
        const tree = buildTestTree();
        
        expect(() => {
            deleteItems(tree, ['non-existent-file.txt']);
        }).toThrow('Cannot delete items: the following items do not exist: non-existent-file.txt');
    });

    test('should handle deleting the only file in a tree', () => {
        // Create a tree with just one file
        let tree = createTree("12345678-1234-5678-9abc-123456789abc");
        tree = addItem(tree, createHashedItem('single-file.txt'));
        
        expect(tree.sort?.leafCount).toBe(1);
        expect(tree.sort?.nodeCount || 0).toBe(1);
        
        // Delete the only file
        const result = deleteItems(tree, ['single-file.txt']);
        expect(result).toBe(1);
        
        // Tree should be empty
        expect(tree.sort?.leafCount || 0).toBe(0);
        expect(tree.sort?.nodeCount || 0).toBe(0);
    });

    test('should persist hard deletion when saving and loading the tree', async () => {
        // Create a test tree and delete a file
        const tree = buildTestTree();
        const fileToDelete = 'file2.txt';
        
        deleteItems(tree, [fileToDelete]);

        tree.dirty = false;
        tree.merkle = buildMerkleTree(tree.sort);
        
        // Save the tree to a temporary file
        const tempFile = '/tmp/merkle-tree-hard-delete-test.bin';
        await saveTree(tempFile, tree, new FileStorage(""));
        
        // Load the tree back
        const loadedTree = (await loadTree(tempFile, new FileStorage("")))!;
        
        // Verify the file is completely gone
        expect(findItemNode(loadedTree, fileToDelete)).toBeUndefined();
        
        // Clean up
        await fs.unlink(tempFile).catch(() => {/* ignore error */});
    });

    test('should allow multiple files to be deleted completely', () => {
        const tree = buildTestTree();
        const initialFiles = tree.sort?.leafCount || 0;
        
        // Delete multiple files
        const result = deleteItems(tree, ['file1.txt', 'file3.txt', 'file5.txt']);
        expect(result).toBe(3);
        
        // Check that all files are completely gone
        expect(findItemNode(tree, 'file1.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file2.txt')).toBeDefined();
        expect(findItemNode(tree, 'file3.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file4.txt')).toBeDefined();
        expect(findItemNode(tree, 'file5.txt')).toBeUndefined();
        
        // Verify metadata is correct
        expect(tree.sort?.leafCount).toBe(initialFiles - 3);
    });

    test('should update Merkle tree hashes when a file is deleted', () => {
        const tree = buildTestTree();
        
        // Save original root hash
        const originalRootHash = tree.merkle!.hash.toString('hex');
        
        // Delete a file
        deleteItems(tree, ['file3.txt']);

        tree.dirty = false;
        tree.merkle = buildMerkleTree(tree.sort); // Force tree rebuild.
        
        // Get new root hash
        const newRootHash = tree.merkle!.hash.toString('hex');
        
        // The root hash should have changed
        expect(newRootHash).not.toBe(originalRootHash);
    });

    test('should handle deleting all files from a tree', () => {
        const tree = buildTestTree();
        const allFiles = ['file1.txt', 'file2.txt', 'file3.txt', 'file4.txt', 'file5.txt'];
        
        // Delete all files
        const result = deleteItems(tree, allFiles);
        expect(result).toBe(allFiles.length);
        
        // Tree should be empty
        expect(tree.sort?.leafCount || 0).toBe(0);
        expect(tree.sort?.nodeCount || 0).toBe(0);
    });

    test('should preserve metadata id and update counts correctly', () => {
        const tree = buildTestTree();
        const originalMetadata = { id: tree.id, leafCount: tree.sort?.leafCount, nodeCount: tree.sort?.nodeCount, size: tree.sort?.size };
        
        // Delete a file
        deleteItems(tree, ['file3.txt']);
        
        // Check that metadata is preserved but counts are updated
        expect(tree.id).toBe(originalMetadata.id);
        expect(tree.sort?.leafCount).toBe((originalMetadata.leafCount || 0) - 1);
        expect(tree.sort?.nodeCount || 0).toBeLessThan(originalMetadata.nodeCount || 0);
        expect(tree.sort?.size || 0).toBeLessThan(originalMetadata.size || 0);
    });

    test('should throw when trying to delete from empty tree', () => {
        const emptyTree = createTree("12345678-1234-5678-9abc-123456789abc");
        
        expect(() => {
            deleteItems(emptyTree, ['any-file.txt']);
        }).toThrow('Cannot delete items from empty or invalid merkle tree');
    });

    test('should throw when trying to delete 0 files (empty array)', () => {
        const tree = buildTestTree();
        
        expect(() => {
            deleteItems(tree, []);
        }).toThrow('Cannot delete items: no names provided');
    });

    test('should handle deleting 1 file', () => {
        const tree = buildTestTree();
        const initialFiles = tree.sort?.leafCount || 0;
        
        const result = deleteItems(tree, ['file2.txt']);
        expect(result).toBe(1);
        
        // Tree should have one less file
        expect(tree.sort?.leafCount).toBe(initialFiles - 1);
        expect(findItemNode(tree, 'file2.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file1.txt')).toBeDefined();
        expect(findItemNode(tree, 'file3.txt')).toBeDefined();
    });

    test('should handle deleting 2 files', () => {
        const tree = buildTestTree();
        const initialFiles = tree.sort?.leafCount || 0;
        
        const result = deleteItems(tree, ['file1.txt', 'file4.txt']);
        expect(result).toBe(2);
        
        // Tree should have two less files
        expect(tree.sort?.leafCount).toBe(initialFiles - 2);
        expect(findItemNode(tree, 'file1.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file4.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file2.txt')).toBeDefined();
        expect(findItemNode(tree, 'file3.txt')).toBeDefined();
        expect(findItemNode(tree, 'file5.txt')).toBeDefined();
    });

    test('should handle deleting 3 files', () => {
        const tree = buildTestTree();
        const initialFiles = tree.sort?.leafCount || 0;
        
        const result = deleteItems(tree, ['file2.txt', 'file3.txt', 'file5.txt']);
        expect(result).toBe(3);
        
        // Tree should have three less files
        expect(tree.sort?.leafCount).toBe(initialFiles - 3);
        expect(findItemNode(tree, 'file2.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file3.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file5.txt')).toBeUndefined();
        expect(findItemNode(tree, 'file1.txt')).toBeDefined();
        expect(findItemNode(tree, 'file4.txt')).toBeDefined();
    });

    test('should throw when trying to delete mix of existing and non-existing files', () => {
        const tree = buildTestTree();
        
        expect(() => {
            deleteItems(tree, ['file1.txt', 'non-existent.txt', 'file3.txt', 'another-missing.txt']);
        }).toThrow('Cannot delete items: the following items do not exist: non-existent.txt, another-missing.txt');
    });
});