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

// Helper to create a sample tree with n files
function createSampleTree(n: number): { tree: MerkleTree, files: FileHash[] } {
    const mockStorage = new MockStorage('test');
    const tree = new MerkleTree(mockStorage);
    
    const files: FileHash[] = [];
    for (let i = 1; i <= n; i++) {
        const file = createFileHash(`file${i}.txt`, `content ${i}`);
        files.push(file);
        tree.addFileHash(file);
    }
    
    // Only complete the tree if we added at least one file
    if (n > 0) {
        tree.complete();
    }
    
    return { tree, files };
}

describe('MerkleTree Adding Files', () => {
    test('add a file to an empty tree', () => {
        const { tree } = createSampleTree(0);
        
        // Initial state
        expect(tree.getRootNode()).toBeUndefined();
        expect(tree.getMetadata().totalFiles).toBe(0);
        
        // Add a new file
        const newFile = createFileHash('newfile.txt', 'new content');
        tree.addFileHash(newFile);
        tree.complete();
        
        // Check structure
        expect(tree.getRootNode()).toBeDefined();
        expect(tree.getMetadata().totalFiles).toBe(1);
        expect(tree.findFileNode('newfile.txt')).toBeDefined();
    });
    
    test('add a file to a tree with 1 existing file', () => {
        const { tree, files } = createSampleTree(1);
        
        // Initial state
        const initialRootHash = tree.getRootHash();
        expect(tree.getMetadata().totalFiles).toBe(1);
        
        // Add a new file
        const newFile = createFileHash('newfile.txt', 'new content');
        tree.addFileHash(newFile);
        tree.complete();
        
        // The root hash should change
        expect(tree.getRootHash()).not.toBe(initialRootHash);
        
        // Check metadata
        expect(tree.getMetadata().totalFiles).toBe(2);
        expect(tree.getMetadata().totalNodes).toBe(3);
        
        // Test tree structure directly
        const rootNode = tree.getRootNode();
        expect(rootNode).toBeDefined();
        expect(rootNode!.leftNode).toBeDefined();
        expect(rootNode!.rightNode).toBeDefined();
        
        // One of the child nodes should be file1.txt and the other should be newfile.txt
        const leftNodeIsFile1 = rootNode!.leftNode!.fileName === 'file1.txt';
        const rightNodeIsFile1 = rootNode!.rightNode!.fileName === 'file1.txt';
        
        // Exactly one of the child nodes should be file1.txt
        expect(leftNodeIsFile1 || rightNodeIsFile1).toBe(true);
        expect(leftNodeIsFile1 && rightNodeIsFile1).toBe(false);
        
        // The other child should be newfile.txt
        if (leftNodeIsFile1) {
            expect(rootNode!.rightNode!.fileName).toBe('newfile.txt');
        } else {
            expect(rootNode!.leftNode!.fileName).toBe('newfile.txt');
        }
    });
    
    test('add a file to a tree with 2 existing files', () => {
        const { tree, files } = createSampleTree(2);
        
        // Initial state
        const initialRootHash = tree.getRootHash();
        expect(tree.getMetadata().totalFiles).toBe(2);
        
        // Add a new file
        const newFile = createFileHash('newfile.txt', 'new content');
        tree.addFileHash(newFile);
        tree.complete();
        
        // The root hash should change
        expect(tree.getRootHash()).not.toBe(initialRootHash);
        
        // Check metadata
        expect(tree.getMetadata().totalFiles).toBe(3);
        
        // For 3 files in a balanced tree: 5 nodes (3 leaves + 1 parent node + 1 root)
        expect(tree.getMetadata().totalNodes).toBe(5);
        
        // Test tree structure directly
        const rootNode = tree.getRootNode();
        expect(rootNode).toBeDefined();
        expect(rootNode!.leftNode).toBeDefined();
        expect(rootNode!.rightNode).toBeDefined();
        
        // In a balanced tree with 3 nodes, one child of the root should be a leaf,
        // and the other should be an internal node with two leaves
        const leftIsLeaf = !!rootNode!.leftNode!.fileName;
        const rightIsLeaf = !!rootNode!.rightNode!.fileName;
        
        // Either left or right should be a leaf, but not both
        expect(leftIsLeaf || rightIsLeaf).toBe(true);
        expect(leftIsLeaf && rightIsLeaf).toBe(false);
        
        // Check the structure of the internal node (which has two children)
        const internalNode = leftIsLeaf ? rootNode!.rightNode! : rootNode!.leftNode!;
        expect(internalNode.leftNode).toBeDefined();
        expect(internalNode.rightNode).toBeDefined();
        expect(internalNode.leftNode!.fileName).toBeDefined();
        expect(internalNode.rightNode!.fileName).toBeDefined();
        
        // Check that all three files are in the tree
        const fileNames = new Set<string>();
        
        // Add leaf node name
        const leafNode = leftIsLeaf ? rootNode!.leftNode! : rootNode!.rightNode!;
        if (leafNode.fileName) {
            fileNames.add(leafNode.fileName);
        }
        
        // Add internal node's children names
        if (internalNode.leftNode!.fileName) {
            fileNames.add(internalNode.leftNode!.fileName);
        }
        if (internalNode.rightNode!.fileName) {
            fileNames.add(internalNode.rightNode!.fileName);
        }
        
        // Verify all three files are present
        expect(fileNames.size).toBe(3);
        expect(fileNames.has('file1.txt')).toBe(true);
        expect(fileNames.has('file2.txt')).toBe(true);
        expect(fileNames.has('newfile.txt')).toBe(true);
    });
    
    test('add a file to a tree with 3 existing files', () => {
        const { tree, files } = createSampleTree(3);
        
        // Initial state
        const initialRootHash = tree.getRootHash();
        const initialMetadata = tree.getMetadata();
        expect(initialMetadata.totalFiles).toBe(3);
        
        // Add a new file
        const newFile = createFileHash('newfile.txt', 'new content');
        tree.addFileHash(newFile);
        tree.complete();
        
        // The root hash should change
        expect(tree.getRootHash()).not.toBe(initialRootHash);
        
        // Check structure - should have all files
        expect(tree.getMetadata().totalFiles).toBe(4);
        for (let i = 1; i <= 3; i++) {
            expect(tree.findFileNode(`file${i}.txt`)).toBeDefined();
        }
        expect(tree.findFileNode('newfile.txt')).toBeDefined();
        
        // Metadata should be updated correctly
        expect(tree.getMetadata().totalFileSize).toBe(initialMetadata.totalFileSize + newFile.length);
    });
    
    test('add a file to a tree with 4 existing files', () => {
        const { tree, files } = createSampleTree(4);
        
        // Initial state
        const initialRootHash = tree.getRootHash();
        expect(tree.getMetadata().totalFiles).toBe(4);
        
        // Add a new file
        const newFile = createFileHash('newfile.txt', 'new content');
        tree.addFileHash(newFile);
        tree.complete();
        
        // The root hash should change
        expect(tree.getRootHash()).not.toBe(initialRootHash);
        
        // Check structure - should have all files
        expect(tree.getMetadata().totalFiles).toBe(5);
        for (let i = 1; i <= 4; i++) {
            expect(tree.findFileNode(`file${i}.txt`)).toBeDefined();
        }
        expect(tree.findFileNode('newfile.txt')).toBeDefined();
    });
    
    test('add a file to a tree with 5 existing files', () => {
        const { tree, files } = createSampleTree(5);
        
        // Initial state
        const initialRootHash = tree.getRootHash();
        expect(tree.getMetadata().totalFiles).toBe(5);
        
        // Add a new file
        const newFile = createFileHash('newfile.txt', 'new content');
        tree.addFileHash(newFile);
        tree.complete();
        
        // The root hash should change
        expect(tree.getRootHash()).not.toBe(initialRootHash);
        
        // Check structure - should have all files
        expect(tree.getMetadata().totalFiles).toBe(6);
        for (let i = 1; i <= 5; i++) {
            expect(tree.findFileNode(`file${i}.txt`)).toBeDefined();
        }
        expect(tree.findFileNode('newfile.txt')).toBeDefined();
    });
    
    test('add multiple files to an existing tree with 3 files', () => {
        const { tree, files } = createSampleTree(3);
        
        // Initial state
        const initialRootHash = tree.getRootHash();
        expect(tree.getMetadata().totalFiles).toBe(3);
        
        // Add several new files
        const newFile1 = createFileHash('newfile1.txt', 'new content 1');
        const newFile2 = createFileHash('newfile2.txt', 'new content 2');
        const newFile3 = createFileHash('newfile3.txt', 'new content 3');
        
        tree.addFileHash(newFile1);
        tree.addFileHash(newFile2);
        tree.addFileHash(newFile3);
        tree.complete();
        
        // The root hash should change
        expect(tree.getRootHash()).not.toBe(initialRootHash);
        
        // Check structure - should have all files
        expect(tree.getMetadata().totalFiles).toBe(6);
        
        // Original files still there
        for (let i = 1; i <= 3; i++) {
            expect(tree.findFileNode(`file${i}.txt`)).toBeDefined();
        }
        
        // New files are there
        expect(tree.findFileNode('newfile1.txt')).toBeDefined();
        expect(tree.findFileNode('newfile2.txt')).toBeDefined();
        expect(tree.findFileNode('newfile3.txt')).toBeDefined();
    });
    
    test('persist changes after adding a file to a loaded tree', async () => {
        // This test verifies that we can:
        // 1. Create a tree and add files
        // 2. Save the tree
        // 3. Load the tree in a new instance
        // 4. Add a new file to the loaded tree
        // 5. Save the updated tree
        // 6. Verify the updates are persisted correctly
        
        const mockStorage = new MockStorage('test');
        
        // Step 1: Create a new tree with a single file
        const tree = new MerkleTree(mockStorage);
        const file1 = createFileHash('single.txt', 'single file content');
        tree.addFileHash(file1);
        tree.complete();
        
        // Save the initial tree
        await tree.save();
        
        // Step 2: Load the tree in a new instance
        const loadedTree = new MerkleTree(mockStorage);
        const loaded = await loadedTree.load();
        expect(loaded).toBe(true);
        
        // Verify initial state
        expect(loadedTree.getMetadata().totalFiles).toBe(1);
        
        // Step 3: Add a new file to the loaded tree
        const newFile = createFileHash('added.txt', 'newly added content');
        loadedTree.addFileHash(newFile);
        loadedTree.complete();
        
        // Verify both files are in the tree
        expect(loadedTree.getMetadata().totalFiles).toBe(2);
        
        // Step 4: Save the updated tree
        await loadedTree.save();
        
        // Step 5: Load the tree again in a new instance
        const finalTree = new MerkleTree(mockStorage);
        await finalTree.load();
        
        // Step 6: Verify the final tree contains the expected number of files
        const finalMetadata = finalTree.getMetadata();
        expect(finalMetadata.totalFiles).toBe(2);
        
        // Step 7: Verify the root hash is the same before and after saving/loading
        expect(finalTree.getRootHash()).toBe(loadedTree.getRootHash());
    });
    
    test('add files with directories to an existing tree', () => {
        const { tree } = createSampleTree(2);
        
        // Add files with directories
        const fileA = createFileHash('fileA.txt', 'content A', { name: 'dirA' });
        const fileB = createFileHash('fileB.txt', 'content B', { name: 'dirB' });
        
        tree.addFileHash(fileA);
        tree.addFileHash(fileB);
        tree.complete();
        
        // Check metadata
        expect(tree.getMetadata().totalFiles).toBe(4);
        
        // Test tree structure directly by traversing all nodes and collecting file info
        function collectFileInfo(node: any): Array<{name: string, dir?: string}> {
            if (!node) return [];
            
            if (node.fileName) {
                return [{
                    name: node.fileName,
                    dir: node.directory ? node.directory.name : undefined
                }];
            }
            
            return [
                ...collectFileInfo(node.leftNode),
                ...collectFileInfo(node.rightNode)
            ];
        }
        
        const files = collectFileInfo(tree.getRootNode());
        expect(files.length).toBe(4);
        
        // Verify regular files without directories
        const regularFiles = files.filter(f => !f.dir);
        expect(regularFiles.length).toBe(2);
        expect(regularFiles.some(f => f.name === 'file1.txt')).toBe(true);
        expect(regularFiles.some(f => f.name === 'file2.txt')).toBe(true);
        
        // Verify files with directories
        const dirAFiles = files.filter(f => f.dir === 'dirA');
        expect(dirAFiles.length).toBe(1);
        expect(dirAFiles[0].name).toBe('fileA.txt');
        
        const dirBFiles = files.filter(f => f.dir === 'dirB');
        expect(dirBFiles.length).toBe(1);
        expect(dirBFiles[0].name).toBe('fileB.txt');
    });
    
    test('add file to exactly fill a balanced tree level', () => {
        // Create a tree with 7 files (a perfectly balanced tree)
        const { tree } = createSampleTree(7);
        
        // Initial state
        const initialRootHash = tree.getRootHash();
        expect(tree.getMetadata().totalFiles).toBe(7);
        
        // Add file to make it 8 files (perfect binary tree with 8 leaf nodes)
        const newFile = createFileHash('newfile.txt', 'new content');
        tree.addFileHash(newFile);
        tree.complete();
        
        // Check metadata
        expect(tree.getMetadata().totalFiles).toBe(8);
        
        // The root hash should change
        expect(tree.getRootHash()).not.toBe(initialRootHash);
        
        // Test the tree structure directly
        const rootNode = tree.getRootNode();
        expect(rootNode).toBeDefined();
        expect(rootNode!.leftNode).toBeDefined();
        expect(rootNode!.rightNode).toBeDefined();
        
        // For a tree with 8 files total, we should have at least 15 nodes:
        // - 8 leaf nodes (one for each file)
        // - 7 internal nodes (including root)
        // The actual structure will depend on the tree balancing algorithm
        expect(tree.getMetadata().totalNodes).toBeGreaterThanOrEqual(15);
        
        // Verify all 8 files are in the tree by traversing all leaf nodes
        function collectLeafNodes(node: any): string[] {
            if (!node) return [];
            if (node.fileName) return [node.fileName]; // Leaf node
            
            return [
                ...collectLeafNodes(node.leftNode),
                ...collectLeafNodes(node.rightNode)
            ];
        }
        
        const leafNodes = collectLeafNodes(rootNode);
        expect(leafNodes.length).toBe(8);
        
        // Check all 8 files are present
        expect(leafNodes).toContain('newfile.txt');
        for (let i = 1; i <= 7; i++) {
            expect(leafNodes).toContain(`file${i}.txt`);
        }
    });
    
    test('add file with extremely large content', () => {
        const { tree } = createSampleTree(3);
        
        // Track initial state
        const initialMetadata = tree.getMetadata();
        const initialFileSize = initialMetadata.totalFileSize;
        
        // Create a large file
        const largeContent = 'x'.repeat(1000000); // 1MB content
        const largeFile = createFileHash('large.txt', largeContent);
        
        // Add to tree
        tree.addFileHash(largeFile);
        tree.complete();
        
        // Check metadata
        expect(tree.getMetadata().totalFiles).toBe(4);
        
        // Check file size is correctly accounted for
        expect(tree.getMetadata().totalFileSize).toBe(initialFileSize + 1000000);
        
        // Find the large file in the tree structure
        function findFileNode(node: any, fileName: string): boolean {
            if (!node) return false;
            if (node.fileName === fileName) return true;
            
            return (
                findFileNode(node.leftNode, fileName) ||
                findFileNode(node.rightNode, fileName)
            );
        }
        
        // Verify large file exists in the tree structure
        expect(findFileNode(tree.getRootNode(), 'large.txt')).toBe(true);
        
        // Original files should still be there
        expect(findFileNode(tree.getRootNode(), 'file1.txt')).toBe(true);
        expect(findFileNode(tree.getRootNode(), 'file2.txt')).toBe(true);
        expect(findFileNode(tree.getRootNode(), 'file3.txt')).toBe(true);
    });
});