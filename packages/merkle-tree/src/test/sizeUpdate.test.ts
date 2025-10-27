import * as crypto from 'crypto';
import { 
  addItem, 
  updateItem,
  findItemNode,
  createTree,
  HashedItem
} from '../lib/merkle-tree';

describe('Size calculation with file updates', () => {

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

  test('updating file size updates node size', () => {
    // Create a tree with one file
    const initialSize = 1000;
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    tree = addItem(tree, createHashedItem('test.txt', 'initial content', initialSize));
    
    // Verify initial size
    expect(tree.sort?.size).toBe(initialSize);
    expect(tree.sort?.size).toBe(initialSize);
    
    // Update the file with a different size
    const updatedSize = 2000;
    const updated = updateItem(tree, createHashedItem('test.txt', 'updated content', updatedSize));
    expect(updated).toBe(true);
    
    // Verify the node size was updated
    const node = findItemNode(tree, 'test.txt');
    expect(node?.size).toBe(updatedSize);
    
    // Verify root node and metadata were updated
    expect(tree.sort?.size).toBe(updatedSize);
    expect(tree.sort?.size).toBe(updatedSize);
  });

  test('updating file propagates size changes up the tree', () => {
    // Create a tree with multiple files
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    const file1Size = 1000;
    const file2Size = 2000;
    const file3Size = 3000;
    
    tree = addItem(tree, createHashedItem('file1.txt', 'content 1', file1Size));
    tree = addItem(tree, createHashedItem('file2.txt', 'content 2', file2Size));
    tree = addItem(tree, createHashedItem('file3.txt', 'content 3', file3Size));
    
    // Initial total size
    const initialTotalSize = file1Size + file2Size + file3Size;
    expect(tree.sort?.size).toBe(initialTotalSize);
    expect(tree.sort?.size).toBe(initialTotalSize);
    
    // Update the second file with a larger size
    const newFile2Size = 5000;
    const sizeDifference = newFile2Size - file2Size;
    updateItem(tree, createHashedItem('file2.txt', 'updated content 2', newFile2Size));
    
    // Verify leaf node size was updated
    const node = findItemNode(tree, 'file2.txt');
    expect(node?.size).toBe(newFile2Size);
    
    // Verify root node size was updated correctly
    expect(tree.sort?.size).toBe(initialTotalSize + sizeDifference);
    
    // Verify metadata was updated
    expect(tree.sort?.size).toBe(initialTotalSize + sizeDifference);
  });

  test('updating file to smaller size properly reduces tree size', () => {
    // Build tree with files of known sizes
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    tree = addItem(tree, createHashedItem('file1.txt', 'content 1', 1000));
    tree = addItem(tree, createHashedItem('file2.txt', 'content 2', 2000));
    tree = addItem(tree, createHashedItem('file3.txt', 'content 3', 3000));
    
    // Initial size is 6000
    expect(tree.sort?.size).toBe(6000);
    
    // Update file3 to a smaller size
    updateItem(tree, createHashedItem('file3.txt', 'smaller content', 1500));
    
    // Expected new total size: 1000 + 2000 + 1500 = 4500
    expect(tree.sort?.size).toBe(4500);
    expect(tree.sort?.size).toBe(4500);
  });

  test('size is correctly maintained in a complex tree with multiple updates', () => {
    // Create a more complex tree with 7 files
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    const initialSizes = [100, 200, 300, 400, 500, 600, 700];
    const totalInitialSize = initialSizes.reduce((sum, size) => sum + size, 0);
    
    // Add files
    for (let i = 0; i < initialSizes.length; i++) {
      tree = addItem(tree, createHashedItem(`file${i}.txt`, `content ${i}`, initialSizes[i]));
    }
    
    // Verify initial total size
    expect(tree.sort?.size).toBe(totalInitialSize);
    expect(tree.sort?.size).toBe(totalInitialSize);
    
    // Update multiple files
    updateItem(tree, createHashedItem('file1.txt', 'updated content 1', 250)); // +50
    updateItem(tree, createHashedItem('file3.txt', 'updated content 3', 350)); // -50
    updateItem(tree, createHashedItem('file5.txt', 'updated content 5', 800)); // +200
    
    // Calculate expected new total
    const expectedNewTotal = totalInitialSize + 50 + (-50) + 200;
    
    // Verify root size is updated correctly
    expect(tree.sort?.size).toBe(expectedNewTotal);
    expect(tree.sort?.size).toBe(expectedNewTotal);
    
    // Verify individual nodes
    expect(findItemNode(tree, 'file1.txt')?.size).toBe(250);
    expect(findItemNode(tree, 'file3.txt')?.size).toBe(350);
    expect(findItemNode(tree, 'file5.txt')?.size).toBe(800);
  });
});