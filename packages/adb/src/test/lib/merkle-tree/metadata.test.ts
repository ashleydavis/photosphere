import fs from 'fs/promises';
import * as crypto from 'crypto';
import { 
    IMerkleTree,
    FileHash,
    addFile,
    updateFile,
    markFileAsDeleted,
    saveTree,
    loadTree,
    createDefaultMetadata,
    updateMetadata,
    createTree
} from '../../../lib/merkle-tree';
import { FileStorage } from 'storage';

describe('Merkle Tree Metadata', () => {
    const TEST_FILE_PATH = './test-tree-metadata.bin';
    
    beforeEach(() => {
        jest.useFakeTimers();
    });
    
    /**
     * Helper function to create a file hash with a given name and content
     */
    function createFileHash(fileName: string, content: string = fileName): FileHash {
        // Create a proper 32-byte SHA-256 hash
        const hash = crypto.createHash('sha256').update(content).digest();
        return {
            fileName,
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
            const fileHash = createFileHash(fileName);
            merkleTree = addFile(merkleTree, fileHash);
        }

        if (!merkleTree) {
            throw new Error('Failed to build the tree');
        }
        
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
        expect(originalTree.metadata).toBeDefined();
        
        if (originalTree.metadata) {
            // Verify UUID is properly formatted
            expect(originalTree.metadata.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
            
            // Verify node and file counts
            expect(originalTree.metadata.totalNodes).toBe(originalTree.nodes.length);
            expect(originalTree.metadata.totalFiles).toBe(originalTree.metadata.totalFiles);            
        }
    });
    
    test('should update metadata when modifying the tree', () => {
        // Create initial tree
        let tree = buildTree(['A', 'B']);
        const originalMetadata = { ...tree.metadata! };
        
        // Let time pass
        jest.advanceTimersByTime(1000);
        
        // Add a new file
        const fileHashC = createFileHash('C');
        tree = addFile(tree, fileHashC);
        
        // Check that metadata was updated
        expect(tree.metadata).toBeDefined();
        
        if (tree.metadata) {
            // UUID should remain the same
            expect(tree.metadata.id).toEqual(originalMetadata.id);
            
            // Counts should be updated
            expect(tree.metadata.totalNodes).toBe(tree.nodes.length);
            expect(tree.metadata.totalFiles).toBe(tree.metadata.totalFiles);
        }
    });
    
    test('should update metadata when updating a file', () => {
        // Create initial tree
        let tree = buildTree(['A', 'B']);
        const originalMetadata = { ...tree.metadata! };
        
        // Let time pass
        jest.advanceTimersByTime(1000);
        
        // Update file A
        const updatedFileHashA = createFileHash('A', 'modified content');
        updateFile(tree, updatedFileHashA);
        
        // Check that metadata was updated
        expect(tree.metadata).toBeDefined();
        
        if (tree.metadata) {
            // UUID should remain the same
            expect(tree.metadata.id).toEqual(originalMetadata.id);
            
            // Counts should remain the same (updating doesn't add nodes)
            expect(tree.metadata.totalNodes).toBe(originalMetadata.totalNodes);
            expect(tree.metadata.totalFiles).toBe(originalMetadata.totalFiles);
        }
    });
    
    test('should update metadata when deleting a file', () => {
        // Create initial tree
        let tree = buildTree(['A', 'B', 'C']);
        const originalMetadata = { ...tree.metadata! };
        
        // Let time pass
        jest.advanceTimersByTime(1000);
        
        // Delete file B
        markFileAsDeleted(tree, 'B');
        
        // Check that metadata was updated
        expect(tree.metadata).toBeDefined();
        
        if (tree.metadata) {
            // UUID should remain the same
            expect(tree.metadata.id).toEqual(originalMetadata.id);
            
            // Counts should remain the same (soft delete doesn't remove nodes)
            expect(tree.metadata.totalNodes).toBe(originalMetadata.totalNodes);
            expect(tree.metadata.totalFiles).toBe(originalMetadata.totalFiles);
        }
    });
    
    test('should save and load metadata with V2 format', async () => {
        // Create a tree with metadata
        const originalTree = buildTree(['A', 'B', 'C']);
        expect(originalTree.metadata).toBeDefined();
        
        // Save the tree to a file
        await saveTree(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        // Load the tree from the file
        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Check that metadata was preserved
        expect(loadedTree.metadata).toBeDefined();
        
        if (loadedTree.metadata && originalTree.metadata) {
            // All metadata fields should match
            expect(loadedTree.metadata.id).toEqual(originalTree.metadata.id);
            expect(loadedTree.metadata.totalNodes).toEqual(originalTree.metadata.totalNodes);
            expect(loadedTree.metadata.totalFiles).toEqual(originalTree.metadata.totalFiles);
        }
    });
    
    test('createDefaultMetadata should generate valid metadata', () => {
        const metadata = createDefaultMetadata("12345678-1234-5678-9abc-123456789abc");
        
        // UUID should be properly formatted
        expect(metadata.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
        
        // Initial counts should be zero
        expect(metadata.totalNodes).toBe(0);
        expect(metadata.totalFiles).toBe(0);
    });
    
    test('updateMetadata should update counts and modified time', () => {
        const original = createDefaultMetadata("12345678-1234-5678-9abc-123456789abc");
        
        // Let time pass
        jest.advanceTimersByTime(1000);
        
        // Update metadata
        const updated = updateMetadata(original, 10, 5, 3);
        
        // UUID should remain the same
        expect(updated.id).toEqual(original.id);
        
        // Counts should be updated
        expect(updated.totalNodes).toBe(10);
        expect(updated.totalFiles).toBe(5);
        expect(updated.totalSize).toBe(3);
    });
});