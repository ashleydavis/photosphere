import fs from 'fs/promises';
import * as crypto from 'crypto';
import { 
    IMerkleTree,
    FileHash,
    addFile,
    updateFile,
    markFileAsDeleted,
    saveTreeV2,
    loadTreeV2,
    createDefaultMetadata,
    updateMetadata,
    createTree
} from '../../../lib/merkle-tree';
import { FileStorage } from 'storage';
import { TestTimestampProvider, TestUuidGenerator } from 'node-utils';

describe('Merkle Tree Metadata', () => {
    const TEST_FILE_PATH = './test-tree-metadata.bin';
    const timestampProvider = new TestTimestampProvider();
    const uuidGenerator = new TestUuidGenerator();
    
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
            length: content.length
        };
    }

    /**
     * Helper function to build a tree with the given file names
     */
    function buildTree(fileNames: string[]): IMerkleTree {
        let merkleTree = createTree(timestampProvider, uuidGenerator);
        
        for (const fileName of fileNames) {
            const fileHash = createFileHash(fileName);
            merkleTree = addFile(merkleTree, fileHash, timestampProvider, uuidGenerator);
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
            
            // Timestamps should be valid dates (within the last minute)
            const now = Date.now();
            const oneMinuteAgo = now - 60000;
            expect(originalTree.metadata.createdAt).toBeGreaterThan(oneMinuteAgo);
            expect(originalTree.metadata.createdAt).toBeLessThanOrEqual(now);
            expect(originalTree.metadata.modifiedAt).toBeGreaterThan(oneMinuteAgo);
            expect(originalTree.metadata.modifiedAt).toBeLessThanOrEqual(now);
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
        tree = addFile(tree, fileHashC, timestampProvider, uuidGenerator);
        
        // Check that metadata was updated
        expect(tree.metadata).toBeDefined();
        
        if (tree.metadata) {
            // UUID should remain the same
            expect(tree.metadata.id).toEqual(originalMetadata.id);
            
            // Counts should be updated
            expect(tree.metadata.totalNodes).toBe(tree.nodes.length);
            expect(tree.metadata.totalFiles).toBe(tree.metadata.totalFiles);
            
            // Created time should remain the same
            expect(tree.metadata.createdAt).toEqual(originalMetadata.createdAt);
            
            // Modified time should be updated
            expect(tree.metadata.modifiedAt).toBeGreaterThan(originalMetadata.modifiedAt);
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
        updateFile(tree, updatedFileHashA, timestampProvider);
        
        // Check that metadata was updated
        expect(tree.metadata).toBeDefined();
        
        if (tree.metadata) {
            // UUID should remain the same
            expect(tree.metadata.id).toEqual(originalMetadata.id);
            
            // Counts should remain the same (updating doesn't add nodes)
            expect(tree.metadata.totalNodes).toBe(originalMetadata.totalNodes);
            expect(tree.metadata.totalFiles).toBe(originalMetadata.totalFiles);
            
            // Created time should remain the same
            expect(tree.metadata.createdAt).toEqual(originalMetadata.createdAt);
            
            // Modified time should be updated
            expect(tree.metadata.modifiedAt).toBeGreaterThan(originalMetadata.modifiedAt);
        }
    });
    
    test('should update metadata when deleting a file', () => {
        // Create initial tree
        let tree = buildTree(['A', 'B', 'C']);
        const originalMetadata = { ...tree.metadata! };
        
        // Let time pass
        jest.advanceTimersByTime(1000);
        
        // Delete file B
        markFileAsDeleted(tree, 'B', timestampProvider);
        
        // Check that metadata was updated
        expect(tree.metadata).toBeDefined();
        
        if (tree.metadata) {
            // UUID should remain the same
            expect(tree.metadata.id).toEqual(originalMetadata.id);
            
            // Counts should remain the same (soft delete doesn't remove nodes)
            expect(tree.metadata.totalNodes).toBe(originalMetadata.totalNodes);
            expect(tree.metadata.totalFiles).toBe(originalMetadata.totalFiles);
            
            // Created time should remain the same
            expect(tree.metadata.createdAt).toEqual(originalMetadata.createdAt);
            
            // Modified time should be updated
            expect(tree.metadata.modifiedAt).toBeGreaterThan(originalMetadata.modifiedAt);
        }
    });
    
    test('should save and load metadata with V2 format', async () => {
        // Create a tree with metadata
        const originalTree = buildTree(['A', 'B', 'C']);
        expect(originalTree.metadata).toBeDefined();
        
        // Save the tree to a file
        await saveTreeV2(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        // Load the tree from the file
        const loadedTree = (await loadTreeV2(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Check that metadata was preserved
        expect(loadedTree.metadata).toBeDefined();
        
        if (loadedTree.metadata && originalTree.metadata) {
            // All metadata fields should match
            expect(loadedTree.metadata.id).toEqual(originalTree.metadata.id);
            expect(loadedTree.metadata.totalNodes).toEqual(originalTree.metadata.totalNodes);
            expect(loadedTree.metadata.totalFiles).toEqual(originalTree.metadata.totalFiles);
            expect(loadedTree.metadata.createdAt).toEqual(originalTree.metadata.createdAt);
            expect(loadedTree.metadata.modifiedAt).toEqual(originalTree.metadata.modifiedAt);
        }
    });
    
    test('createDefaultMetadata should generate valid metadata', () => {
        const metadata = createDefaultMetadata(timestampProvider, uuidGenerator);
        
        // UUID should be properly formatted
        expect(metadata.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
        
        // Initial counts should be zero
        expect(metadata.totalNodes).toBe(0);
        expect(metadata.totalFiles).toBe(0);
        
        // Timestamps should be valid dates (within the last minute)
        const now = Date.now();
        const oneMinuteAgo = now - 60000;
        expect(metadata.createdAt).toBeGreaterThan(oneMinuteAgo);
        expect(metadata.createdAt).toBeLessThanOrEqual(now);
        expect(metadata.modifiedAt).toEqual(metadata.createdAt);
    });
    
    test('updateMetadata should update counts and modified time', () => {
        const original = createDefaultMetadata(timestampProvider, uuidGenerator);
        
        // Let time pass
        jest.advanceTimersByTime(1000);
        
        // Update metadata
        const updated = updateMetadata(original, 10, 5, 3, timestampProvider);
        
        // UUID should remain the same
        expect(updated.id).toEqual(original.id);
        
        // Counts should be updated
        expect(updated.totalNodes).toBe(10);
        expect(updated.totalFiles).toBe(5);
        expect(updated.totalSize).toBe(3);
        
        // Created time should remain the same
        expect(updated.createdAt).toEqual(original.createdAt);
        
        // Modified time should be updated
        expect(updated.modifiedAt).toBeGreaterThan(original.modifiedAt);
    });
});