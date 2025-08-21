import * as crypto from 'crypto';
import { 
    FileHash, 
    addFile, 
    updateFile, 
    findFileNode,
    createTree, 
} from '../../../lib/merkle-tree';
import { TestTimestampProvider, TestUuidGenerator } from 'node-utils';

// Helper to create a file hash
function createFileHash(fileName: string, content: string): FileHash {
  const hash = crypto.createHash('sha256').update(content).digest();
  return {
    fileName,
    hash,
    length: content.length,
    lastModified: new Date(),
  };
}

describe('Merkle Tree UpdateFile', () => {
  const timestampProvider = new TestTimestampProvider();
  const uuidGenerator = new TestUuidGenerator();
  it('should update a file and recalculate hashes along the path to root', () => {
    // Create a tree with multiple files to ensure we have a good structure
    let tree = createTree(timestampProvider, uuidGenerator);
    
    // Add several files to create a multi-level tree
    const file1 = createFileHash('file1.txt', 'original content 1');
    const file2 = createFileHash('file2.txt', 'original content 2');
    const file3 = createFileHash('file3.txt', 'original content 3');
    const file4 = createFileHash('file4.txt', 'original content 4');
    const file5 = createFileHash('file5.txt', 'original content 5');
    
    // Build the tree
    tree = addFile(tree, file1, timestampProvider, uuidGenerator);
    tree = addFile(tree, file2, timestampProvider, uuidGenerator);
    tree = addFile(tree, file3, timestampProvider, uuidGenerator);
    tree = addFile(tree, file4, timestampProvider, uuidGenerator);
    tree = addFile(tree, file5, timestampProvider, uuidGenerator);
    
    // Get the root hash before update
    const originalRootHash = tree.nodes[0].hash.toString('hex');
    
    // Now update file3
    const updatedFile3 = createFileHash('file3.txt', 'UPDATED content 3');
    const updated = updateFile(tree, updatedFile3, timestampProvider);
    
    // Verify the update was successful
    expect(updated).toBe(true);
    
    // Get the new root hash
    const newRootHash = tree.nodes[0].hash.toString('hex');
    
    // The root hash should have changed
    expect(newRootHash).not.toBe(originalRootHash);
    
    // Verify the file was actually updated
    const fileNode = findFileNode(tree, 'file3.txt');
    expect(fileNode).toBeDefined();
    expect(fileNode?.hash.toString('hex')).toBe(updatedFile3.hash.toString('hex'));
    
    // All other files should remain unchanged
    const file1Node = findFileNode(tree, 'file1.txt');
    expect(file1Node?.hash.toString('hex')).toBe(file1.hash.toString('hex'));
    
    // Update a non-existent file should return false
    const nonExistentUpdate = updateFile(tree, createFileHash('not-exists.txt', 'content'), timestampProvider);
    expect(nonExistentUpdate).toBe(false);
  });

  //
  // Tree
  //
  //          ABCDEFG (root)
  //         /         \
  //     ABCD          EFG        
  //    /    \        /   \
  //   AB    CD     EF     G       
  //  / \    / \   /  \
  // A   B  C   D E    F           
  //
  //
  // Flat layout vs file index
  //
  // 0: ABCDEFG
  // 1: ABCD
  // 2: AB
  // 3: A        == 0
  // 4: B        == 1
  // 5: CD
  // 6: C        == 2
  // 7: D        == 3
  // 8: EFG
  // 9: EF
  // 10: E       == 4
  // 11: F       == 5
  // 12: G       == 6
  //
  it('should preserve hash integrity through the entire tree after update', () => {
    // Create a more complex tree
    let tree = createTree(timestampProvider, uuidGenerator);
    
    // Add files in a specific order to create a known structure
    const fileNames = ['A.txt', 'B.txt', 'C.txt', 'D.txt', 'E.txt', 'F.txt', 'G.txt'];
    const originalContents: { [key: string]: string } = {};
    
    // Add all files to the tree
    for (const fileName of fileNames) {
      const content = `Original content of ${fileName}`;
      originalContents[fileName] = content;
      const fileHash = createFileHash(fileName, content);
      tree = addFile(tree, fileHash, timestampProvider, uuidGenerator);
    }
    
    // Store the original tree structure for comparison
    // console.log("Original Tree:");
    // console.log(visualizeTree(tree!));
    
    // Update one of the files
    const updateFileName = 'D.txt';
    const updatedContent = 'UPDATED CONTENT!';
    const updatedFile = createFileHash(updateFileName, updatedContent);
    
    const updated = updateFile(tree, updatedFile, timestampProvider);
    expect(updated).toBe(true);
    
    // console.log("Updated Tree:");
    // console.log(visualizeTree(tree!));
    
    // Verify hash integrity by manually recalculating all parent hashes
    // Each internal node should have a hash equal to the combined hash of its children
    function verifyNodeHash(nodeIndex: number): boolean {
      const node = tree!.nodes[nodeIndex];
      
      // Leaf nodes can't be verified this way
      if (node.nodeCount === 1) {
        return true;
      }
      
      // For internal nodes, recalculate hash from children
      const leftIndex = nodeIndex + 1;
      const leftNode = tree!.nodes[leftIndex];
      const leftCount = leftNode.nodeCount;
      const rightIndex = leftIndex + leftCount;
      const rightNode = tree!.nodes[rightIndex];
      
      // Calculate the expected hash
      const expectedHash = crypto.createHash('sha256')
        .update(leftNode.hash)
        .update(rightNode.hash)
        .digest();
      
      // Compare with actual hash
      const hashesMatch = Buffer.compare(expectedHash, node.hash) === 0;
      
      // Recursively verify children
      const leftVerified = verifyNodeHash(leftIndex);
      const rightVerified = verifyNodeHash(rightIndex);
      
      return hashesMatch && leftVerified && rightVerified;
    }
    
    // Verify the entire tree starting from the root
    const treeIntegrity = verifyNodeHash(0);
    expect(treeIntegrity).toBe(true);
    
    // Verify all non-updated files still have their original hash
    for (const fileName of fileNames) {
      if (fileName !== updateFileName) {
        const node = findFileNode(tree, fileName);
        const expectedHash = createFileHash(fileName, originalContents[fileName]).hash;
        expect(node?.hash.toString('hex')).toBe(expectedHash.toString('hex'));
      }
    }
    
    // Verify the updated file has the new hash
    const updatedNode = findFileNode(tree, updateFileName);
    expect(updatedNode?.hash.toString('hex')).toBe(updatedFile.hash.toString('hex'));
  });
});