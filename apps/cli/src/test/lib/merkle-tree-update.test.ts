import { MerkleTree, FileHash } from '../../lib/merkle-tree';
import * as crypto from 'crypto';

// Mock the IStorage interface with minimal implementation
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

describe('MerkleTree Update Functionality', () => {
    let mockStorage: MockStorage;
    let tree: MerkleTree;
    
    beforeEach(() => {
        mockStorage = new MockStorage('test');
        tree = new MerkleTree(mockStorage);
    });
    
    test('should update a file in a complex tree and update all parent hashes', () => {
        // Create a more complex tree with multiple levels
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
        
        // Get the original root hash
        const originalRootHash = tree.getRootHash();
        
        // Get file4's original node
        const file4Node = tree.findFileNode('file4.txt');
        expect(file4Node).toBeDefined();
        const originalFile4Hash = file4Node!.node.hash.toString('hex');
        
        // Create an updated version of file4
        const updatedFile4 = createFileHash('file4.txt', 'updated content for file 4');
        
        // Update the file in the tree
        tree.addFileHash(updatedFile4);
        
        // The root hash should have changed
        const newRootHash = tree.getRootHash();
        expect(newRootHash).not.toBe(originalRootHash);
        
        // File4's hash should have changed
        const updatedFile4Node = tree.findFileNode('file4.txt');
        expect(updatedFile4Node).toBeDefined();
        const newFile4Hash = updatedFile4Node!.node.hash.toString('hex');
        expect(newFile4Hash).not.toBe(originalFile4Hash);
        
        // The tree should still have the same number of files
        const metadata = tree.getMetadata();
        expect(metadata.totalFiles).toBe(7);
    });
    
    test('should correctly update files in nested directories', () => {
        // Create files in various directories
        const fileA1 = createFileHash('fileA1.txt', 'content A1', { name: 'dirA' });
        const fileA2 = createFileHash('fileA2.txt', 'content A2', { name: 'dirA' });
        const fileB1 = createFileHash('fileB1.txt', 'content B1', { name: 'dirB' });
        const fileB2 = createFileHash('fileB2.txt', 'content B2', { name: 'dirB' });
        
        // Add files to the tree
        tree.addFileHash(fileA1);
        tree.addFileHash(fileA2);
        tree.addFileHash(fileB1);
        tree.addFileHash(fileB2);
        tree.complete();
        
        // Get original root hash
        const originalRootHash = tree.getRootHash();
        
        // Update a file in dirA
        const updatedFileA1 = createFileHash('fileA1.txt', 'updated content for A1', { name: 'dirA' });
        tree.addFileHash(updatedFileA1);
        
        // The root hash should have changed
        const newRootHash = tree.getRootHash();
        expect(newRootHash).not.toBe(originalRootHash);
        
        // Try to find the updated file
        const foundNode = tree.findFileNode('fileA1.txt', { name: 'dirA' });
        expect(foundNode).toBeDefined();
        
        // Make sure file counts haven't changed
        const metadata = tree.getMetadata();
        expect(metadata.totalFiles).toBe(4);
    });
    
    test('should update multiple files in succession', () => {
        // Add initial files
        const files = [
            createFileHash('file1.txt', 'content 1'),
            createFileHash('file2.txt', 'content 2'),
            createFileHash('file3.txt', 'content 3'),
        ];
        
        files.forEach(file => tree.addFileHash(file));
        tree.complete();
        
        // Get original root hash
        const originalRootHash = tree.getRootHash();
        
        // Update file1
        const updatedFile1 = createFileHash('file1.txt', 'updated content 1');
        tree.addFileHash(updatedFile1);
        
        // Root hash should change
        const rootHashAfterUpdate1 = tree.getRootHash();
        expect(rootHashAfterUpdate1).not.toBe(originalRootHash);
        
        // Update file2
        const updatedFile2 = createFileHash('file2.txt', 'updated content 2');
        tree.addFileHash(updatedFile2);
        
        // Root hash should change again
        const rootHashAfterUpdate2 = tree.getRootHash();
        expect(rootHashAfterUpdate2).not.toBe(rootHashAfterUpdate1);
        
        // Update file3
        const updatedFile3 = createFileHash('file3.txt', 'updated content 3');
        tree.addFileHash(updatedFile3);
        
        // Root hash should change a third time
        const rootHashAfterUpdate3 = tree.getRootHash();
        expect(rootHashAfterUpdate3).not.toBe(rootHashAfterUpdate2);
        
        // File count should still be 3
        const metadata = tree.getMetadata();
        expect(metadata.totalFiles).toBe(3);
    });
    
    test('should handle updating a file that does not exist', () => {
        // Add some files
        const file1 = createFileHash('file1.txt', 'content 1');
        const file2 = createFileHash('file2.txt', 'content 2');
        
        tree.addFileHash(file1);
        tree.addFileHash(file2);
        tree.complete();
        
        // Get original state
        const originalRootHash = tree.getRootHash();
        const originalMetadata = tree.getMetadata();
        
        // Try to update a non-existent file
        const nonExistentFile = createFileHash('nonexistent.txt', 'this file does not exist');
        tree.addFileHash(nonExistentFile);
        
        // We need to complete the tree again to include the new file
        tree.complete();
        
        // It should be added as a new file, not an update
        const newMetadata = tree.getMetadata();
        expect(newMetadata.totalFiles).toBe(originalMetadata.totalFiles + 1);
        
        // Root hash should change
        const newRootHash = tree.getRootHash();
        expect(newRootHash).not.toBe(originalRootHash);
    });
    
    test('should preserve LastUpdatedDate during updates', async () => {
        // Add a file
        const file1 = createFileHash('file1.txt', 'content 1');
        tree.addFileHash(file1);
        tree.complete();
        
        // Save the tree
        await tree.save();
        
        // Wait a moment to ensure timestamp would be different
        await new Promise(resolve => setTimeout(resolve, 100));
        
        // Get the original lastUpdatedDate
        const originalMetadata = tree.getMetadata();
        const originalDate = new Date(originalMetadata.lastUpdatedDate);
        
        // Update the file
        const updatedFile1 = createFileHash('file1.txt', 'updated content 1');
        tree.addFileHash(updatedFile1);
        
        // Get the new lastUpdatedDate
        const newMetadata = tree.getMetadata();
        const newDate = new Date(newMetadata.lastUpdatedDate);
        
        // The lastUpdatedDate should be more recent
        expect(newDate.getTime()).toBeGreaterThan(originalDate.getTime());
    });
});