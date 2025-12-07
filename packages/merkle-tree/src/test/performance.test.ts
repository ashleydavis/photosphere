import * as crypto from 'crypto';
import { 
  addItem, 
  updateItem, 
  deleteItem,
  HashedItem,
  findItemNode,
  createTree,
} from '../lib/merkle-tree';

/**
 * Helper function to create a file hash with specified content
 */
function createHashedItem(name: string, content: string = name): HashedItem {
  const hash = crypto.createHash('sha256')
    .update(content)
    .digest();
  return {
    name,
    hash,
    length: content.length,
    lastModified: new Date(),
  };
}

/**
 * Helper function to measure execution time
 */
function measureTime<T>(fn: () => T): [T, number] {
  const start = process.hrtime.bigint();
  const result = fn();
  const end = process.hrtime.bigint();
  const timeInMs = Number(end - start) / 1e6; // Convert ns to ms
  return [result, timeInMs];
}

/**
 * Helper to generate sequential file names
 */
function generateFileNames(count: number, prefix: string = 'file-'): string[] {
  return Array.from({ length: count }, (_, i) => `${prefix}${i}.txt`);
}

// These tests are marked with larger timeouts since they involve
// performance measurements on potentially large data structures
jest.setTimeout(30000);

describe('Merkle Tree Performance Tests', () => {
  
  test('should measure performance of adding files to tree', () => {
    const sizes = [10, 100, 1000, 5000, 10000];
    
    for (const size of sizes) {
      const fileNames = generateFileNames(size);
      let tree = createTree("12345678-1234-5678-9abc-123456789abc");
      
      const [resultTree, time] = measureTime(() => {
        for (const fileName of fileNames) {
          tree = addItem(tree, createHashedItem(fileName));
        }
        return tree;
      });
      
      // console.log(`Adding ${size} files took ${time.toFixed(2)}ms`);
      
      // Basic assertions to verify the tree was built properly
      expect(resultTree).toBeDefined();
      expect(resultTree!.sort?.leafCount).toBe(size);
      
      // Time should be roughly O(n log n)
      const timePerFile = time / size;
      expect(timePerFile).toBeLessThan(8);
    }
  });
  
  test('should measure performance of updating files in tree', () => {
    // First, build a tree with a large number of files
    const fileCount = 10000;
    const fileNames = generateFileNames(fileCount);
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    
    for (const fileName of fileNames) {
      tree = addItem(tree, createHashedItem(fileName));
    }
    
    // Test the performance of updating files at different positions
    const indicesToTest = [0, Math.floor(fileCount / 2), fileCount - 1];
    
    for (const index of indicesToTest) {
      const fileName = fileNames[index];
      const updatedContent = `Updated content for ${fileName}`;
      
      const [success, time] = measureTime(() => {
        return updateItem(tree, createHashedItem(fileName, updatedContent));
      });
      
      // console.log(`Updating file at index ${index} took ${time.toFixed(2)}ms`);
      
      // Verify update was successful
      expect(success).toBe(true);
      
      // Verify the hash was actually updated
      const node = findItemNode(tree, fileName);
      expect(node).toBeDefined();
      
      const expectedHash = crypto.createHash('sha256')
        .update(updatedContent)
        .digest();
      
      expect(node!.contentHash!.toString('hex')).toBe(expectedHash.toString('hex'));
      
      // Performance assertions - updating should be O(log n)
      expect(time).toBeLessThan(10); // Should be very fast, under 10ms
    }
  });
  
  test('should measure performance of marking files as deleted in tree', () => {
    // First, build a tree with a large number of files
    const fileCount = 10000;
    const fileNames = generateFileNames(fileCount);
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    
    for (const fileName of fileNames) {
      tree = addItem(tree, createHashedItem(fileName));
    }
    
    // File count before deletions
    const filesBefore = tree!.sort?.leafCount || 0;
    expect(filesBefore).toBe(fileCount);
    
    // Test the performance of deleting files at different positions
    const indicesToTest = [0, Math.floor(fileCount / 2), fileCount - 1];
    
    for (const index of indicesToTest) {
      const fileName = fileNames[index];
      
      const [, time] = measureTime(() => {
        deleteItem(tree!, fileName);
      });
      
      // console.log(`Deleting file ${fileName} took ${time.toFixed(2)}ms`);
      
      // Verify the file is completely gone (this verifies deletion was successful)
      const node = findItemNode(tree, fileName);
      expect(node).toBeUndefined(); // Should not be found
      
      // Performance assertions - deletion should be O(log n)
      expect(time).toBeLessThan(20); // Should be very fast
    }
    
    // Make sure file count is reduced by the number of deletions
    const filesAfter = tree!.sort?.leafCount || 0;
    expect(filesAfter).toBe(filesBefore - indicesToTest.length);
  });
  
  test('should evaluate the impact of tree depth on operations', () => {
    const treeSizes = [1000, 10000];
    const results: Record<number, {addTime: number, updateTime: number}> = {};
    
    for (const size of treeSizes) {
      // Create a tree with 'size' number of files
      const fileNames = generateFileNames(size);
      let tree = createTree("12345678-1234-5678-9abc-123456789abc");
      
      // Measure time to build entire tree
      const [resultTree, addTime] = measureTime(() => {
        for (const fileName of fileNames) {
          tree = addItem(tree, createHashedItem(fileName));
        }
        return tree;
      });
      
      // Measure time to update a file in the middle of the tree
      const middleFileName = fileNames[Math.floor(size / 2)];
      const [, updateTime] = measureTime(() => {
        return updateItem(resultTree, createHashedItem(middleFileName, 'updated content'));
      });
      
      results[size] = { addTime, updateTime };
      
      // const treeDepth = Math.ceil(Math.log2(size));
      // console.log(`Tree with ~${treeDepth} levels (${size} files):`);
      // console.log(`  - Adding all files: ${addTime.toFixed(2)}ms`);
      // console.log(`  - Updating middle file: ${updateTime.toFixed(2)}ms`);
    }
    
    // Verify log n scaling for updates (should be much faster than adds)
    for (let i = 1; i < treeSizes.length; i++) {
      const currentSize = treeSizes[i];
      const previousSize = treeSizes[i-1];
      const currentUpdateTime = results[currentSize].updateTime;
      const previousUpdateTime = results[previousSize].updateTime;
      
      // In a logarithmic algorithm, time should scale sublinearly with size
      const sizeRatio = currentSize / previousSize;
      const timeRatio = currentUpdateTime / previousUpdateTime;
      
      // Time ratio should be much less than size ratio for log(n) operations
      expect(timeRatio).toBeLessThan(sizeRatio * 2); // I tend to run other tasks on the computer while testing so these performance tests must be more tolerant.
    }
    
    // Also verify that update performance scales as expected
    const firstAvgTime = results[treeSizes[0]].updateTime;
    const lastAvgTime = results[treeSizes[treeSizes.length-1]].updateTime / treeSizes[treeSizes.length-1] * treeSizes[0];
    
    // The normalized update time for larger trees should be similar or better
    // than for small trees due to logarithmic scaling
    expect(lastAvgTime).toBeLessThanOrEqual(firstAvgTime * 2);
  });
  
  test('should measure performance of batch operations', () => {
    // First create a baseline tree with 1000 files
    const baselineCount = 1000;
    const baseFileNames = generateFileNames(baselineCount);
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    
    for (const fileName of baseFileNames) {
      tree = addItem(tree, createHashedItem(fileName));
    }
    
    // Now measure bulk operations on this tree
    
    // 1. Bulk add 100 more files
    const addBatchSize = 100;
    const newFileNames = generateFileNames(addBatchSize, 'new-file-');
    
    const [treeAfterAdd, addBatchTime] = measureTime(() => {
      let currentTree = tree;
      for (const fileName of newFileNames) {
        currentTree = addItem(currentTree, createHashedItem(fileName));
      }
      return currentTree;
    });
    
    // console.log(`Bulk adding ${addBatchSize} files to a tree with ${baselineCount} existing files: ${addBatchTime.toFixed(2)}ms`);
    
    // Verify adds worked
    expect(treeAfterAdd!.sort?.leafCount).toBe(baselineCount + addBatchSize);
    
    // 2. Bulk update 100 files
    const updateBatchSize = 100;
    const filesToUpdate = baseFileNames.slice(0, updateBatchSize);
    
    const [updateResults, updateBatchTime] = measureTime(() => {
      return filesToUpdate.map(fileName => 
        updateItem(treeAfterAdd, createHashedItem(fileName, `updated-${fileName}`))
      );
    });
    
    // console.log(`Bulk updating ${updateBatchSize} files in a tree with ${treeAfterAdd!.sort?.leafCount} total files: ${updateBatchTime.toFixed(2)}ms`);
    
    // 3. Bulk delete 100 files
    const deleteBatchSize = 100;
    const filesToDelete = baseFileNames.slice(updateBatchSize, updateBatchSize + deleteBatchSize);
    
    const [, deleteBatchTime] = measureTime(() => {
      filesToDelete.forEach(fileName => deleteItem(treeAfterAdd!, fileName));
    });
    
    // console.log(`Bulk deleting ${deleteBatchSize} files in a tree with ${treeAfterAdd!.sort?.leafCount} total files: ${deleteBatchTime.toFixed(2)}ms`);
    
    // Verify both operations completed successfully
    expect(updateResults.every(success => success === true)).toBe(true);
    // deleteItem now returns void, so success is verified by the fact that no exception was thrown
    
    // Verify the average time per operation is reasonable
    const avgTimePerUpdate = updateBatchTime / updateBatchSize;
    const avgTimePerDelete = deleteBatchTime / deleteBatchSize;
    
    expect(avgTimePerUpdate).toBeLessThan(1); // Less than 1ms per update
    expect(avgTimePerDelete).toBeLessThan(1); // Less than 1ms per delete
  });
});