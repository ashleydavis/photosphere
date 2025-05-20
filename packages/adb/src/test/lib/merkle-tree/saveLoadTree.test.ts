import fs from 'fs/promises';
import * as crypto from 'crypto';
import { 
    IMerkleTree,
    FileHash,
    addFile,
    saveTree,
    loadTree,
    createTree,
} from '../../../lib/merkle-tree';
import { FileStorage } from 'storage';

describe('Merkle Tree Save/Load', () => {
    const TEST_FILE_PATH = './test-tree.bin';
    
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
        let merkleTree = createTree();
        
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
    
    test('should save and load a small tree correctly', async () => {
        // Create a simple tree with two files
        const originalTree = buildTree(['A', 'B']);
        
        // Save the tree to a file
        await saveTree(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        // Load the tree from the file
        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Verify basic tree properties
        expect(loadedTree.metadata.totalFiles).toBe(originalTree.metadata.totalFiles);
        
        // Check that we have the expected file count
        expect(loadedTree.metadata.totalFiles).toBe(2);
        
        // The loaded tree should have nodes (even if not exactly matching the original structure)
        expect(loadedTree.nodes.length).toBeGreaterThan(0);
        
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
    });
    
    test('should save and load a complex tree correctly', async () => {
        // Create a larger tree with multiple levels
        const fileNames = ['A', 'B', 'C', 'D', 'E', 'F', 'G'];
        const originalTree = buildTree(fileNames);
        
        // Save the tree to a file
        await saveTree(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        // Load the tree from the file
        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Verify basic tree properties
        expect(loadedTree.metadata.totalFiles).toBe(fileNames.length);
        
        // Verify we have nodes in the loaded tree
        expect(loadedTree.nodes.length).toBeGreaterThan(0);
        
        // Find leaf nodes by looking for nodes with fileName defined
        const leafNodes = loadedTree.nodes.filter(node => node.fileName !== undefined);
        expect(leafNodes.length).toBe(fileNames.length);
        
        // Verify all original file names are present
        const loadedFileNames = leafNodes.map(node => node.fileName).sort();
        expect(loadedFileNames).toEqual(fileNames.sort());
        
        // Verify each leaf node has the right properties
        for (const node of leafNodes) {
            expect(node.hash).toBeInstanceOf(Buffer);
            expect(node.hash.length).toBe(32);
        }
        
        // Find internal nodes (nodes without fileName)
        const internalNodes = loadedTree.nodes.filter(node => node.fileName === undefined);
        expect(internalNodes.length).toBeGreaterThan(0);
        
        // Verify all internal nodes have proper hash properties
        for (const node of internalNodes) {
            expect(node.hash).toBeInstanceOf(Buffer);
            expect(node.hash.length).toBe(32);
        }
        
        // Verify the tree has a root node
        const rootNode = loadedTree.nodes[0];
        expect(rootNode).toBeDefined();
        expect(rootNode.hash).toBeInstanceOf(Buffer);
        expect(rootNode.hash.length).toBe(32);
    });
    
    test('should correctly save and load trees with long file paths', async () => {
        const longPath = 'a/very/long/nested/directory/path/with/a/deeply/nested/file/structure/example-file.txt';
        const tree = buildTree([longPath]);
        
        await saveTree(TEST_FILE_PATH, tree, new FileStorage(""));

        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        expect(loadedTree.nodes.length).toBe(1);
        expect(loadedTree.nodes[0].fileName).toBe(longPath);
        expect(loadedTree.nodes[0].hash).toBeInstanceOf(Buffer);
        expect(loadedTree.nodes[0].hash.length).toBe(32);
    });
    
    test('should handle trees with special characters in file names', async () => {
        const specialChars = 'file-with-special-chars-!@#$%^&*()_+.txt';
        const tree = buildTree([specialChars]);
        
        await saveTree(TEST_FILE_PATH, tree, new FileStorage(""));

        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        expect(loadedTree.nodes.length).toBe(1);
        expect(loadedTree.nodes[0].fileName).toBe(specialChars);
        expect(loadedTree.nodes[0].hash).toBeInstanceOf(Buffer);
        expect(loadedTree.nodes[0].hash.length).toBe(32);
    });
    
    test('should handle large trees efficiently', async () => {
        // Create a large tree with 100 files
        const fileNames = Array.from({ length: 100 }, (_, i) => `file-${i}.txt`);
        const originalTree = buildTree(fileNames);
        
        // Save the tree
        await saveTree(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        // Load the tree
        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Verify tree properties
        expect(loadedTree.metadata.totalFiles).toBe(100);
        
        // Verify the tree has nodes
        expect(loadedTree.nodes.length).toBeGreaterThan(0);
        
        // Find leaf nodes by looking for nodes with fileName defined
        const leafNodes = loadedTree.nodes.filter(node => node.fileName !== undefined);
        expect(leafNodes.length).toBe(100);
        
        // Ensure that all leaf nodes have valid hashes and follow the naming pattern
        for (const node of leafNodes) {
            expect(node.hash).toBeInstanceOf(Buffer);
            expect(node.hash.length).toBe(32);
            expect(node.fileName).toMatch(/^file-\d+\.txt$/);
        }
        
        // Find internal nodes (nodes without fileName)
        const internalNodes = loadedTree.nodes.filter(node => node.fileName === undefined);
        expect(internalNodes.length).toBeGreaterThan(0);
        
        // All internal nodes should have valid hashes
        for (const node of internalNodes) {
            expect(node.hash).toBeInstanceOf(Buffer);
            expect(node.hash.length).toBe(32);
        }
        
        // Test that we can find specific files in the loaded tree
        const sampleFileNames = fileNames.slice(0, 5); // Take a few sample files
        for (const fileName of sampleFileNames) {
            // Find the node manually since sortedNodeRefs is not loaded
            const node = leafNodes.find(n => n.fileName === fileName);
            expect(node).toBeDefined();
            expect(node?.hash).toBeInstanceOf(Buffer);
            expect(node?.hash.length).toBe(32);
        }
    });
    
    test('should handle empty or very small trees', async () => {
        // Create a tree with just one file
        const originalTree = buildTree(['A']);
        
        await saveTree(TEST_FILE_PATH, originalTree, new FileStorage(""));

        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        expect(loadedTree.nodes.length).toBe(1);
        expect(loadedTree.metadata.totalFiles).toBe(1);
        expect(loadedTree.nodes[0].fileName).toBe('A');
        expect(loadedTree.nodes[0].hash).toBeInstanceOf(Buffer);
        expect(loadedTree.nodes[0].hash.length).toBe(32);
    });
    
    test('should maintain proper tree structure after save/load', async () => {
        const originalTree = buildTree(['A', 'B', 'C', 'D', 'E']);
        
        await saveTree(TEST_FILE_PATH, originalTree, new FileStorage(""));

        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Manually verify tree structure
        function verifyNodeRelationship(nodeIndex: number): void {
            const node = loadedTree.nodes[nodeIndex];
            
            // Skip leaf nodes
            if (node.nodeCount === 1) {
                return;
            }
            
            // For internal nodes, verify relationship with children
            const leftIndex = nodeIndex + 1;
            const leftNode = loadedTree.nodes[leftIndex];
            const leftCount = leftNode.nodeCount;
            const rightIndex = leftIndex + leftCount;
            const rightNode = loadedTree.nodes[rightIndex];
            
            // Verify parent-child relationships
            expect(node.leafCount).toBe(leftNode.leafCount + rightNode.leafCount);
            expect(node.nodeCount).toBe(1 + leftNode.nodeCount + rightNode.nodeCount);
            
            // Verify the hash is the combination of children's hashes
            const combinedHash = crypto.createHash('sha256')
                .update(leftNode.hash)
                .update(rightNode.hash)
                .digest();
            expect(node.hash.toString('hex')).toBe(combinedHash.toString('hex'));
            
            // Recursively verify children
            verifyNodeRelationship(leftIndex);
            verifyNodeRelationship(rightIndex);
        }
        
        // Start verification from the root
        verifyNodeRelationship(0);
    });
    
    test('should save and load sortedNodeRefs correctly', async () => {
        // Create a tree with files in a non-alphabetical order
        const originalTree = buildTree(['C', 'A', 'B']);
        
        // Original tree should have sortedNodeRefs sorted alphabetically
        expect(originalTree.sortedNodeRefs.length).toBe(3);
        expect(originalTree.sortedNodeRefs.map(ref => ref.fileName)).toEqual(['A', 'B', 'C']);
        
        await saveTree(TEST_FILE_PATH, originalTree, new FileStorage(""));

        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
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
    
    test('should regenerate sortedNodeRefs if they are not in the file', async () => {
        // Create a tree with files
        const originalTree = buildTree(['D', 'B', 'A', 'C']);
        
        // Original tree should have sortedNodeRefs sorted alphabetically
        expect(originalTree.sortedNodeRefs.length).toBe(4);
        expect(originalTree.sortedNodeRefs.map(ref => ref.fileName)).toEqual(['A', 'B', 'C', 'D']);
        
        // Manually create a version without sortedNodeRefs to simulate an older file format
        const treeWithoutRefs = {
            ...originalTree,
            sortedNodeRefs: [] // Empty the refs
        };
        
        await saveTree(TEST_FILE_PATH, treeWithoutRefs, new FileStorage(""));

        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Verify the loaded tree regenerated the sortedNodeRefs
        expect(loadedTree.sortedNodeRefs.length).toBe(4);
        
        // Check that the sortedNodeRefs are sorted alphabetically
        const loadedFileNames = loadedTree.sortedNodeRefs.map(ref => ref.fileName);
        expect(loadedFileNames).toEqual(['A', 'B', 'C', 'D']);
    });
    
    test('should handle file not found gracefully', async () => {
        // Try to load from a non-existent file
        expect(await loadTree('non-existent-file.bin', new FileStorage(""))).toBeUndefined();
    });
});