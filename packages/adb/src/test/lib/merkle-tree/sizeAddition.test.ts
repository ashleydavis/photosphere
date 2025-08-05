import * as crypto from 'crypto';
import { 
  FileHash, 
  addFile, 
  createTree
} from '../../../lib/merkle-tree';
import { TestTimestampProvider, TestUuidGenerator } from 'node-utils';

describe('Size calculation with file addition', () => {
  const timestampProvider = new TestTimestampProvider();
  const uuidGenerator = new TestUuidGenerator();
  
  // Helper function to create a file hash with specific size
  function createFileHash(fileName: string, content: string, size: number): FileHash {
    const hash = crypto.createHash('sha256')
      .update(content)
      .digest();
    return {
      fileName,
      hash,
      length: size,
    };
  }

  test('leaf node should have size equal to file length', () => {
    // Create a tree with one file
    const fileSize = 1024;
    const fileHash = createFileHash('test.txt', 'test content', fileSize);
    const tree = addFile(createTree(timestampProvider, uuidGenerator), fileHash, timestampProvider, uuidGenerator);

    // Verify the leaf node has correct size
    expect(tree.nodes[0].size).toBe(fileSize);
    expect(tree.metadata.totalSize).toBe(fileSize);
  });

  test('parent node should have size equal to sum of children', () => {
    // Create a tree with two files of different sizes
    const file1Size = 500;
    const file2Size = 1000;
    
    let tree = createTree(timestampProvider, uuidGenerator);
    tree = addFile(tree, createFileHash('file1.txt', 'content 1', file1Size), timestampProvider, uuidGenerator);
    tree = addFile(tree, createFileHash('file2.txt', 'content 2', file2Size), timestampProvider, uuidGenerator);
    
    // Verify root node has sum of all file sizes
    expect(tree.nodes[0].size).toBe(file1Size + file2Size);
    
    // Verify left child has correct size
    expect(tree.nodes[1].size).toBe(file1Size);
    
    // Verify right child has correct size
    expect(tree.nodes[2].size).toBe(file2Size);
    
    // Verify metadata reflects total size
    expect(tree.metadata.totalSize).toBe(file1Size + file2Size);
  });

  test('sizes are propagated correctly in a multi-level tree', () => {
    // Create a tree with multiple files
    let tree = createTree(timestampProvider, uuidGenerator);
    const sizes = [100, 200, 300, 400, 500, 600, 700];
    const totalSize = sizes.reduce((sum, size) => sum + size, 0);
    
    // Add files with different sizes
    for (let i = 0; i < sizes.length; i++) {
      tree = addFile(tree, createFileHash(`file${i}.txt`, `content ${i}`, sizes[i]), timestampProvider, uuidGenerator);
    }
    
    // Verify root node size equals sum of all file sizes
    expect(tree.nodes[0].size).toBe(totalSize);
    
    // Verify metadata reflects total size
    expect(tree.metadata.totalSize).toBe(totalSize);
    
    // For a balanced tree with 7 nodes, we'd have a structure like:
    //          root
    //         /    \
    //     ABCD      EFG
    //    /    \    /   \
    //   AB    CD  EF    G
    //  / \   / \  / \
    // A   B C   D E  F
    
    // Verify internal nodes have correct cumulative sizes
    // Left subtree (ABCD) = 100 + 200 + 300 + 400 = 1000
    const leftSubtreeIndex = 1; // First child of root
    expect(tree.nodes[leftSubtreeIndex].size).toBe(1000);
    
    // Right subtree (EFG) = 500 + 600 + 700 = 1800
    const rightSubtreeIndex = 1 + tree.nodes[1].nodeCount;
    expect(tree.nodes[rightSubtreeIndex].size).toBe(1800);
  });
  
  test('metadata totalSize is updated when adding files', () => {
    let tree = createTree(timestampProvider, uuidGenerator);
    expect(tree.metadata.totalSize).toBe(0);
    
    // Add first file
    const file1Size = 1000;
    tree = addFile(tree, createFileHash('file1.txt', 'content 1', file1Size), timestampProvider, uuidGenerator);
    expect(tree.metadata.totalSize).toBe(file1Size);
    
    // Add second file
    const file2Size = 2000;
    tree = addFile(tree, createFileHash('file2.txt', 'content 2', file2Size), timestampProvider, uuidGenerator);
    expect(tree.metadata.totalSize).toBe(file1Size + file2Size);
    
    // Add third file
    const file3Size = 3000;
    tree = addFile(tree, createFileHash('file3.txt', 'content 3', file3Size), timestampProvider, uuidGenerator);
    expect(tree.metadata.totalSize).toBe(file1Size + file2Size + file3Size);
  });
});