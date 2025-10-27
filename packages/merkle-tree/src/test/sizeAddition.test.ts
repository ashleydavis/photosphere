import * as crypto from 'crypto';
import { 
  addItem, 
  createTree,
  HashedItem
} from '../lib/merkle-tree';
import { visualizeTree } from '../lib/visualize';

describe('Size calculation with file addition', () => {
  
  // Helper function to create a file hash with specific size
  function createHashedItem(name: string, content: string, size: number): HashedItem {
    const hash = crypto.createHash('sha256')
      .update(content)
      .digest();
    return {
      name,
      hash,
      length: size,
      lastModified: new Date(),
    };
  }

  test('leaf node should have size equal to file length', () => {
    // Create a tree with one file
    const fileSize = 1024;
    const fileHash = createHashedItem('test.txt', 'test content', fileSize);
    const tree = addItem(createTree("12345678-1234-5678-9abc-123456789abc"), fileHash);

    // Verify the leaf node has correct size
    expect(tree.sort?.size).toBe(fileSize);
    expect(tree.sort?.size).toBe(fileSize);
  });

  test('parent node should have size equal to sum of children', () => {
    // Create a tree with two files of different sizes
    const file1Size = 500;
    const file2Size = 1000;
    
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    tree = addItem(tree, createHashedItem('file1.txt', 'content 1', file1Size));
    tree = addItem(tree, createHashedItem('file2.txt', 'content 2', file2Size));
    
    // Verify root node has sum of all file sizes
    expect(tree.sort?.size).toBe(file1Size + file2Size);
    
    // Verify left child has correct size
    expect(tree.sort?.left?.size).toBe(file1Size);
    
    // Verify right child has correct size
    expect(tree.sort?.right?.size).toBe(file2Size);
    
    // Verify metadata reflects total size
    expect(tree.sort?.size).toBe(file1Size + file2Size);
  });

  test('sizes are propagated correctly in a multi-level tree', () => {
    // Create a tree with multiple files
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    const sizes = [100, 200, 300, 400, 500, 600, 700];
    const totalSize = sizes.reduce((sum, size) => sum + size, 0);
    
    // Add files with different sizes
    for (let i = 0; i < sizes.length; i++) {
      tree = addItem(tree, createHashedItem(`file${i}.txt`, `content ${i}`, sizes[i]));
    }
    
    expect(tree.sort?.size).toBe(totalSize);    
    expect(tree.sort?.size).toBe(totalSize);    
    expect(tree.sort?.left?.size).toBe(1500);
    expect(tree.sort?.right?.size).toBe(1300);
  });
  
  test('size is updated when adding files', () => {
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    expect(tree.sort).toBeUndefined();
    
    // Add first file
    const file1Size = 1000;
    tree = addItem(tree, createHashedItem('file1.txt', 'content 1', file1Size));
    expect(tree.sort?.size).toBe(file1Size);
    
    // Add second file
    const file2Size = 2000;
    tree = addItem(tree, createHashedItem('file2.txt', 'content 2', file2Size));
    expect(tree.sort?.size).toBe(file1Size + file2Size);
    
    // Add third file
    const file3Size = 3000;
    tree = addItem(tree, createHashedItem('file3.txt', 'content 3', file3Size));
    expect(tree.sort?.size).toBe(file1Size + file2Size + file3Size);
  });
});