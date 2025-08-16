import fs from 'fs/promises';
import * as crypto from 'crypto';
import { 
    IMerkleTree,
    FileHash,
    addFile,
    saveTreeV2,
    loadTreeV2,
    createTree
} from '../../../lib/merkle-tree';
import { FileStorage } from 'storage';
import { TestTimestampProvider, TestUuidGenerator } from 'node-utils';

describe('Merkle Tree Save/Load V2', () => {
    const TEST_FILE_PATH = './test-tree-v2.bin';
    const timestampProvider = new TestTimestampProvider();
    const uuidGenerator = new TestUuidGenerator();
    
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
    
    test('should save and load a small tree correctly with V2 format', async () => {
        // Create a simple tree with two files
        const originalTree = buildTree(['A', 'B']);
        
        // Save the tree to a file using V2 format
        await saveTreeV2(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        // Load the tree from the file using V2 format
        const loadedTree = (await loadTreeV2(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Verify basic tree properties
        expect(loadedTree.metadata.totalFiles).toBe(originalTree.metadata.totalFiles);
        expect(loadedTree.nodes.length).toBe(originalTree.nodes.length);
        
        // Check that we have the expected file count
        expect(loadedTree.metadata.totalFiles).toBe(2);
        
        // Find leaf nodes to verify data integrity
        const leafNodes = loadedTree.nodes.filter(node => node.fileName !== undefined);
        expect(leafNodes.length).toBe(2);
        
        // They should have filenames 'A' and 'B' (in some order)
        const fileNames = leafNodes.map(node => node.fileName).sort();
        expect(fileNames).toEqual(['A', 'B']);
        
        // Check that leaf nodes have proper hash properties
        for (const node of leafNodes) {
            expect(node.hash).toBeInstanceOf(Buffer);
            expect(node.hash.length).toBe(32);
        }
        
        // Verify node counts and leaf counts are preserved
        for (let i = 0; i < originalTree.nodes.length; i++) {
            expect(loadedTree.nodes[i].nodeCount).toEqual(originalTree.nodes[i].nodeCount);
            expect(loadedTree.nodes[i].leafCount).toEqual(originalTree.nodes[i].leafCount);
        }
    });
    
    test('should save and load a complex tree correctly with V2 format', async () => {
        // Create a larger tree with multiple levels
        const fileNames = ['A', 'B', 'C', 'D', 'E', 'F', 'G'];
        const originalTree = buildTree(fileNames);
        
        // Save the tree to a file
        await saveTreeV2(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        // Load the tree from the file
        const loadedTree = (await loadTreeV2(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Verify basic tree properties
        expect(loadedTree.metadata.totalFiles).toBe(fileNames.length);
        expect(loadedTree.nodes.length).toBe(originalTree.nodes.length);
        
        // Verify leaf nodes have correct file names
        const leafNodes = loadedTree.nodes.filter(node => node.fileName !== undefined);
        expect(leafNodes.length).toBe(fileNames.length);
        
        const loadedFileNames = leafNodes.map(node => node.fileName).sort();
        expect(loadedFileNames).toEqual(fileNames.sort());
        
        // Verify the structure of internal nodes by checking nodeCount and leafCount
        for (let i = 0; i < originalTree.nodes.length; i++) {
            expect(loadedTree.nodes[i].nodeCount).toEqual(originalTree.nodes[i].nodeCount);
            expect(loadedTree.nodes[i].leafCount).toEqual(originalTree.nodes[i].leafCount);
        }
        
        // Verify hash integrity - the root hash should match
        expect(loadedTree.nodes[0].hash.toString('hex')).toBe(originalTree.nodes[0].hash.toString('hex'));
    });
    
    test('should save and load all nodeRefs correctly in V2 format', async () => {
        // Create a tree with files in a non-alphabetical order
        const originalTree = buildTree(['C', 'A', 'B']);
        
        // Original tree should have sortedNodeRefs sorted alphabetically
        expect(originalTree.sortedNodeRefs.length).toBe(3);
        expect(originalTree.sortedNodeRefs.map(ref => ref.fileName)).toEqual(['A', 'B', 'C']);
        
        await saveTreeV2(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        const loadedTree = (await loadTreeV2(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Verify the loaded tree has the sortedNodeRefs
        expect(loadedTree.sortedNodeRefs.length).toBe(3);
        
        // Check that the sortedNodeRefs are sorted alphabetically
        const loadedFileNames = loadedTree.sortedNodeRefs.map(ref => ref.fileName);
        expect(loadedFileNames).toEqual(['A', 'B', 'C']);
        
        // Check the fileIndex values to make sure they match the original
        for (let i = 0; i < originalTree.sortedNodeRefs.length; i++) {
            const originalRef = originalTree.sortedNodeRefs[i];
            const loadedRef = loadedTree.sortedNodeRefs[i];
            
            expect(loadedRef.fileName).toBe(originalRef.fileName);
            expect(loadedRef.fileIndex).toBe(originalRef.fileIndex);
        }
    });
    
    test('should handle trees with special characters in file names in V2 format', async () => {
        const specialChars = 'file-with-special-chars-!@#$%^&*()_+.txt';
        const tree = buildTree([specialChars]);
        
        await saveTreeV2(TEST_FILE_PATH, tree, new FileStorage(""));

        const loadedTree = (await loadTreeV2(TEST_FILE_PATH, new FileStorage("")))!;
        
        // In V2 format the tree structure should be exactly the same
        expect(loadedTree.nodes.length).toBe(tree.nodes.length);
        expect(loadedTree.nodes[0].fileName).toBe(specialChars);
        expect(loadedTree.nodes[0].hash.toString('hex')).toBe(tree.nodes[0].hash.toString('hex'));
        
        // SortedNodeRefs should be preserved
        expect(loadedTree.sortedNodeRefs.length).toBe(1);
        expect(loadedTree.sortedNodeRefs[0].fileName).toBe(specialChars);
        expect(loadedTree.sortedNodeRefs[0].fileIndex).toBe(0);
    });
    
    test('should handle large trees efficiently with V2 format', async () => {
        // Create a large tree with 100 files
        const fileNames = Array.from({ length: 100 }, (_, i) => `file-${i}.txt`);
        const originalTree = buildTree(fileNames);
        
        // Save the tree
        await saveTreeV2(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        // Load the tree
        const loadedTree = (await loadTreeV2(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Verify tree properties
        expect(loadedTree.metadata.totalFiles).toBe(100);
        expect(loadedTree.nodes.length).toBe(originalTree.nodes.length);
        
        // SortedNodeRefs should be preserved
        expect(loadedTree.sortedNodeRefs.length).toBe(100);
        
        // Check a sample of the nodes to ensure they were loaded correctly
        for (let i = 0; i < 5; i++) {
            const originalNode = originalTree.nodes[i];
            const loadedNode = loadedTree.nodes[i];
            
            expect(loadedNode.hash.toString('hex')).toBe(originalNode.hash.toString('hex'));
            expect(loadedNode.nodeCount).toBe(originalNode.nodeCount);
            expect(loadedNode.leafCount).toBe(originalNode.leafCount);
            expect(loadedNode.fileName).toBe(originalNode.fileName);
        }
    });
});