import fs from 'fs/promises';
import * as crypto from 'crypto';
import { 
    IMerkleTree,
    SortNode,
    FileHash,
    addFile,
    saveTree,
    loadTree,
    loadTreeVersion,
    traverseTreeSync,
    createTree,
    CURRENT_DATABASE_VERSION
} from '../../../lib/merkle-tree';
import { FileStorage } from 'storage';

describe('Merkle Tree Save/Load', () => {
    const TEST_FILE_PATH = './test-tree-v2.bin';
    
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

    /**
     * Helper function to compare two binary trees
     */
    function compareTrees(original: SortNode | undefined, loaded: SortNode | undefined) {
        if (!original && !loaded) return;
        if (!original || !loaded) throw new Error('Tree structure mismatch');
        
        expect(loaded.nodeCount).toEqual(original.nodeCount);
        expect(loaded.leafCount).toEqual(original.leafCount);
        
        compareTrees(original.left, loaded.left);
        compareTrees(original.right, loaded.right);
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
        
        // Save the tree to a file using V2 format
        await saveTree(TEST_FILE_PATH, originalTree, new FileStorage(""));
        
        // Load the tree from the file using V2 format
        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        // Verify basic tree properties
        expect(loadedTree.metadata.totalFiles).toBe(originalTree.metadata.totalFiles);
        expect(loadedTree.sort?.nodeCount || 0).toBe(originalTree.sort?.nodeCount || 0);
        
        // Check that we have the expected file count
        expect(loadedTree.metadata.totalFiles).toBe(2);
        
        // Find leaf nodes to verify data integrity using binary tree traversal
        const leafNodes: SortNode[] = [];
        traverseTreeSync(loadedTree.sort, (node) => {
            if (node.nodeCount === 1 && node.fileName) {
                leafNodes.push(node);
            }
            return true; // Continue traversal
        });
        expect(leafNodes.length).toBe(2);
        
        // They should have filenames 'A' and 'B' (in some order)
        const fileNames = leafNodes.map(node => node.fileName).sort();
        expect(fileNames).toEqual(['A', 'B']);
        
        // Check that leaf nodes have proper hash properties
        for (const node of leafNodes) {
            expect(node.hash).toBeInstanceOf(Buffer);
            expect(node.hash.length).toBe(32);
        }
        
        // Verify node counts and leaf counts are preserved using binary tree traversal
        compareTrees(originalTree.sort, loadedTree.sort);
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
        expect(loadedTree.sort?.nodeCount || 0).toBe(originalTree.sort?.nodeCount || 0);
        
        // Verify leaf nodes have correct file names using binary tree traversal
        const leafNodes: SortNode[] = [];
        traverseTreeSync(loadedTree.sort, (node) => {
            if (node.nodeCount === 1 && node.fileName) {
                leafNodes.push(node);
            }
            return true; // Continue traversal
        });
        expect(leafNodes.length).toBe(fileNames.length);
        
        const loadedFileNames = leafNodes.map(node => node.fileName).sort();
        expect(loadedFileNames).toEqual(fileNames.sort());
        
        // Verify the structure using the existing compareTrees function
        compareTrees(originalTree.sort, loadedTree.sort);
        
        // Verify hash integrity - the root hash should match
        expect(loadedTree.sort?.hash.toString('hex')).toBe(originalTree.sort?.hash.toString('hex'));
    });
       
    test('should handle trees with special characters in file names', async () => {
        const specialChars = 'file-with-special-chars-!@#$%^&*()_+.txt';
        const tree = buildTree([specialChars]);
        
        await saveTree(TEST_FILE_PATH, tree, new FileStorage(""));

        const loadedTree = (await loadTree(TEST_FILE_PATH, new FileStorage("")))!;
        
        // the tree structure should be exactly the same
        expect(loadedTree.sort?.nodeCount || 0).toBe(tree.sort?.nodeCount || 0);
        expect(loadedTree.sort?.fileName).toBe(specialChars);
        expect(loadedTree.sort?.hash.toString('hex')).toBe(tree.sort?.hash.toString('hex'));        
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
        expect(loadedTree.sort?.nodeCount || 0).toBe(originalTree.sort?.nodeCount || 0);
                
        // Check that the trees are structurally identical using the compareTrees function
        compareTrees(originalTree.sort, loadedTree.sort);
    });
});

describe('loadTreeVersion', () => {
    const TEST_VERSION_FILE_PATH = './test-tree-version.bin';
    const storage = new FileStorage("");
    
    // Clean up test file after each test
    afterEach(async () => {
        try {
            await fs.access(TEST_VERSION_FILE_PATH);
            await fs.unlink(TEST_VERSION_FILE_PATH);
        } catch (error) {
            // File doesn't exist, nothing to do
        }
    });

    test('should load version from a valid tree file', async () => {
        // Create a tree and save it
        const originalTree = createTree("12345678-1234-5678-9abc-123456789abc");
        await saveTree(TEST_VERSION_FILE_PATH, originalTree, storage);
        
        // Load just the version
        const version = await loadTreeVersion(TEST_VERSION_FILE_PATH, storage);
        
        expect(version).toBe(CURRENT_DATABASE_VERSION);
    });

    test('should throw error for non-existent file', async () => {
        await expect(loadTreeVersion('./non-existent-file.bin', storage)).rejects.toThrow();
    });

    test('should return undefined for empty file', async () => {
        // Create an empty file
        await fs.writeFile(TEST_VERSION_FILE_PATH, Buffer.alloc(0));
        
        const version = await loadTreeVersion(TEST_VERSION_FILE_PATH, storage);
        
        expect(version).toBeUndefined();
    });

    test('should return undefined for file with less than 4 bytes', async () => {
        // Create a file with only 2 bytes
        await fs.writeFile(TEST_VERSION_FILE_PATH, Buffer.from([0x01, 0x02]));
        
        const version = await loadTreeVersion(TEST_VERSION_FILE_PATH, storage);
        
        expect(version).toBeUndefined();
    });

    test('should correctly read version from file with exactly 4 bytes', async () => {
        // Create a file with exactly 4 bytes representing version 42
        const versionBuffer = Buffer.alloc(4);
        versionBuffer.writeUInt32LE(42, 0);
        await fs.writeFile(TEST_VERSION_FILE_PATH, versionBuffer);
        
        const version = await loadTreeVersion(TEST_VERSION_FILE_PATH, storage);
        
        expect(version).toBe(42);
    });

    test('should read version from large file without loading entire file', async () => {
        // Create a file with version followed by lots of data
        const versionBuffer = Buffer.alloc(4);
        versionBuffer.writeUInt32LE(123, 0);
        
        // Add 1MB of additional data after the version
        const largeData = Buffer.alloc(1024 * 1024, 0xFF);
        const completeFile = Buffer.concat([versionBuffer, largeData]);
        
        await fs.writeFile(TEST_VERSION_FILE_PATH, completeFile);
        
        const version = await loadTreeVersion(TEST_VERSION_FILE_PATH, storage);
        
        expect(version).toBe(123);
    });

    test('should handle different version values correctly', async () => {
        const testVersions = [0, 1, 2, 3, 255, 65535, 4294967295]; // Test edge cases
        
        for (const expectedVersion of testVersions) {
            // Create file with specific version
            const versionBuffer = Buffer.alloc(4);
            versionBuffer.writeUInt32LE(expectedVersion, 0);
            await fs.writeFile(TEST_VERSION_FILE_PATH, versionBuffer);
            
            const version = await loadTreeVersion(TEST_VERSION_FILE_PATH, storage);
            
            expect(version).toBe(expectedVersion);
            
            // Clean up for next iteration
            await fs.unlink(TEST_VERSION_FILE_PATH);
        }
    });

    test('should work correctly with large tree files', async () => {
        // Create a complex tree with many files to demonstrate the function works with large files
        const fileNames = Array.from({ length: 100 }, (_, i) => `file-${i.toString().padStart(3, '0')}.txt`);
        let originalTree = createTree("12345678-1234-5678-9abc-123456789abc");
        
        for (const fileName of fileNames) {
            const fileHash: FileHash = {
                fileName,
                hash: crypto.createHash('sha256').update(fileName).digest(),
                length: fileName.length,
                lastModified: new Date(),
            };
            originalTree = addFile(originalTree, fileHash);
        }
        
        await saveTree(TEST_VERSION_FILE_PATH, originalTree, storage);
        
        // Load version from the large tree file
        const version = await loadTreeVersion(TEST_VERSION_FILE_PATH, storage);
        
        // Also load the full tree to compare
        const fullTree = await loadTree(TEST_VERSION_FILE_PATH, storage);
        
        // Verify both methods return the same version
        expect(version).toBe(CURRENT_DATABASE_VERSION);
        expect(fullTree?.version).toBe(CURRENT_DATABASE_VERSION);
        expect(version).toBe(fullTree?.version);
        
        // Verify the tree has the expected number of files
        expect(fullTree?.metadata.totalFiles).toBe(100);
    });
});