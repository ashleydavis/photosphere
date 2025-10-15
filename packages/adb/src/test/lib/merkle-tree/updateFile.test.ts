import * as crypto from 'crypto';
import { 
    FileHash, 
    MerkleNode,
    addFile, 
    updateFile, 
    findFileNode,
    traverseTreeSync,
    createTree, 
} from '../../../lib/merkle-tree';
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
  it('should update a file and recalculate hashes along the path to root', () => {
    // Create a tree with multiple files to ensure we have a good structure
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    
    // Add several files to create a multi-level tree
    const file1 = createFileHash('file1.txt', 'original content 1');
    const file2 = createFileHash('file2.txt', 'original content 2');
    const file3 = createFileHash('file3.txt', 'original content 3');
    const file4 = createFileHash('file4.txt', 'original content 4');
    const file5 = createFileHash('file5.txt', 'original content 5');
    
    // Build the tree
    tree = addFile(tree, file1);
    tree = addFile(tree, file2);
    tree = addFile(tree, file3);
    tree = addFile(tree, file4);
    tree = addFile(tree, file5);
    
    // Get the root hash before update
    const originalRootHash = tree.root?.hash.toString('hex');
    
    // Now update file3
    const updatedFile3 = createFileHash('file3.txt', 'UPDATED content 3');
    const updated = updateFile(tree, updatedFile3);
    
    // Verify the update was successful
    expect(updated).toBe(true);
    
    // Get the new root hash
    const newRootHash = tree.root?.hash.toString('hex');
    
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
    const nonExistentUpdate = updateFile(tree, createFileHash('not-exists.txt', 'content'));
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
    let tree = createTree("12345678-1234-5678-9abc-123456789abc");
    
    // Add files in a specific order to create a known structure
    const fileNames = ['A.txt', 'B.txt', 'C.txt', 'D.txt', 'E.txt', 'F.txt', 'G.txt'];
    const originalContents: { [key: string]: string } = {};
    
    // Add all files to the tree
    for (const fileName of fileNames) {
      const content = `Original content of ${fileName}`;
      originalContents[fileName] = content;
      const fileHash = createFileHash(fileName, content);
      tree = addFile(tree, fileHash);
    }
    
    // Store the original tree structure for comparison
    // console.log("Original Tree:");
    // console.log(visualizeTree(tree!));
    
    // Update one of the files
    const updateFileName = 'D.txt';
    const updatedContent = 'UPDATED CONTENT!';
    const updatedFile = createFileHash(updateFileName, updatedContent);
    
    const updated = updateFile(tree, updatedFile);
    expect(updated).toBe(true);
    
    // console.log("Updated Tree:");
    // console.log(visualizeTree(tree!));
    
    // Verify hash integrity by manually recalculating all parent hashes
    // Each internal node should have a hash equal to the combined hash of its children
    function verifyNodeHash(node: MerkleNode | undefined): boolean {
      if (!node) return true;
      
      let allHashesValid = true;
      
      traverseTreeSync(node, (currentNode) => {
        // Leaf nodes can't be verified this way
        if (currentNode.nodeCount === 1) {
          return true; // Continue traversal
        }
        
        // For internal nodes, recalculate hash from children
        if (!currentNode.left || !currentNode.right) {
          return true; // No children to verify, continue traversal
        }
        
        // Calculate the expected hash
        const expectedHash = crypto.createHash('sha256')
          .update(currentNode.left.hash)
          .update(currentNode.right.hash)
          .digest();
        
        // Compare with actual hash
        const hashesMatch = Buffer.compare(expectedHash, currentNode.hash) === 0;
        if (!hashesMatch) {
          allHashesValid = false;
          return false; // Stop traversal on first error
        }
        
        return true; // Continue traversal
      });
      
      return allHashesValid;
    }
    
    // Verify the entire tree starting from the root
    const treeIntegrity = verifyNodeHash(tree!.root);
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