import * as crypto from 'crypto';
import { FileHash, MerkleTree } from '../../lib/merkle-tree';

// Mock the IStorage interface
class MockStorage {
    private files: Map<string, Buffer> = new Map();
    
    constructor(public readonly location: string) {}
    
    async isEmpty(path: string): Promise<boolean> { return true; }
    async listFiles(path: string, max: number, next?: string): Promise<{ names: string[], next?: string }> { return { names: [] }; }
    async listDirs(path: string, max: number, next?: string): Promise<{ names: string[], next?: string }> { return { names: [] }; }
    async fileExists(filePath: string): Promise<boolean> { return this.files.has(filePath); }
    async dirExists(dirPath: string): Promise<boolean> { return false; }
    
    async info(filePath: string): Promise<{ contentType: string | undefined, length: number, lastModified: Date } | undefined> {
        if (!this.files.has(filePath)) return undefined;
        return { contentType: 'application/octet-stream', length: this.files.get(filePath)!.length, lastModified: new Date() };
    }
    
    async read(filePath: string): Promise<Buffer | undefined> { return this.files.get(filePath); }
    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> { this.files.set(filePath, data); }
    readStream(filePath: string): any { throw new Error('Not implemented in mock'); }
    async writeStream(filePath: string, contentType: string | undefined, inputStream: any, contentLength?: number): Promise<void> { throw new Error('Not implemented in mock'); }
    async deleteFile(filePath: string): Promise<void> { this.files.delete(filePath); }
    async deleteDir(dirPath: string): Promise<void> { }
    async copyTo(srcPath: string, destPath: string): Promise<void> { }
}

// Helper function to create a file hash
function createFileHash(fileName: string, content: string, directory?: { name: string }): FileHash {
    const buffer = Buffer.from(content);
    const hash = crypto.createHash('sha256').update(buffer).digest();
    return {
        fileName,
        directory,
        hash,
        length: buffer.length
    };
}

describe('MerkleTree Delete Functionality', () => {
    let mockStorage: MockStorage;
    let tree: MerkleTree;
    
    beforeEach(() => {
        mockStorage = new MockStorage('test');
        tree = new MerkleTree(mockStorage);
    });
    
    test('should delete a file from a simple tree with one file', () => {
        // Add a single file
        const file = createFileHash('file1.txt', 'content 1');
        tree.addFileHash(file);
        tree.complete();
        
        // Check that the tree is valid
        expect(tree.getRootNode()).toBeDefined();
        expect(tree.getMetadata().totalFiles).toBe(1);
        
        // Delete the file
        const deleted = tree.deleteFile('file1.txt', undefined, file.length);
        
        // Verify it was deleted
        expect(deleted).toBe(true);
        expect(tree.getRootNode()).toBeUndefined();
        expect(tree.getMetadata().totalFiles).toBe(0);
        expect(tree.getMetadata().totalNodes).toBe(0);
        expect(tree.getMetadata().totalFileSize).toBe(0);
    });
    
    test('should delete a file from a tree with multiple files', () => {
        // Add multiple files
        const file1 = createFileHash('file1.txt', 'content 1');
        const file2 = createFileHash('file2.txt', 'content 2');
        const file3 = createFileHash('file3.txt', 'content 3');
        
        tree.addFileHash(file1);
        tree.addFileHash(file2);
        tree.addFileHash(file3);
        tree.complete();
        
        // Get the original root hash
        const originalRootHash = tree.getRootHash();
        
        // Delete file2
        const deleted = tree.deleteFile('file2.txt', undefined, file2.length);
        
        // Verify it was deleted
        expect(deleted).toBe(true);
        
        // Root hash should have changed
        const newRootHash = tree.getRootHash();
        expect(newRootHash).not.toBe(originalRootHash);
        
        // Tree should now have 2 files
        expect(tree.getMetadata().totalFiles).toBe(2);
        
        // The file should no longer be findable
        const foundNode = tree.findFileNode('file2.txt');
        expect(foundNode).toBeUndefined();
    });
    
    test('should handle files with directories correctly', () => {
        // Create files in directories
        const fileA = createFileHash('fileA.txt', 'content A', { name: 'dirA' });
        const fileB = createFileHash('fileB.txt', 'content B', { name: 'dirB' });
        
        tree.addFileHash(fileA);
        tree.addFileHash(fileB);
        tree.complete();
        
        // Delete fileA from dirA
        const deleted = tree.deleteFile('fileA.txt', { name: 'dirA' }, fileA.length);
        
        // Verify it was deleted
        expect(deleted).toBe(true);
        
        // fileB should still be there
        const foundNode = tree.findFileNode('fileB.txt', { name: 'dirB' });
        expect(foundNode).toBeDefined();
        
        // Tree should now have 1 file
        expect(tree.getMetadata().totalFiles).toBe(1);
    });
    
    test('should return false when deleting a non-existent file', () => {
        // Add a file
        const file = createFileHash('file1.txt', 'content 1');
        tree.addFileHash(file);
        tree.complete();
        
        // Try to delete a file that does not exist
        const deleted = tree.deleteFile('nonexistent.txt');
        
        // Should return false
        expect(deleted).toBe(false);
        
        // Metadata should remain unchanged
        expect(tree.getMetadata().totalFiles).toBe(1);
    });
    
    test('should handle deletion of the root node in a 2-file tree', () => {
        // Add two files
        const file1 = createFileHash('file1.txt', 'content 1');
        const file2 = createFileHash('file2.txt', 'content 2');
        
        tree.addFileHash(file1);
        tree.addFileHash(file2);
        tree.complete();
        
        // Get the initial metadata
        const initialMetadata = tree.getMetadata();
        
        // Delete file1
        const deleted = tree.deleteFile('file1.txt', undefined, file1.length);
        
        // Verify it was deleted
        expect(deleted).toBe(true);
        
        // Only file2 should remain, and it should be the root
        const rootNode = tree.getRootNode();
        expect(rootNode).toBeDefined();
        expect(rootNode!.fileName).toBe('file2.txt');
        
        // Check metadata
        expect(tree.getMetadata().totalFiles).toBe(1);
        
        // Nodes count decreases by 1 (the parent is replaced by the sibling)
        // The initial tree for 2 files has 3 nodes: root, file1, file2
        expect(tree.getMetadata().totalNodes).toBe(initialMetadata.totalNodes - 1);
    });
    
    test('should delete a file in a complex tree and properly restructure', () => {
        // Create a more complex tree with 7 files
        const files = [
            createFileHash('file1.txt', 'content 1'),
            createFileHash('file2.txt', 'content 2'),
            createFileHash('file3.txt', 'content 3'),
            createFileHash('file4.txt', 'content 4'),
            createFileHash('file5.txt', 'content 5'),
            createFileHash('file6.txt', 'content 6'),
            createFileHash('file7.txt', 'content 7'),
        ];
        
        // Add all files to the tree
        files.forEach(file => tree.addFileHash(file));
        tree.complete();
        
        // Original node/file counts
        const originalNodeCount = tree.getMetadata().totalNodes;
        const originalFileCount = tree.getMetadata().totalFiles;
        
        // Delete file3
        const deleted = tree.deleteFile('file3.txt', undefined, files[2].length);
        
        // Verify deletion was successful
        expect(deleted).toBe(true);
        
        // Verify counts were updated properly
        const newMetadata = tree.getMetadata();
        expect(newMetadata.totalFiles).toBe(originalFileCount - 1);
        expect(newMetadata.totalNodes).toBe(originalNodeCount - 1);
        
        // The tree should still be valid
        expect(tree.getRootNode()).toBeDefined();
        
        // Try to find the deleted file
        const foundNode = tree.findFileNode('file3.txt');
        expect(foundNode).toBeUndefined();
        
        // But we should still be able to find other files
        const otherNode = tree.findFileNode('file4.txt');
        expect(otherNode).toBeDefined();
    });
    
    test('should update totalFileSize when deleting a file', () => {
        // Add files with known sizes
        const file1 = createFileHash('file1.txt', 'content 1'); // Size: 9 bytes
        const file2 = createFileHash('file2.txt', 'content 2'); // Size: 9 bytes
        
        tree.addFileHash(file1);
        tree.addFileHash(file2);
        tree.complete();
        
        // Initial total file size should be 18 bytes
        expect(tree.getMetadata().totalFileSize).toBe(18);
        
        // Delete file1 with its size
        const deleted = tree.deleteFile('file1.txt', undefined, file1.length);
        
        // Verify totalFileSize was reduced
        expect(tree.getMetadata().totalFileSize).toBe(9);
    });
    
    test('should save and load tree metadata after deletion', async () => {
        // Add files - make sure we have an easily identifiable structure
        const file1 = createFileHash('file1.txt', 'content 1');
        const file2 = createFileHash('file2.txt', 'content 2');
        const file3 = createFileHash('file3.txt', 'content 3');
        
        tree.addFileHash(file1);
        tree.addFileHash(file2);
        tree.addFileHash(file3);
        tree.complete();
        
        // Get the original metadata
        const originalMetadata = tree.getMetadata();
        
        // Delete a file
        tree.deleteFile('file1.txt', undefined, file1.length);
        
        // Verify the state before saving
        const afterDeleteMetadata = tree.getMetadata();
        expect(afterDeleteMetadata.totalFiles).toBe(originalMetadata.totalFiles - 1);
        
        // Save the tree
        await tree.save();
        
        // Load the tree in a new instance
        const newTree = new MerkleTree(mockStorage);
        const loaded = await newTree.load();
        
        // Verify it loaded correctly
        expect(loaded).toBe(true);
        
        // Verify the metadata is correct after loading
        const loadedMetadata = newTree.getMetadata();
        expect(loadedMetadata.totalFiles).toBe(afterDeleteMetadata.totalFiles);
        expect(loadedMetadata.totalNodes).toBe(afterDeleteMetadata.totalNodes);
        expect(loadedMetadata.totalFileSize).toBe(afterDeleteMetadata.totalFileSize);
        
        // The root hash should match
        expect(newTree.getRootHash()).toBe(tree.getRootHash());
    });
});