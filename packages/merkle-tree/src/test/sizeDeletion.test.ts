import * as crypto from 'crypto';
import { 
  IMerkleTree, 
  addFile, 
  deleteFile,
  findFileNode,
  createTree,
  FileHash
} from '../lib/merkle-tree';

describe('Size calculation with file deletion', () => {
  
  // Helper function to create a file hash with specific size
  function createFileHash(fileName: string, content: string, size: number): FileHash {
    const hash = crypto.createHash('sha256')
      .update(content)
      .digest();
    return {
      fileName,
      hash,
      length: size,
      lastModified: new Date(),
    };
  }

  // Helper to build a test tree with files of specific sizes
  function buildTestTree(): IMerkleTree<any>{
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    const files = [
      { name: 'file1.txt', content: 'content 1', size: 1000 },
      { name: 'file2.txt', content: 'content 2', size: 2000 },
      { name: 'file3.txt', content: 'content 3', size: 3000 },
      { name: 'file4.txt', content: 'content 4', size: 4000 },
      { name: 'file5.txt', content: 'content 5', size: 5000 }
    ];
    
    for (const file of files) {
      tree = addFile(tree, createFileHash(file.name, file.content, file.size));
    }
    
    return tree;
  }

  test('deleting a file removes it completely from the tree', () => {
    const tree = buildTestTree();
    const fileToDelete = 'file3.txt';
    
    // Verify initial state
    const initialNode = findFileNode(tree, fileToDelete);
    expect(initialNode?.size).toBe(3000);
    
    // Delete the file completely
    deleteFile(tree, fileToDelete);
    
    // Verify the file is completely gone
    const deletedNode = findFileNode(tree, fileToDelete);
    expect(deletedNode).toBeUndefined();
  });

  test('deleting a file updates parent node sizes', () => {
    const tree = buildTestTree();
    const initialTotalSize = 15000; // Sum of all file sizes: 1000+2000+3000+4000+5000
    
    // Verify initial total size
    expect(tree.sort?.size).toBe(initialTotalSize);
    expect(tree.metadata.totalSize).toBe(initialTotalSize);
    
    // Delete a file of size 3000
    deleteFile(tree, 'file3.txt');
    
    // Expected new total: 15000 - 3000 = 12000
    expect(tree.sort?.size).toBe(12000);
    expect(tree.metadata.totalSize).toBe(12000);
  });

  test('deleting multiple files correctly updates size throughout the tree', () => {
    const tree = buildTestTree();
    const initialTotalSize = 15000;
    
    // Verify initial state
    expect(tree.metadata.totalSize).toBe(initialTotalSize);
    
    // Delete multiple files
    deleteFile(tree, 'file1.txt'); // -1000
    deleteFile(tree, 'file4.txt'); // -4000
    
    // Expected new size: 15000 - (1000 + 4000) = 10000
    expect(tree.sort?.size).toBe(10000);
    expect(tree.metadata.totalSize).toBe(10000);
    
    // Delete one more file
    deleteFile(tree, 'file5.txt'); // -5000
    
    // Expected final size: 10000 - 5000 = 5000
    expect(tree.sort?.size).toBe(5000);
    expect(tree.metadata.totalSize).toBe(5000);
  });

  test('sizes are correctly propagated up through all parent nodes', () => {
    // Create a tree with 7 files to create a 3-level tree
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    const fileSizes = [100, 200, 300, 400, 500, 600, 700];
    
    for (let i = 0; i < fileSizes.length; i++) {
      tree = addFile(tree, createFileHash(`file${i}.txt`, `content ${i}`, fileSizes[i]));
    }
    
    // A 7-file tree will have a structure like:
    //          root
    //         /    \
    //     ABCD      EFG
    //    /    \    /   \
    //   AB    CD  EF    G
    //  / \   / \  / \
    // A   B C   D E  F
    
    // Verify initial state
    const totalSize = fileSizes.reduce((sum, size) => sum + size, 0);
    expect(tree.sort?.size).toBe(totalSize);
    
    // Delete file C (index 2, size 300)
    deleteFile(tree, 'file2.txt');
    
    // Verify file C is completely gone
    const nodeC = findFileNode(tree, 'file2.txt');
    expect(nodeC).toBeUndefined();
    
    // Verify root node size is updated
    expect(tree.sort?.size).toBe(totalSize - fileSizes[2]);
    expect(tree.metadata.totalSize).toBe(totalSize - fileSizes[2]);
  });

  test('totalSize in metadata correctly reflects all deletions', () => {
    const tree = buildTestTree();
    const initialTotalSize = 15000;
    
    // Delete files one by one and verify metadata is updated each time
    deleteFile(tree, 'file1.txt'); // -1000
    expect(tree.metadata.totalSize).toBe(initialTotalSize - 1000);
    
    deleteFile(tree, 'file3.txt'); // -3000
    expect(tree.metadata.totalSize).toBe(initialTotalSize - 1000 - 3000);
    
    deleteFile(tree, 'file5.txt'); // -5000
    expect(tree.metadata.totalSize).toBe(initialTotalSize - 1000 - 3000 - 5000);
    
    // Final size should be 2000 + 4000 = 6000
    expect(tree.metadata.totalSize).toBe(6000);
  });
});