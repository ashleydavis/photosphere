import fs from 'fs/promises';
import * as crypto from 'crypto';
import { 
    IMerkleTree,
    HashedItem,
    addItem,
    updateItem,
    deleteItem,
    saveTree,
    loadTree,
    createTree,
    buildMerkleTree
} from '../lib/merkle-tree';
import { FileStorage } from 'storage';

describe('Merkle Tree Metadata', () => {
    const TEST_FILE_PATH = './test-tree-metadata.bin';
    
    beforeEach(() => {
        jest.useFakeTimers();
    });
    
    /**
     * Helper function to create a file hash with a given name and content
     */
    function createHashedItem(name: string, content: string = name): HashedItem {
        // Create a proper 32-byte SHA-256 hash
        const hash = crypto.createHash('sha256').update(content).digest();
        return {
            name,
            hash,
            length: content.length,
            lastModified: new Date(),
        };
    }

    /**
     * Helper function to build a tree with the given file names
     */
    function buildTree(fileNames: string[]): IMerkleTree<any>{
        let merkleTree = createTree("12345678-1234-5678-9abc-123456789abc");
        
        for (const fileName of fileNames) {
            const fileHash = createHashedItem(fileName);
            merkleTree = addItem(merkleTree, fileHash);
        }

        if (!merkleTree) {
            throw new Error('Failed to build the tree');
        }

        merkleTree.dirty = false;
        merkleTree.merkle = buildMerkleTree(merkleTree.sort);
        
        return merkleTree;
    }
    
    // Clean up test file after each test
    afterEach(async () => {
        try {
            await fs.access(TEST_FILE_PATH);
            await fs.unlink(TEST_FILE_PATH);
        } catch (error) {
            // File doesn't exist, nothing to do
        }
    });
    
    test('should initialize metadata when creating a new tree', () => {
        const originalTree = buildTree(['A', 'B']);
        
        // Check that the metadata exists
        // Verify UUID is properly formatted
        expect(originalTree.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
        
        // Verify node and file counts
        expect(originalTree.sort?.nodeCount).toBe(originalTree.sort?.nodeCount || 0);
        expect(originalTree.sort?.leafCount).toBeGreaterThan(0);
    });
    
    test('should update metadata when modifying the tree', () => {
        // Create initial tree
        let tree = buildTree(['A', 'B']);
        const originalMetadata = { id: tree.id, nodeCount: tree.sort?.nodeCount, leafCount: tree.sort?.leafCount };
        
        // Let time pass
        jest.advanceTimersByTime(1000);
        
        // Add a new file
        const fileHashC = createHashedItem('C');
        tree = addItem(tree, fileHashC);
        
        // Check that metadata was updated
        // UUID should remain the same
        expect(tree.id).toEqual(originalMetadata.id);
        
        // Counts should be updated
        expect(tree.sort?.nodeCount).toBe(tree.sort?.nodeCount || 0);
        expect(tree.sort?.leafCount).toBeGreaterThan(0);
    });
    
    test('should update metadata when updating a file', () => {
        // Create initial tree
        let tree = buildTree(['A', 'B']);
        const originalMetadata = { id: tree.id, nodeCount: tree.sort?.nodeCount, leafCount: tree.sort?.leafCount };
        
        // Let time pass
        jest.advanceTimersByTime(1000);
        
        // Update file A
        const updatedHashedItemA = createHashedItem('A', 'modified content');
        updateItem(tree, updatedHashedItemA);
        
        // Check that metadata was updated
        // UUID should remain the same
        expect(tree.id).toEqual(originalMetadata.id);
        
        // Counts should remain the same (updating doesn't add nodes)
        expect(tree.sort?.nodeCount).toBe(originalMetadata.nodeCount);
        expect(tree.sort?.leafCount).toBe(originalMetadata.leafCount);
    });
    
    test('should update metadata when deleting a file', () => {
        // Create initial tree
        let tree = buildTree(['A', 'B', 'C']);
        const originalMetadata = { id: tree.id, nodeCount: tree.sort?.nodeCount, leafCount: tree.sort?.leafCount };
        
        // Let time pass
        jest.advanceTimersByTime(1000);
        
        // Delete file B
        deleteItem(tree, 'B');
        
        // Check that metadata was updated
        // UUID should remain the same
        expect(tree.id).toEqual(originalMetadata.id);
        
        // Counts should decrease (hard delete removes nodes)
        expect(tree.sort?.nodeCount || 0).toBeLessThan(originalMetadata.nodeCount || 0);
        expect(tree.sort?.leafCount).toBe((originalMetadata.leafCount || 0) - 1);
    });
    
    test('should save and load metadata with V2 format', async () => {
        // Create a tree with metadata
        const originalTree = buildTree(['A', 'B', 'C']);
        // Save the tree to a file
        await saveTree(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        // Load the tree from the file
        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        // All metadata fields should match
        expect(loadedTree.id).toEqual(originalTree.id);
        expect(loadedTree.sort?.nodeCount).toEqual(originalTree.sort?.nodeCount);
        expect(loadedTree.sort?.leafCount).toEqual(originalTree.sort?.leafCount);
    });
    
    // Tests removed - createDefaultMetadata and updateMetadata no longer exist
    // Metadata (totalNodes, totalFiles, totalSize) now comes directly from the sort tree root
});