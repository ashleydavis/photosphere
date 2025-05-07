import { MerkleTree, FileHash } from '../lib/merkle-tree';
import * as crypto from 'crypto';

// Mock the IStorage interface
class MockStorage {
    private files: Map<string, Buffer> = new Map();
    
    constructor(public readonly location: string) {}
    
    async isEmpty(path: string): Promise<boolean> {
        return true;
    }
    
    async listFiles(path: string, max: number, next?: string): Promise<{ names: string[], next?: string }> {
        return { names: [] };
    }
    
    async listDirs(path: string, max: number, next?: string): Promise<{ names: string[], next?: string }> {
        return { names: [] };
    }
    
    async fileExists(filePath: string): Promise<boolean> {
        return this.files.has(filePath);
    }
    
    async dirExists(dirPath: string): Promise<boolean> {
        return false;
    }
    
    async info(filePath: string): Promise<{ contentType: string | undefined, length: number, lastModified: Date } | undefined> {
        if (!this.files.has(filePath)) {
            return undefined;
        }
        return {
            contentType: 'application/octet-stream',
            length: this.files.get(filePath)!.length,
            lastModified: new Date()
        };
    }
    
    async read(filePath: string): Promise<Buffer | undefined> {
        return this.files.get(filePath);
    }
    
    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {
        this.files.set(filePath, data);
    }
    
    readStream(filePath: string): any {
        throw new Error('Not implemented in mock');
    }
    
    async writeStream(filePath: string, contentType: string | undefined, inputStream: any, contentLength?: number): Promise<void> {
        throw new Error('Not implemented in mock');
    }
    
    async deleteFile(filePath: string): Promise<void> {
        this.files.delete(filePath);
    }
    
    async deleteDir(dirPath: string): Promise<void> {
        // Remove all files that start with the directory path
        for (const filePath of this.files.keys()) {
            if (filePath.startsWith(dirPath + '/')) {
                this.files.delete(filePath);
            }
        }
    }
    
    async copyTo(srcPath: string, destPath: string): Promise<void> {
        const data = this.files.get(srcPath);
        if (data) {
            this.files.set(destPath, data);
        }
    }
}

// Helper function to create a file hash
function createFileHash(fileName: string, content: string): FileHash {
    const buffer = Buffer.from(content);
    const hash = crypto.createHash('sha256').update(buffer).digest();
    return {
        fileName,
        hash,
        length: buffer.length
    };
}

describe('MerkleTree', () => {
    let mockStorage: MockStorage;
    let tree: MerkleTree;
    
    beforeEach(() => {
        mockStorage = new MockStorage('test');
        tree = new MerkleTree(mockStorage);
    });
    
    test('initialize with correct metadata', () => {
        const metadata = tree.getMetadata();
        expect(metadata.totalNodes).toBe(0);
        expect(metadata.totalFiles).toBe(0);
        expect(metadata.totalFileSize).toBe(0);
    });
    
    test('add a file hash and create a root node', () => {
        const fileHash = createFileHash('test.txt', 'test content');
        tree.addFileHash(fileHash);
        
        // Complete the tree (this would normally be called after all files are added)
        tree.complete();
        
        // Check that we have a root node
        const rootNode = tree.getRootNode();
        expect(rootNode).toBeDefined();
        expect(tree.getRootHash()).toBeDefined();
        
        // Check metadata was updated
        const metadata = tree.getMetadata();
        expect(metadata.totalFiles).toBe(1);
        expect(metadata.totalNodes).toBe(1); // Just one node (the leaf node) since we only added one file
        expect(metadata.totalFileSize).toBe(fileHash.length);
    });
    
    test('add multiple file hashes and create a proper tree', () => {
        const fileHash1 = createFileHash('file1.txt', 'content 1');
        const fileHash2 = createFileHash('file2.txt', 'content 2');
        const fileHash3 = createFileHash('file3.txt', 'content 3');
        
        tree.addFileHash(fileHash1);
        tree.addFileHash(fileHash2);
        tree.addFileHash(fileHash3);
        
        // Complete the tree
        tree.complete();
        
        // Check that we have a root node
        const rootNode = tree.getRootNode();
        expect(rootNode).toBeDefined();
        
        // In a balanced merkle tree with 3 files, we should have 5 nodes total:
        // - 3 leaf nodes (one for each file)
        // - 1 internal node (parent of first two files)
        // - 1 root node
        const metadata = tree.getMetadata();
        expect(metadata.totalFiles).toBe(3);
        expect(metadata.totalNodes).toBe(5);
        
        // Check the structure of the tree
        expect(rootNode!.leftNode).toBeDefined();
        expect(rootNode!.rightNode).toBeDefined();
        
        // The left node should have two children (it's the parent node of file1 and file2)
        expect(rootNode!.leftNode!.leftNode).toBeDefined();
        expect(rootNode!.leftNode!.rightNode).toBeDefined();
        
        // The right node should be file3
        expect(rootNode!.rightNode!.fileName).toBe('file3.txt');
    });
    
    test('update a file that already exists in the tree', () => {
        // Add two files
        const fileHash1 = createFileHash('file1.txt', 'original content');
        const fileHash2 = createFileHash('file2.txt', 'content 2');
        
        tree.addFileHash(fileHash1);
        tree.addFileHash(fileHash2);
        
        // Complete the tree
        tree.complete();
        
        // Get the original root hash
        const originalRootHash = tree.getRootHash();
        
        // Create a new hash for file1 with updated content
        const updatedFileHash1 = createFileHash('file1.txt', 'updated content');
        
        // Update the file in the tree
        tree.addFileHash(updatedFileHash1);
        
        // Get the new root hash - it should be different
        const newRootHash = tree.getRootHash();
        expect(newRootHash).not.toBe(originalRootHash);
        
        // The file counts should remain the same
        const metadata = tree.getMetadata();
        expect(metadata.totalFiles).toBe(2); // Still 2 files
        expect(metadata.totalNodes).toBe(3); // Still 3 nodes (2 leaves + 1 parent)
    });
    
    test('find a file node in the tree', () => {
        // Add file
        const fileHash = createFileHash('findme.txt', 'find this file');
        tree.addFileHash(fileHash);
        tree.complete();
        
        // Use the public findFileNode method to locate the file
        const foundNode = tree.findFileNode('findme.txt');
        
        // Check that we found the node
        expect(foundNode).toBeDefined();
        expect(foundNode!.node.fileName).toBe('findme.txt');
    });
    
    test('handle nested directory structure', () => {
        // Create file hashes with directory structure
        const fileHash1 = createFileHash('file1.txt', 'content 1');
        fileHash1.directory = { name: 'dir1' };
        
        const fileHash2 = createFileHash('file2.txt', 'content 2');
        fileHash2.directory = { name: 'dir2' };
        
        // Add files to the tree
        tree.addFileHash(fileHash1);
        tree.addFileHash(fileHash2);
        tree.complete();
        
        // Find the files by full path
        const foundNode1 = tree.findFileNode('file1.txt', { name: 'dir1' });
        const foundNode2 = tree.findFileNode('file2.txt', { name: 'dir2' });
        
        // Check that we found the nodes with correct directories
        expect(foundNode1).toBeDefined();
        expect(foundNode1!.node.fileName).toBe('file1.txt');
        expect(foundNode1!.node.directory).toBeDefined();
        expect(foundNode1!.node.directory!.name).toBe('dir1');
        
        expect(foundNode2).toBeDefined();
        expect(foundNode2!.node.fileName).toBe('file2.txt');
        expect(foundNode2!.node.directory).toBeDefined();
        expect(foundNode2!.node.directory!.name).toBe('dir2');
    });
    
    test('save and load the tree', async () => {
        // Add files
        const fileHash1 = createFileHash('file1.txt', 'content 1');
        const fileHash2 = createFileHash('file2.txt', 'content 2');
        
        tree.addFileHash(fileHash1);
        tree.addFileHash(fileHash2);
        tree.complete();
        
        // Get original root hash
        const originalRootHash = tree.getRootHash();
        
        // Save the tree
        await tree.save();
        
        // Create a new tree and load from the same storage
        const newTree = new MerkleTree(mockStorage);
        const loaded = await newTree.load();
        
        // Check that it loaded successfully
        expect(loaded).toBe(true);
        
        // Check that the root hash matches
        expect(newTree.getRootHash()).toBe(originalRootHash);
        
        // Check that metadata was preserved
        const originalMetadata = tree.getMetadata();
        const loadedMetadata = newTree.getMetadata();
        
        expect(loadedMetadata.totalFiles).toBe(originalMetadata.totalFiles);
        expect(loadedMetadata.totalNodes).toBe(originalMetadata.totalNodes);
        expect(loadedMetadata.totalFileSize).toBe(originalMetadata.totalFileSize);
    });
    
    test('visualize the tree correctly', () => {
        // Add files
        const fileHash1 = createFileHash('file1.txt', 'content 1');
        const fileHash2 = createFileHash('file2.txt', 'content 2');
        
        tree.addFileHash(fileHash1);
        tree.addFileHash(fileHash2);
        tree.complete();
        
        // Get the visualization
        const visualization = tree.visualize();
        
        // Check that the visualization contains our files
        expect(visualization).toContain('file1.txt');
        expect(visualization).toContain('file2.txt');
        expect(visualization).toContain('Root hash:');
    });
});